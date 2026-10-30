import Foundation
import AppKit
import SwiftUI

/// Self-tests run by `swift run GravityBar --test` (and CI). Deterministic fixture checks gate the run;
/// the live section at the end only prints what this machine reports.
@MainActor
enum SelfTests {
    private static var failures = 0

    /// Like `assert`, but active in every build configuration and reported through the exit code.
    static func check(_ condition: @autoclosure () -> Bool, _ message: @autoclosure () -> String = "", file: StaticString = #fileID, line: UInt = #line) {
        guard !condition() else { return }
        failures += 1
        let detail = message()
        print("✗ check failed at \(file):\(line)\(detail.isEmpty ? "" : " — \(detail)")")
    }

    /// Returns the process exit code: 0 when every check passed.
    static func run() async -> Int32 {
        print("Running GravityBar Self-Tests...")
        failures = 0

        // 1. Thresholds
        check(QuotaThreshold.from(usedPercent: 0.0) == .normal)
        check(QuotaThreshold.from(usedPercent: 59.9) == .normal)
        check(QuotaThreshold.from(usedPercent: 60.0) == .warning)
        check(QuotaThreshold.from(usedPercent: 85.0) == .warning)
        check(QuotaThreshold.from(usedPercent: 85.1) == .critical)
        check(QuotaThreshold.from(usedPercent: 100.0) == .critical)
        print("✓ Quota threshold tests passed")

        // 2. Countdowns
        let now = Date()
        let in45m = now.addingTimeInterval(45 * 60)
        let m1 = UsageMetric(windowType: .fiveHour, usedPercent: 50, resetDate: in45m)
        check(m1.formattedReset(relativeTo: now) == "Resets in 45m")

        let in2h15m = now.addingTimeInterval((2 * 3600) + (15 * 60))
        let m2 = UsageMetric(windowType: .fiveHour, usedPercent: 78, resetDate: in2h15m)
        check(m2.formattedReset(relativeTo: now) == "Resets in 2h 15m")

        let in3d = now.addingTimeInterval((3 * 86400) + (14 * 3600))
        let m3 = UsageMetric(windowType: .weekly, usedPercent: 34, resetDate: in3d)
        check(m3.formattedReset(relativeTo: now) == "Resets in 3d 14h")
        print("✓ Countdown formatting tests passed")

        // 3. Provider Urgency Aggregation
        let usage = ProviderUsage(
            provider: .claude,
            fiveHourMetric: UsageMetric(windowType: .fiveHour, usedPercent: 78, resetDate: now),
            weeklyMetric: UsageMetric(windowType: .weekly, usedPercent: 34, resetDate: now)
        )
        check(usage.highestPercent == 78.0)
        check(usage.highestUrgency == .warning)
        print("✓ Provider urgency aggregation tests passed")

        // 3b. Quota polarity: remainingFraction is converted to used %
        let untouched = UsageMetric(windowType: .fiveHour, remainingFraction: 1.0, resetDate: now)
        check(untouched.usedPercent == 0.0 && untouched.remainingPercent == 100.0)
        check(untouched.threshold == .normal)
        let exhausted = UsageMetric(windowType: .fiveHour, remainingFraction: 0.0, resetDate: now)
        check(exhausted.usedPercent == 100.0 && exhausted.threshold == .critical)
        let quarterUsed = UsageMetric(windowType: .weekly, remainingFraction: 0.75, resetDate: now)
        check(quarterUsed.usedPercent == 25.0 && quarterUsed.usageSummary == "25% used • 75% left")
        let roundingEdge = UsageMetric(windowType: .fiveHour, usedPercent: 12.5, resetDate: now)
        check(roundingEdge.usageSummary == "13% used • 87% left")
        print("✓ Quota polarity tests passed")

        // 3c. Antigravity multi-group parsing & multi-PID merge (CHR-57)
        let argonResponse = Data("""
        {"response":{"groups":[
          {"displayName":"Gemini Models","buckets":[
            {"window":"5h","remainingFraction":1.0,"resetTime":"2026-10-24T03:42:18Z"},
            {"window":"weekly","remainingFraction":0.9961552,"resetTime":"2026-10-27T16:45:03Z"}]},
          {"displayName":"Claude and GPT models","buckets":[
            {"window":"5h","remainingFraction":1.0,"resetTime":"2026-10-24T03:42:18Z"},
            {"window":"weekly","remainingFraction":1.0,"resetTime":"2026-10-30T22:42:18Z"}]},
          {"displayName":"Gemini 4 Argon","buckets":[
            {"window":"weekly","remainingFraction":0.7350507,"resetTime":"2026-10-27T16:32:30Z"}]}
        ]}}
        """.utf8)
        let otherResponse = Data("""
        {"response":{"groups":[
          {"displayName":"Gemini Models","buckets":[
            {"window":"5h","remainingFraction":0.9,"resetTime":"2026-10-24T03:42:18Z"},
            {"window":"weekly","remainingFraction":1.0,"resetTime":"2026-10-27T16:45:03Z"}]},
          {"displayName":"Claude and GPT models","buckets":[
            {"window":"5h","remainingFraction":1.0,"resetTime":"2026-10-24T03:42:18Z"}]}
        ]}}
        """.utf8)
        guard let argonGroups = AntigravityProvider.parseQuotaGroups(from: argonResponse, now: now),
              let otherGroups = AntigravityProvider.parseQuotaGroups(from: otherResponse, now: now) else {
            preconditionFailure("Antigravity quota fixtures failed to parse")
        }
        check(argonGroups.map { $0.name } == ["Gemini Models", "Claude and GPT models", "Gemini 4 Argon"])
        check(argonGroups[2].fiveHourMetric == nil && argonGroups[2].weeklyMetric?.usedPercent == 26.0)
        check(argonGroups[0].fiveHourMetric?.usedPercent == 0.0, "Argon weekly bucket must not overwrite Gemini Models")
        check(AntigravityProvider.parseQuotaGroups(from: Data("{}".utf8)) == nil)

        let mergedAB = AntigravityProvider.mergeQuotaGroups([argonGroups, otherGroups])
        let mergedBA = AntigravityProvider.mergeQuotaGroups([otherGroups, argonGroups])
        check(mergedAB.count == 3 && mergedBA.count == 3)
        for (a, b) in zip(mergedAB, mergedBA) {
            check(a.name == b.name)
            check(a.fiveHourMetric?.usedPercent == b.fiveHourMetric?.usedPercent)
            check(a.weeklyMetric?.usedPercent == b.weeklyMetric?.usedPercent)
        }
        let merged = AntigravityProvider.makeUsage(groups: mergedAB, now: now)
        check(merged.fiveHourMetric?.usedPercent == 10.0)
        check(merged.weeklyMetric?.usedPercent == 26.0)
        check(merged.groups.count == 3)
        check(mergedAB.map { $0.name } == AntigravityProvider.groupDisplayOrder)

        // Different PIDs returning different subsets / orders must merge identically
        let subsetA = [argonGroups[2], argonGroups[0]]          // Argon, Gemini Models
        let subsetB = [otherGroups[1], argonGroups[1]]          // Claude and GPT (other PID), Claude and GPT (argon PID)
        let unknown = [QuotaGroup(name: "Aardvark Models", weeklyMetric: UsageMetric(windowType: .weekly, usedPercent: 3, resetDate: now))]
        let forward = AntigravityProvider.mergeQuotaGroups([subsetA, subsetB, unknown])
        let backward = AntigravityProvider.mergeQuotaGroups([unknown, subsetB, subsetA])
        check(forward.map { $0.name } == backward.map { $0.name })
        check(forward.map { $0.name } == AntigravityProvider.groupDisplayOrder + ["Aardvark Models"])

        // Protobuf JSON timestamps may include fractional seconds (GRBA-5: static formatters)
        check(AntigravityProvider.fractionalFormatter.formatOptions.contains(.withFractionalSeconds))
        check(!AntigravityProvider.wholeSecondFormatter.formatOptions.contains(.withFractionalSeconds))
        check(AntigravityProvider.parseResetTime("invalid-date") == nil)
        let fractionalReset = AntigravityProvider.parseResetTime("2026-10-24T03:42:18.491Z")
        let wholeReset = AntigravityProvider.parseResetTime("2026-10-24T03:42:18Z")
        check(fractionalReset != nil && wholeReset != nil)
        check(abs(fractionalReset!.timeIntervalSince(wholeReset!) - 0.491) < 0.001)
        let fractionalResponse = Data("""
        {"response":{"groups":[{"displayName":"Gemini Models","buckets":[
          {"window":"5h","remainingFraction":0.5,"resetTime":"2026-10-24T03:42:18.491Z"}]}]}}
        """.utf8)
        let fractionalGroups = AntigravityProvider.parseQuotaGroups(from: fractionalResponse, now: now)
        check(fractionalGroups?.first?.fiveHourMetric?.resetDate == fractionalReset, "Fractional resetTime must not fall back to now + 5h")
        print("✓ Antigravity multi-group merge tests passed")

        // 3d. Claude window inference from plan-usage-history samples (CHR-58)
        func planSamples(_ rows: [(minutesAgo: Double, fh: Int?, sd: Int?)]) -> Data {
            let items = rows.map { row -> String in
                let t = Int((now.timeIntervalSince1970 - row.minutesAgo * 60) * 1000)
                let fields = [row.fh.map { "\"fh\":\($0)" }, row.sd.map { "\"sd\":\($0)" }].compactMap { $0 }
                return "{\"t\":\(t),\"org\":\"x\",\"u\":{\(fields.joined(separator: ","))}}"
            }
            return Data("{\"version\":1,\"samples\":[\(items.joined(separator: ","))]}".utf8)
        }
        func windows(_ data: Data) -> (UsageMetric, UsageMetric) {
            let samples = ClaudeProvider.parseSamples(from: data)
            return (
                ClaudeProvider.currentWindow(samples: samples, value: \.fiveHour, windowType: .fiveHour, length: 5 * 3600, now: now),
                ClaudeProvider.currentWindow(samples: samples, value: \.weekly, windowType: .weekly, length: 7 * 86400, now: now)
            )
        }

        // Active window: reset counts down from the first non-zero sample, not from the latest sample
        let (activeFH, activeSD) = windows(planSamples([(70, 0, 0), (60, 7, 3), (30, 15, 4), (5, nil, nil), (1, 23, 5)]))
        let expectedActiveFH: TimeInterval = 4 * 3600
        let expectedActiveSD: TimeInterval = 7 * 86400 - 3600
        check(activeFH.usedPercent == 23 && abs(activeFH.resetDate.timeIntervalSince(now) - expectedActiveFH) < 1)
        check(activeSD.usedPercent == 5 && abs(activeSD.resetDate.timeIntervalSince(now) - expectedActiveSD) < 1)

        // Step down means the window reset between samples: new window starts at the lower reading
        let (steppedFH, _) = windows(planSamples([(200, 40, 10), (120, 5, 10)]))
        let expectedSteppedFH: TimeInterval = 3 * 3600
        check(steppedFH.usedPercent == 5 && abs(steppedFH.resetDate.timeIntervalSince(now) - expectedSteppedFH) < 1)

        // Stale: Claude closed for 6h, so the 5h window expired and decays to 0%; weekly still active
        let (staleFH, staleSD) = windows(planSamples([(400, 60, 20), (360, 78, 22)]))
        check(staleFH.usedPercent == 0 && staleSD.usedPercent == 22)

        // Weekly expires after 7 days
        let (_, expiredSD) = windows(planSamples([(8.0 * 24 * 60, 50, 30)]))
        check(expiredSD.usedPercent == 0)
        print("✓ Claude window inference tests passed")

        // 3e. Claude Code CLI token aggregation de-duplicates streamed message ids
        func cliLine(_ id: String, minutesAgo: Double, input: Int, output: Int) -> String {
            let stamp = ISO8601DateFormatter().string(from: now.addingTimeInterval(-minutesAgo * 60))
            return "{\"type\":\"assistant\",\"timestamp\":\"\(stamp)\",\"message\":{\"id\":\"\(id)\",\"usage\":{\"input_tokens\":\(input),\"output_tokens\":\(output),\"cache_read_input_tokens\":100,\"cache_creation_input_tokens\":10}}}"
        }
        let transcript = Data([
            cliLine("msg_a", minutesAgo: 10.1, input: 5, output: 0),      // early streamed block reports 0 output
            cliLine("msg_a", minutesAgo: 10, input: 5, output: 50),       // final line for the same message id
            cliLine("msg_a", minutesAgo: 10, input: 5, output: 50),       // exact duplicate
            "{\"type\":\"user\",\"message\":{\"role\":\"user\"}}",
            cliLine("msg_b", minutesAgo: 6.0 * 60, input: 7, output: 70),   // 7d only
            cliLine("msg_c", minutesAgo: 8.0 * 24 * 60, input: 9, output: 90) // outside 7d
        ].joined(separator: "\n").utf8)
        let cli = ClaudeCodeUsageScanner.aggregate(ClaudeCodeUsageScanner.parseEntries(from: transcript), now: now)
        check(cli.last5h == TokenUsage(inputTokens: 5, outputTokens: 50, cacheReadTokens: 100, cacheCreationTokens: 10))
        check(cli.last5h.outputTokens == 50, "Streamed message must keep its final output_tokens, not the early 0")

        // A recently touched transcript holding only old messages must not surface an empty CLI section
        let staleDir = FileManager.default.temporaryDirectory.appendingPathComponent("gravitybar-cli-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: staleDir, withIntermediateDirectories: true)
        try? Data(cliLine("msg_old", minutesAgo: 30.0 * 24 * 60, input: 1, output: 1).utf8).write(to: staleDir.appendingPathComponent("old.jsonl"))
        check(ClaudeCodeUsageScanner.scan(projectsPath: staleDir.path, now: now) == nil)
        try? Data(cliLine("msg_new", minutesAgo: 5, input: 1, output: 1).utf8).write(to: staleDir.appendingPathComponent("new.jsonl"))
        check(ClaudeCodeUsageScanner.scan(projectsPath: staleDir.path, now: now)?.last5h.outputTokens == 1)
        try? FileManager.default.removeItem(at: staleDir)
        check(cli.last7d == TokenUsage(inputTokens: 12, outputTokens: 120, cacheReadTokens: 200, cacheCreationTokens: 20))
        check(TokenUsage.compact(950) == "950" && TokenUsage.compact(12_300) == "12.3K" && TokenUsage.compact(4_500_000) == "4.5M")
        check(TokenUsage.compact(342_000) == "342K" && TokenUsage.compact(1_000) == "1K" && TokenUsage.compact(2_000_000_000) == "2B")
        print("✓ Claude Code CLI token aggregation tests passed")

        // 3f. Codex rollout token_count parsing (CHR-59)
        func codexEvent(minutesAgo: Double, windows: String, input: Int, cached: Int, output: Int, plan: String = "plus") -> String {
            let stamp = ISO8601DateFormatter().string(from: now.addingTimeInterval(-minutesAgo * 60))
            return "{\"timestamp\":\"\(stamp)\",\"type\":\"event_msg\",\"payload\":{\"type\":\"token_count\",\"info\":{\"total_token_usage\":{\"input_tokens\":\(input),\"cached_input_tokens\":\(cached),\"cache_write_input_tokens\":0,\"output_tokens\":\(output),\"reasoning_output_tokens\":0,\"total_tokens\":\(input + output)}},\"rate_limits\":{\"limit_id\":\"codex\",\(windows),\"plan_type\":\"\(plan)\"}}}"
        }
        let inOneDay = Int(now.addingTimeInterval(86400).timeIntervalSince1970)
        let inTwoHours = Int(now.addingTimeInterval(7200).timeIntervalSince1970)
        let anHourAgo = Int(now.addingTimeInterval(-3600).timeIntervalSince1970)
        let sessionA = Data([
            codexEvent(minutesAgo: 8.0 * 60, windows: "\"primary\":{\"used_percent\":40.0,\"window_minutes\":10080,\"resets_at\":\(inOneDay)},\"secondary\":null", input: 1_000, cached: 600, output: 100),
            codexEvent(minutesAgo: 60, windows: "\"primary\":{\"used_percent\":13.0,\"window_minutes\":10080,\"resets_at\":\(inOneDay)},\"secondary\":{\"used_percent\":55.0,\"window_minutes\":300,\"resets_at\":\(inTwoHours)}", input: 3_000, cached: 2_000, output: 400)
        ].joined(separator: "\n").utf8)
        // Newer event from a local (Ollama) session carries no windows and must not wipe the rate limits
        let sessionB = Data(codexEvent(minutesAgo: 5, windows: "\"primary\":null,\"secondary\":null", input: 50, cached: 0, output: 5).utf8)
        let codexEvents = CodexRolloutScanner.parseEvents(from: sessionA, session: "a") + CodexRolloutScanner.parseEvents(from: sessionB, session: "b")
        let codexUsage = CodexProvider.makeUsage(events: codexEvents, now: now)
        check(codexUsage.fiveHourMetric?.usedPercent == 55 && codexUsage.weeklyMetric?.usedPercent == 13)
        check(codexUsage.weeklyMetric?.windowType == .weekly && codexUsage.planBadge == "Plus" && codexUsage.connectionState == .connected)
        // 5h: session A grew 3000-1000 input (incl. cached 2000-600) since the 8h-old baseline; session B is new
        check(codexUsage.cliTokenUsage?.last5h == TokenUsage(inputTokens: 600 + 50, outputTokens: 300 + 5, cacheReadTokens: 1_400, cacheCreationTokens: 0))
        check(codexUsage.cliTokenUsage?.last7d == TokenUsage(inputTokens: 1_000 + 50, outputTokens: 400 + 5, cacheReadTokens: 2_000, cacheCreationTokens: 0))

        // Expired window resets to 0% and rolls forward; 43200-minute windows are monthly
        let expired = CodexRolloutScanner.Window(usedPercent: 80, windowMinutes: 300, resetsAt: Date(timeIntervalSince1970: TimeInterval(anHourAgo)))
        check(expired.metric(now: now).usedPercent == 0 && abs(expired.metric(now: now).resetDate.timeIntervalSince(now) - 4 * 3600) < 2)
        check(CodexRolloutScanner.Window(usedPercent: 1, windowMinutes: 43200, resetsAt: now).windowType == .monthly)
        check(CodexProvider.makeUsage(events: [], now: now).connectionState == .notConfigured)
        // No 5-hour window reported: headline stays nil instead of a fake 0% / now + 5h placeholder
        let weeklyOnly = CodexProvider.makeUsage(events: CodexRolloutScanner.parseEvents(from: Data(codexEvent(minutesAgo: 30, windows: "\"primary\":{\"used_percent\":20.0,\"window_minutes\":10080,\"resets_at\":\(inOneDay)},\"secondary\":null", input: 1, cached: 0, output: 1).utf8), session: "c"), now: now)
        check(weeklyOnly.fiveHourMetric == nil && weeklyOnly.weeklyMetric?.usedPercent == 20)
        check(weeklyOnly.connectionState == .idleCached(lastSeen: weeklyOnly.cliTokenUsage!.lastActivity!))
        print("✓ Codex rollout parsing tests passed")

        // 3g. Connection state, offline placeholders and Ollama (CHR-60)
        check(ProviderConnectionState.fromLastSeen(now.addingTimeInterval(-60), now: now) == .connected)
        check(ProviderConnectionState.fromLastSeen(now.addingTimeInterval(-3 * 3600), now: now).label(relativeTo: now) == "Last seen 3h ago")
        check(!ProviderConnectionState.notConfigured.isDetected && !ProviderConnectionState.error("x").isDetected)
        let offline = ProviderUsage.unavailable(.claude, state: .notConfigured)
        check(offline.allMetrics.isEmpty && offline.highestPercent == 0 && offline.highestUrgency == .normal)

        let ollamaTags = Data("{\"models\":[{\"name\":\"qwen2.5-coder:latest\"},{\"name\":\"llama3.3:70b\"}]}".utf8)
        let ollamaPs = Data("{\"models\":[{\"name\":\"llama3.3:70b\",\"size_vram\":42500000000}]}".utf8)
        let ollama = OllamaProvider.makeUsage(tagsData: ollamaTags, psData: ollamaPs, configuredModel: "glm-5.3-flash:cloud")
        check(ollama.planBadge == "2 models" && ollama.allMetrics.isEmpty)
        check(ollama.models.map(\.name) == ["llama3.3:70b", "glm-5.3-flash:cloud"] && ollama.models[0].isRunning)
        check(OllamaProvider.configuredModel(fromTOML: "model = \"glm-5.3-flash:cloud\"\nmodel_provider = \"ollama-launch\"\n[x]\nmodel = \"nope\"") == "glm-5.3-flash:cloud")
        check(OllamaProvider.configuredModel(fromTOML: "[model_providers.x]\nmodel = \"nope\"") == nil)
        // Nothing loaded and no Codex default: fall back to installed models, sized only for local weights
        let installedTags = Data("{\"models\":[{\"name\":\"qwen2.5-coder:latest\",\"size\":4683087561},{\"name\":\"kimi-k2.6:cloud\",\"size\":310},{\"name\":\"a\"},{\"name\":\"b\"},{\"name\":\"c\"}]}".utf8)
        let idleOllama = OllamaProvider.makeUsage(tagsData: installedTags, psData: nil, configuredModel: nil)
        check(idleOllama.models.count == OllamaProvider.installedModelPreviewLimit && idleOllama.models.allSatisfy { !$0.isRunning })
        check(idleOllama.models[0].detail?.hasPrefix("installed · ") == true && idleOllama.models[1].detail == "installed")
        check(idleOllama.planBadge == "5 models")

        // A running ChatGPT desktop app counts as connected, with or without (stale) Codex CLI logs
        let chatGPTRunning = ActiveModel(name: "ChatGPT desktop", detail: "running", isRunning: true)
        check(CodexProvider.makeUsage(events: [], chatGPTApp: chatGPTRunning, now: now).connectionState == .connected)
        check(CodexProvider.makeUsage(events: codexEvents, chatGPTApp: chatGPTRunning, now: now.addingTimeInterval(14.0 * 86400)).connectionState == .connected)
        let chatGPTInstalled = ActiveModel(name: "ChatGPT desktop", detail: "installed")
        check(CodexProvider.makeUsage(events: [], chatGPTApp: chatGPTInstalled, now: now).connectionState == .notConfigured)
        print("✓ Connection state and Ollama tests passed")

        func pct(_ metric: UsageMetric?) -> String { metric.map { "\(Int($0.usedPercent))% used" } ?? "n/a" }

        // 3h. language_server discovery parsing and off-main command runner (CHR-61)
        let psSample = """
          424 /Applications/Antigravity IDE.app/Contents/Resources/app/extensions/antigravity/bin/language_server_macos_arm --csrf_token tok-a --extension_server_port 58983 --extension_server_csrf_token ext-a
         4488 /Applications/Antigravity.app/Contents/Resources/bin/language_server --standalone --csrf_token tok-b
         4505 /Applications/Antigravity.app/Contents/Resources/bin/language_server multicall schedule
          999 /usr/bin/some_other_server --csrf_token nope
        """
        check(AntigravityProvider.parseLanguageServers(psOutput: psSample) == [424: "tok-a", 4488: "tok-b"])
        let lsofSample = """
        COMMAND    PID        USER   FD   TYPE             DEVICE SIZE/OFF NODE NAME
        language_ 4488 chriswander    7u  IPv4 0xa6c05fe5aabd90cf      0t0  TCP 127.0.0.1:64082 (LISTEN)
        language_ 4488 chriswander    8u  IPv4 0x68196f40e3fe2ee1      0t0  TCP 127.0.0.1:64083 (LISTEN)
        language_ 8972 chriswander   24u  IPv6 0x1c3a5d15367ed637      0t0  TCP [::1]:64782 (LISTEN)
        """
        check(AntigravityProvider.parseListeningPorts(lsofOutput: lsofSample) == [4488: [64082, 64083], 8972: [64782]])
        let echoed = await AntigravityProvider.runCommand("/bin/echo", ["gravity"])
        check(echoed == "gravity\n")
        let missingBinary = await AntigravityProvider.runCommand("/nonexistent/binary", [])
        check(missingBinary == "")
        print("✓ language_server discovery parsing tests passed")

        // 3i. UI helpers: path overrides and status item title (CHR-62)
        check(ProviderPaths.resolve(nil, default: "~/d") == "~/d")
        check(ProviderPaths.resolve("", default: "~/d") == "~/d")
        check(ProviderPaths.resolve("  \n", default: "~/d") == "~/d")
        check(ProviderPaths.resolve(" ~/custom.json ", default: "~/d") == "~/custom.json")
        check(StatusBarController.statusTitle(hasReadings: true, usedPercent: 0) == "0%")
        check(StatusBarController.statusTitle(hasReadings: true, usedPercent: 41.6) == "42%")
        check(StatusBarController.statusTitle(hasReadings: false, usedPercent: 0) == "--%")
        print("✓ Path override and status title tests passed")

        // 3j. End-to-end provider fixtures on disk + malformed input + TLS scope (CHR-63)
        await providerFixtureChecks(now: now)
        print("✓ Provider fixture, malformed input and TLS scope tests passed")

        // 3k. URLSession reuse and provider caching (GRBA-1)
        check(AntigravityProvider.sharedSession.delegate === AntigravityProvider.sharedDelegate, "AntigravityProvider must reuse shared delegate")
        check(AntigravityProvider.sharedSession.configuration.timeoutIntervalForRequest == 1.5, "AntigravityProvider session timeout must be 1.5s")
        check(OllamaProvider.sharedSession.configuration.timeoutIntervalForRequest == 1.5, "OllamaProvider session timeout must be 1.5s")

        let delegateCountBefore = LocalhostTrustDelegate.instanceCount
        check(delegateCountBefore > 0, "LocalhostTrustDelegate should be initialized with shared delegate")
        _ = try? await AntigravityProvider().fetchUsage()
        _ = try? await AntigravityProvider().fetchUsage()
        _ = try? await AntigravityProvider().fetchUsage()
        check(LocalhostTrustDelegate.instanceCount == delegateCountBefore, "LocalhostTrustDelegate must not leak across polling cycles")

        let testManager = UsageManager(startPollingImmediately: false)
        let initialClaude = testManager.providers[.claude]
        let initialCodex = testManager.providers[.codex]
        let initialGemini = testManager.providers[.gemini]
        let initialOllama = testManager.providers[.ollama]
        check(initialClaude != nil && initialCodex != nil && initialGemini != nil && initialOllama != nil, "UsageManager must initialize all providers")

        testManager.setupProvidersIfNeeded()
        check(testManager.providers[.claude] === initialClaude as AnyObject, "UsageManager must not recreate providers when config unchanged")
        check(testManager.providers[.gemini] === initialGemini as AnyObject, "UsageManager must not recreate AntigravityProvider when config unchanged")

        let savedClaudeDefault = UserDefaults.standard.object(forKey: "GravityBar_claudePath")
        defer {
            if let saved = savedClaudeDefault {
                UserDefaults.standard.set(saved, forKey: "GravityBar_claudePath")
            } else {
                UserDefaults.standard.removeObject(forKey: "GravityBar_claudePath")
            }
        }
        testManager.claudePath = "/tmp/test-claude-path"
        check(testManager.providers[.claude] !== initialClaude as AnyObject, "UsageManager must recreate ClaudeProvider when path changes")
        if let saved = savedClaudeDefault as? String {
            testManager.claudePath = saved
        }
        print("✓ URLSession reuse and provider caching tests passed")

        // 3n. Idle timer and button update gating (GRBA-4)
        check(!testManager.isPopoverOpen, "Popover should default to closed")
        check(!testManager.isCountdownTimerRunning, "Countdown timer must not run while popover is closed")

        testManager.isPopoverOpen = true
        check(testManager.isCountdownTimerRunning, "Countdown timer must run while popover is open")

        testManager.isPopoverOpen = false
        check(!testManager.isCountdownTimerRunning, "Countdown timer must stop when popover closes")

        let controller = StatusBarController(manager: testManager)
        let initialUpdates = controller.updateCount
        check(initialUpdates > 0, "Controller must initialize button on setup")

        // Calling updateButtonUI with identical title and icon must not reconfigure or increment count
        controller.updateButtonUI()
        controller.updateButtonUI()
        check(controller.updateCount == initialUpdates, "updateButtonUI must be a no-op when title and icon are unchanged")

        // Triggering objectWillChange without changing state must not reconfigure button
        testManager.objectWillChange.send()
        await Task.yield()
        check(controller.updateCount == initialUpdates, "objectWillChange must not trigger button reconfiguration when state is identical")
        print("✓ Idle countdown gating and button update deduplication tests passed")

        // 3o. Reset showingSettings on popover close (GRBA-7)
        let savedGrba7Claude = UserDefaults.standard.object(forKey: "GravityBar_claudePath")
        let savedGrba7Mock = UserDefaults.standard.object(forKey: "GravityBar_isMockMode")
        do {
            defer {
                if let saved = savedGrba7Claude {
                    UserDefaults.standard.set(saved, forKey: "GravityBar_claudePath")
                } else {
                    UserDefaults.standard.removeObject(forKey: "GravityBar_claudePath")
                }
                if let saved = savedGrba7Mock {
                    UserDefaults.standard.set(saved, forKey: "GravityBar_isMockMode")
                } else {
                    UserDefaults.standard.removeObject(forKey: "GravityBar_isMockMode")
                }
            }
            testManager.isMockMode = true

            // Verify openPreferences opens into Settings
            check(!testManager.showingSettings)
            controller.openPreferences()
            check(testManager.showingSettings, "openPreferences must set showingSettings = true")
            check(testManager.isPopoverOpen, "openPreferences must open popover")

            // Popover close without changes resets showingSettings = false
            controller.popoverDidClose(Notification(name: NSPopover.didCloseNotification))
            check(!testManager.showingSettings, "popoverDidClose must reset showingSettings = false")
            check(!testManager.isPopoverOpen, "popoverDidClose must reset isPopoverOpen = false")

            // Popover close with path changes resets showingSettings and triggers refresh
            controller.openPreferences()
            check(testManager.showingSettings)
            testManager.claudePath = "/tmp/test-grba7-path-\(UUID().uuidString)"
            let refreshCountBeforeClose = testManager.refreshCount
            controller.popoverDidClose(Notification(name: NSPopover.didCloseNotification))
            check(!testManager.showingSettings, "popoverDidClose must reset showingSettings = false")
            for _ in 0..<50 {
                if testManager.refreshCount > refreshCountBeforeClose { break }
                try? await Task.sleep(nanoseconds: 20_000_000)
            }
            check(testManager.refreshCount > refreshCountBeforeClose, "popoverDidClose after path changes must trigger refresh")

            // Also verify closePopover resets showingSettings
            controller.openPreferences()
            check(testManager.showingSettings)
            controller.closePopover(nil)
            check(!testManager.showingSettings, "closePopover must reset showingSettings = false")
        }
        let restoredGrba7Claude = UserDefaults.standard.object(forKey: "GravityBar_claudePath")
        let restoredGrba7Mock = UserDefaults.standard.object(forKey: "GravityBar_isMockMode")
        check((savedGrba7Claude == nil && restoredGrba7Claude == nil) || (savedGrba7Claude as? String == restoredGrba7Claude as? String), "UserDefaults claudePath must be restored")
        check((savedGrba7Mock == nil && restoredGrba7Mock == nil) || (savedGrba7Mock as? Bool == restoredGrba7Mock as? Bool), "UserDefaults isMockMode must be restored")
        print("✓ Reset showingSettings on popover close tests passed")

        // 3p. Adaptive design tokens for Light and Dark mode contrast (GRBA-8)
        check(GravityBarTokens.buttonBackground == Color.primary.opacity(0.06), "buttonBackground token must use adaptive Color.primary.opacity(0.06)")
        check(GravityBarTokens.badgeBackground == Color.primary.opacity(0.08), "badgeBackground token must use adaptive Color.primary.opacity(0.08)")
        check(GravityBarTokens.progressTrack == Color.primary.opacity(0.08), "progressTrack token must use adaptive Color.primary.opacity(0.08)")
        check(GravityBarTokens.circularGaugeTrack == Color.primary.opacity(0.09), "circularGaugeTrack token must use adaptive Color.primary.opacity(0.09)")
        check(GravityBarTokens.cardBorder == Color.primary.opacity(0.09), "cardBorder token must use adaptive Color.primary.opacity(0.09)")

        // Verify PopoverView and UsageMetricRowView can render in both light and dark color schemes
        let sampleUsage = ProviderUsage(
            provider: .codex,
            fiveHourMetric: UsageMetric(windowType: .fiveHour, usedPercent: 42.0, resetDate: now.addingTimeInterval(3600)),
            weeklyMetric: UsageMetric(windowType: .weekly, usedPercent: 68.0, resetDate: now.addingTimeInterval(86400)),
            planBadge: "Plus"
        )
        _ = PopoverView(manager: testManager).environment(\.colorScheme, .light)
        _ = PopoverView(manager: testManager).environment(\.colorScheme, .dark)
        _ = UsageMetricRowView(usage: sampleUsage).environment(\.colorScheme, .light)
        _ = UsageMetricRowView(usage: sampleUsage).environment(\.colorScheme, .dark)
        print("✓ Adaptive design tokens and light/dark appearance tests passed")

        // 3q. Hover-to-open cancellation on click and click race protection (GRBA-9)
        guard let hView = controller.hoverView else {
            preconditionFailure("StatusBarController must instantiate HoverTrackingView")
        }

        // Test c1: Mouse enter schedules pendingHover; mouseDown cancels it
        hView.handleMouseEnter()
        check(hView.pendingHover != nil, "handleMouseEnter must schedule pendingHover")
        hView.handleMouseDown()
        check(hView.pendingHover == nil, "mouseDown must cancel pendingHover")

        // Test c1: Mouse enter schedules pendingHover; rightMouseDown cancels it
        hView.handleMouseEnter()
        check(hView.pendingHover != nil, "handleMouseEnter must schedule pendingHover")
        hView.handleRightMouseDown()
        check(hView.pendingHover == nil, "rightMouseDown must cancel pendingHover")

        // Test c1: Mouse enter schedules pendingHover; mouseExit cancels it
        hView.handleMouseEnter()
        check(hView.pendingHover != nil, "handleMouseEnter must schedule pendingHover")
        hView.handleMouseExit()
        check(hView.pendingHover == nil, "mouseExit must cancel pendingHover")

        // Test c1: showContextMenu cancels pendingHover
        hView.handleMouseEnter()
        check(hView.pendingHover != nil, "handleMouseEnter must schedule pendingHover")
        controller.showContextMenu(popUpMenu: false)
        check(hView.pendingHover == nil, "showContextMenu must cancel pendingHover")

        // Test c2: Hover-open records lastHoverOpenTime; immediate left-click is ignored (kept open)
        let savedGrba9HoverToOpen = UserDefaults.standard.object(forKey: "GravityBar_hoverToOpen")
        let originalHoverToOpen = testManager.hoverToOpen
        do {
            defer {
                testManager.hoverToOpen = originalHoverToOpen
                if let saved = savedGrba9HoverToOpen {
                    UserDefaults.standard.set(saved, forKey: "GravityBar_hoverToOpen")
                } else {
                    UserDefaults.standard.removeObject(forKey: "GravityBar_hoverToOpen")
                }
            }
            testManager.hoverToOpen = true

            controller.closePopover(nil)
            check(!testManager.isPopoverOpen)

            // Trigger hover open via onHover closure
            hView.onHover?()
            check(controller.lastHoverOpenTime != nil, "onHover must record lastHoverOpenTime")
            check(testManager.isPopoverOpen, "onHover must open popover")

            // Immediate left-click (within 0.4s) must NOT close the popover
            if let btn = controller.statusItem.button {
                controller.statusItemClicked(btn)
                check(testManager.isPopoverOpen, "Left-click within 400ms of hover-open must keep popover open")

                // Left-click after grace period (>0.4s) closes the popover
                controller.lastHoverOpenTime = Date().addingTimeInterval(-1.0)
                controller.statusItemClicked(btn)
                check(!testManager.isPopoverOpen, "Left-click after grace period must close popover")

                // Normal click-open (not hover) can be closed immediately by another click
                controller.statusItemClicked(btn)
                check(testManager.isPopoverOpen, "Click should open popover")
                check(controller.lastHoverOpenTime == nil, "Click-open must not set lastHoverOpenTime")
                controller.statusItemClicked(btn)
                check(!testManager.isPopoverOpen, "Immediate click after click-open must close popover")
            }
        }
        let restoredGrba9HoverToOpen = UserDefaults.standard.object(forKey: "GravityBar_hoverToOpen")
        check((savedGrba9HoverToOpen == nil && restoredGrba9HoverToOpen == nil) || (savedGrba9HoverToOpen as? Bool == restoredGrba9HoverToOpen as? Bool), "UserDefaults hoverToOpen must be restored")
        print("✓ Hover cancellation and click race protection tests passed")

        // 3r. Empty readings status and popover scroll view sizing (GRBA-10)
        let savedGrba10Providers = UserDefaults.standard.object(forKey: "GravityBar_enabledProviders")
        do {
            defer {
                if let saved = savedGrba10Providers {
                    UserDefaults.standard.set(saved, forKey: "GravityBar_enabledProviders")
                } else {
                    UserDefaults.standard.removeObject(forKey: "GravityBar_enabledProviders")
                }
            }

            // c1: overallStatusText neutral when !hasReadings
            let emptyManager = UsageManager(startPollingImmediately: false)
            emptyManager.providerUsages = [:]
            emptyManager.lastUpdated = nil
            check(!emptyManager.hasReadings, "hasReadings must be false when lastUpdated is nil")
            check(emptyManager.overallStatusText == "No Active Readings", "overallStatusText must be 'No Active Readings' when !hasReadings")

            // c1: hasReadings false when providerUsages has non-detected providers
            let undetectedUsage = ProviderUsage.unavailable(.ollama, state: .notConfigured)
            emptyManager.providerUsages = [.ollama: undetectedUsage]
            emptyManager.lastUpdated = Date()
            check(!emptyManager.hasReadings, "hasReadings must be false when no providers are detected")
            check(emptyManager.overallStatusText == "No Active Readings", "overallStatusText must be 'No Active Readings' when detectedUsages is empty")

            // c1: hasReadings true when detected provider at 0%
            let zeroUsage = ProviderUsage(
                provider: .claude,
                fiveHourMetric: UsageMetric(windowType: .fiveHour, usedPercent: 0.0, resetDate: now.addingTimeInterval(3600)),
                weeklyMetric: nil,
                connectionState: .connected
            )
            emptyManager.providerUsages = [.claude: zeroUsage]
            check(emptyManager.hasReadings, "hasReadings must be true when detected provider is present")
            check(emptyManager.overallStatusText == "Normal / Healthy (0% used)", "overallStatusText must be 'Normal / Healthy (0% used)' when 0% detected")

            // c1: elevated and critical statuses when hasReadings is true
            let elevatedUsage = ProviderUsage(
                provider: .codex,
                fiveHourMetric: UsageMetric(windowType: .fiveHour, usedPercent: 70.0, resetDate: now.addingTimeInterval(3600)),
                weeklyMetric: nil,
                connectionState: .connected
            )
            emptyManager.providerUsages = [.codex: elevatedUsage]
            check(emptyManager.overallStatusText == "Elevated Usage (70% used)", "overallStatusText must be 'Elevated Usage (70% used)'")

            let criticalUsage = ProviderUsage(
                provider: .gemini,
                fiveHourMetric: UsageMetric(windowType: .fiveHour, usedPercent: 92.0, resetDate: now.addingTimeInterval(3600)),
                weeklyMetric: nil,
                connectionState: .connected
            )
            emptyManager.providerUsages = [.gemini: criticalUsage]
            check(emptyManager.overallStatusText == "Critical Quota (92% used)", "overallStatusText must be 'Critical Quota (92% used)'")

            // c2: PopoverView readoutView vertical sizing fits content up to maxHeight: 380
            let sizingManager = UsageManager(startPollingImmediately: false)
            sizingManager.enabledProviders = Set(ProviderType.allCases)
            sizingManager.providerUsages = [:]
            sizingManager.lastUpdated = Date()

            let hcEmpty = NSHostingController(rootView: PopoverView(manager: sizingManager))
            let emptySize = hcEmpty.sizeThatFits(in: CGSize(width: GravityBarTokens.popoverWidth, height: 1000))

            sizingManager.providerUsages = [.claude: zeroUsage]
            let hcOne = NSHostingController(rootView: PopoverView(manager: sizingManager))
            let oneCardSize = hcOne.sizeThatFits(in: CGSize(width: GravityBarTokens.popoverWidth, height: 1000))

            sizingManager.providerUsages = [.claude: zeroUsage, .codex: elevatedUsage]
            let hcTwo = NSHostingController(rootView: PopoverView(manager: sizingManager))
            let twoCardSize = hcTwo.sizeThatFits(in: CGSize(width: GravityBarTokens.popoverWidth, height: 1000))

            let extraUsage = ProviderUsage(
                provider: .ollama,
                fiveHourMetric: UsageMetric(windowType: .fiveHour, usedPercent: 10.0, resetDate: now.addingTimeInterval(3600)),
                weeklyMetric: nil,
                connectionState: .connected
            )
            sizingManager.providerUsages = [.claude: zeroUsage, .codex: elevatedUsage, .gemini: criticalUsage, .ollama: extraUsage]
            let hcFour = NSHostingController(rootView: PopoverView(manager: sizingManager))
            let fourCardSize = hcFour.sizeThatFits(in: CGSize(width: GravityBarTokens.popoverWidth, height: 1000))

            check(emptySize.height < fourCardSize.height, "empty height (\(emptySize.height)) must be smaller than 4 cards height (\(fourCardSize.height))")
            check(oneCardSize.height < fourCardSize.height, "1 card height (\(oneCardSize.height)) must be smaller than 4 cards height (\(fourCardSize.height))")
            check(oneCardSize.height < 350, "1 card height (\(oneCardSize.height)) must hug content and be well below 350pt")
            check(twoCardSize.height > oneCardSize.height, "2 cards height (\(twoCardSize.height)) must be larger than 1 card height (\(oneCardSize.height))")
            check(fourCardSize.height <= 560, "4 cards total height (\(fourCardSize.height)) must be capped by maxHeight 380 constraint")
        }
        let restoredGrba10Providers = UserDefaults.standard.object(forKey: "GravityBar_enabledProviders")
        check((savedGrba10Providers == nil && restoredGrba10Providers == nil) || (savedGrba10Providers as? [String] == restoredGrba10Providers as? [String]), "UserDefaults enabledProviders must be restored")
        print("✓ Empty readings status and popover scroll view sizing tests passed")

        // 3s. Prevent overlapping refreshAll() runs and scope spinner state (GRBA-11)
        let savedGrba11Mock = UserDefaults.standard.object(forKey: "GravityBar_isMockMode")
        let savedGrba11Providers = UserDefaults.standard.object(forKey: "GravityBar_enabledProviders")
        do {
            defer {
                if let saved = savedGrba11Mock {
                    UserDefaults.standard.set(saved, forKey: "GravityBar_isMockMode")
                } else {
                    UserDefaults.standard.removeObject(forKey: "GravityBar_isMockMode")
                }
                if let saved = savedGrba11Providers {
                    UserDefaults.standard.set(saved, forKey: "GravityBar_enabledProviders")
                } else {
                    UserDefaults.standard.removeObject(forKey: "GravityBar_enabledProviders")
                }
            }

            let coalescingManager = UsageManager(startPollingImmediately: false)
            coalescingManager.isMockMode = true
            let initialCount = coalescingManager.refreshCount

            // Launch 5 concurrent refreshAll calls in parallel
            await withTaskGroup(of: Void.self) { group in
                for _ in 0..<5 {
                    group.addTask {
                        await coalescingManager.refreshAll()
                    }
                }
            }

            // 5 concurrent calls must produce at most 2 executions (coalesced pass + at most 1 trailing pass)
            check(coalescingManager.refreshCount <= initialCount + 2, "Concurrent refreshAll calls must produce at most 2 executions (count: \(coalescingManager.refreshCount), expected <= \(initialCount + 2))")
            check(!coalescingManager.isRefreshing, "isRefreshing must be false after coalesced refresh completes")

            let countAfterConcurrent = coalescingManager.refreshCount
            // Sequential refresh after completion must execute as a new refresh
            await coalescingManager.refreshAll()
            check(coalescingManager.refreshCount == countAfterConcurrent + 1, "Sequential refreshAll must execute after previous completed")
            check(!coalescingManager.isRefreshing, "isRefreshing must be false after sequential refresh completes")

            // Trailing-refresh regression check: enable a provider during an in-flight refresh
            let trailingManager = UsageManager(startPollingImmediately: false)
            trailingManager.isMockMode = true
            trailingManager.enabledProviders = [.claude]

            let passCountBefore = trailingManager.refreshPassesStarted
            // Start in-flight refresh for just .claude
            let refreshTask = Task {
                await trailingManager.refreshAll()
            }

            // Yield until the first pass has actually started and captured toFetch
            while trailingManager.refreshPassesStarted == passCountBefore {
                await Task.yield()
            }
            check(trailingManager.isRefreshing, "trailingManager must enter isRefreshing")

            // Enable .codex and request refresh while first pass is in flight
            trailingManager.enabledProviders.insert(.codex)
            await trailingManager.refreshAll()
            await refreshTask.value

            check(trailingManager.providerUsages[.codex] != nil, "Trailing refresh must capture and populate newly enabled .codex usage")
            check(!trailingManager.isRefreshing, "isRefreshing must be false after trailing refresh completes")
        }
        let restoredGrba11Mock = UserDefaults.standard.object(forKey: "GravityBar_isMockMode")
        let restoredGrba11Providers = UserDefaults.standard.object(forKey: "GravityBar_enabledProviders")
        check((savedGrba11Mock == nil && restoredGrba11Mock == nil) || (savedGrba11Mock as? Bool == restoredGrba11Mock as? Bool), "UserDefaults isMockMode must be restored")
        check((savedGrba11Providers == nil && restoredGrba11Providers == nil) || (savedGrba11Providers as? [String] == restoredGrba11Providers as? [String]), "UserDefaults enabledProviders must be restored")
        print("✓ Refresh coalescing guard and popover spinner tests passed")

        // 3t. Codex plan badge formatting and row header layout (GRBA-12)
        // c1 & c3: CodexProvider.formatPlanBadge formatting checks
        check(CodexProvider.formatPlanBadge(nil) == nil, "nil raw badge must return nil")
        check(CodexProvider.formatPlanBadge("") == nil, "empty raw badge must return nil")
        check(CodexProvider.formatPlanBadge("   ") == nil, "whitespace raw badge must return nil")
        check(CodexProvider.formatPlanBadge("self_serve_business_prolite") == "Pro Lite", "self_serve_business_prolite must format to 'Pro Lite'")
        check(CodexProvider.formatPlanBadge("SELF_SERVE_BUSINESS_PROLITE") == "Pro Lite", "SELF_SERVE_BUSINESS_PROLITE must format to 'Pro Lite'")
        check(CodexProvider.formatPlanBadge("chatgpt_plus") == "Plus", "chatgpt_plus must format to 'Plus'")
        check(CodexProvider.formatPlanBadge("plus") == "Plus", "plus must format to 'Plus'")
        check(CodexProvider.formatPlanBadge("Plus") == "Plus", "Plus must format to 'Plus'")
        check(CodexProvider.formatPlanBadge("chatgpt_team") == "Team", "chatgpt_team must format to 'Team'")
        check(CodexProvider.formatPlanBadge("team") == "Team", "team must format to 'Team'")
        check(CodexProvider.formatPlanBadge("chatgpt_enterprise") == "Enterprise", "chatgpt_enterprise must format to 'Enterprise'")
        check(CodexProvider.formatPlanBadge("enterprise") == "Enterprise", "enterprise must format to 'Enterprise'")
        check(CodexProvider.formatPlanBadge("chatgpt_edu") == "Edu", "chatgpt_edu must format to 'Edu'")
        check(CodexProvider.formatPlanBadge("free") == "Free", "free must format to 'Free'")
        check(CodexProvider.formatPlanBadge("self_serve_business") == "Business", "self_serve_business must format to 'Business'")
        check(CodexProvider.formatPlanBadge("self_serve_enterprise_tier") == "Enterprise Tier", "self_serve_enterprise_tier must format to 'Enterprise Tier'")
        check(CodexProvider.formatPlanBadge("custom_plan") == "Custom Plan", "custom_plan must format to 'Custom Plan'")

        // c2: UsageMetricRowView header layout stays single line (no vertical wrap expanding card height)
        func makeTestUsage(badge: String?) -> ProviderUsage {
            ProviderUsage(
                provider: .codex,
                fiveHourMetric: UsageMetric(windowType: .fiveHour, usedPercent: 42.0, resetDate: now.addingTimeInterval(3600)),
                weeklyMetric: UsageMetric(windowType: .weekly, usedPercent: 68.0, resetDate: now.addingTimeInterval(86400)),
                connectionState: .idleCached(lastSeen: now.addingTimeInterval(-22 * 3600)),
                planBadge: badge
            )
        }
        let cardWidth = GravityBarTokens.popoverWidth - 28
        let sizeNil = NSHostingController(rootView: UsageMetricRowView(usage: makeTestUsage(badge: nil)).frame(width: cardWidth)).sizeThatFits(in: CGSize(width: cardWidth, height: 1000))
        let sizeProLite = NSHostingController(rootView: UsageMetricRowView(usage: makeTestUsage(badge: CodexProvider.formatPlanBadge("self_serve_business_prolite"))).frame(width: cardWidth)).sizeThatFits(in: CGSize(width: cardWidth, height: 1000))
        let sizeLong = NSHostingController(rootView: UsageMetricRowView(usage: makeTestUsage(badge: "Enterprise Premium Annual Tier")).frame(width: cardWidth)).sizeThatFits(in: CGSize(width: cardWidth, height: 1000))

        check(sizeNil.height == 154, "Row height without badge must be 154pt (got \(sizeNil.height))")
        check(sizeProLite.height == sizeNil.height, "Row height with Pro Lite badge (\(sizeProLite.height)) must equal nil badge height (\(sizeNil.height))")
        check(sizeLong.height == sizeNil.height, "Row height with long badge (\(sizeLong.height)) must equal nil badge height (\(sizeNil.height))")
        print("✓ Codex plan badge formatting and row header layout tests passed")

        // 3u. Idle Ollama installed models preview and configured model de-duplication (GRBA-13)
        let fiveInstalledTags = Data("""
        {"models":[
            {"name":"qwen2.5-coder:latest","size":4683087561},
            {"name":"llama3.2:latest","size":2000000000},
            {"name":"mistral:latest","size":4000000000},
            {"name":"phi3:latest","size":2500000000},
            {"name":"gemma:latest","size":3000000000}
        ]}
        """.utf8)

        // c1 & c2 & c3: Idle Ollama with configuredModel already in /api/tags
        // Must de-duplicate configuredModel and fill up to installedModelPreviewLimit (4) total rows
        let idleWithConfiguredInTags = OllamaProvider.makeUsage(
            tagsData: fiveInstalledTags,
            psData: nil,
            configuredModel: "qwen2.5-coder:latest"
        )
        check(idleWithConfiguredInTags.models.count == OllamaProvider.installedModelPreviewLimit, "Idle Ollama must fill up to installedModelPreviewLimit rows (got \(idleWithConfiguredInTags.models.count))")
        check(idleWithConfiguredInTags.models.map(\.name) == ["qwen2.5-coder:latest", "llama3.2:latest", "mistral:latest", "phi3:latest"], "Models must include configuredModel first and de-duplicate it from installed tags")
        check(idleWithConfiguredInTags.models.count >= 2 && idleWithConfiguredInTags.models[0].detail == "Codex default model", "Configured model must have 'Codex default model' detail")
        check(idleWithConfiguredInTags.models.count >= 2 && idleWithConfiguredInTags.models[1].detail?.hasPrefix("installed · ") == true, "Installed models must have 'installed · ' detail")
        check(idleWithConfiguredInTags.models.allSatisfy { !$0.isRunning }, "All idle models must have isRunning == false")
        check(idleWithConfiguredInTags.planBadge == "5 models", "planBadge must reflect total installed models count")

        // c1 & c3: Idle Ollama with configuredModel NOT in /api/tags (e.g. cloud or remote model)
        let idleWithConfiguredNotInTags = OllamaProvider.makeUsage(
            tagsData: fiveInstalledTags,
            psData: Data("{\"models\":[]}".utf8),
            configuredModel: "deepseek-r1:cloud"
        )
        check(idleWithConfiguredNotInTags.models.count == OllamaProvider.installedModelPreviewLimit, "Idle Ollama must fill up to installedModelPreviewLimit total rows")
        check(idleWithConfiguredNotInTags.models.map(\.name) == ["deepseek-r1:cloud", "qwen2.5-coder:latest", "llama3.2:latest", "mistral:latest"], "Models must list external configuredModel then up to 3 installed models")
        check(idleWithConfiguredNotInTags.models.count >= 1 && idleWithConfiguredNotInTags.models[0].detail == "Codex default model")
        check(idleWithConfiguredNotInTags.models.allSatisfy { !$0.isRunning })

        // Fewer installed models than preview limit
        let twoInstalledTags = Data("""
        {"models":[
            {"name":"qwen2.5-coder:latest","size":4683087561},
            {"name":"llama3.2:latest","size":2000000000}
        ]}
        """.utf8)
        let idleFewTags = OllamaProvider.makeUsage(
            tagsData: twoInstalledTags,
            psData: nil,
            configuredModel: "deepseek-r1:cloud"
        )
        check(idleFewTags.models.count == 3, "Idle Ollama with 2 tags and configured model must contain 3 models")
        check(idleFewTags.models.map(\.name) == ["deepseek-r1:cloud", "qwen2.5-coder:latest", "llama3.2:latest"])

        // Running models take precedence: no installed models preview when VRAM is active
        let runningPs = Data("{\"models\":[{\"name\":\"llama3.2:latest\",\"size_vram\":5000000000}]}".utf8)
        let runningUsage = OllamaProvider.makeUsage(
            tagsData: fiveInstalledTags,
            psData: runningPs,
            configuredModel: "qwen2.5-coder:latest"
        )
        check(runningUsage.models.count == 2, "Running Ollama must only list running models and configured model")
        check(runningUsage.models.map(\.name) == ["llama3.2:latest", "qwen2.5-coder:latest"])
        check(runningUsage.models.count >= 2 && runningUsage.models[0].isRunning && !runningUsage.models[1].isRunning, "Only running model in psData has isRunning == true")
        print("✓ Idle Ollama installed models preview and de-duplication tests passed")

        // 3v. Suppress fake moving reset countdown on untouched 0% quota windows (GRBA-14)
        // formattedReset remains a pure time formatter for active or synthetic metrics
        let futureReset = now.addingTimeInterval(3600)
        let activeMetric = UsageMetric(windowType: .fiveHour, usedPercent: 42.0, resetDate: futureReset)
        check(activeMetric.formattedReset(relativeTo: now) == "Resets in 1h 0m", "Active window must format countdown")

        let expiredMetric = UsageMetric(windowType: .fiveHour, usedPercent: 10.0, resetDate: now.addingTimeInterval(-10))
        check(expiredMetric.formattedReset(relativeTo: now) == "Resets momentarily", "Expired window must format as 'Resets momentarily'")

        // Regression check: nextResetCountdownText with detected usage >0% must start with "Resets in"
        let resetTestManager = UsageManager(startPollingImmediately: false)
        let singleUsage = ProviderUsage(
            provider: .claude,
            fiveHourMetric: UsageMetric(windowType: .fiveHour, usedPercent: 50.0, resetDate: now.addingTimeInterval((2 * 3600) + (10 * 60))),
            weeklyMetric: nil,
            connectionState: .connected
        )
        resetTestManager.providerUsages = [.claude: singleUsage]
        check(resetTestManager.nextResetCountdownText.hasPrefix("Resets in"), "nextResetCountdownText must start with 'Resets in' when active usage has pending reset (got \(resetTestManager.nextResetCountdownText))")

        // When all detected windows are untouched at 0%, nextResetCountdownText must report "None pending"
        let zeroUsage = ProviderUsage(
            provider: .claude,
            fiveHourMetric: UsageMetric(windowType: .fiveHour, usedPercent: 0.0, resetDate: now.addingTimeInterval(5 * 3600)),
            weeklyMetric: UsageMetric(windowType: .weekly, usedPercent: 0.0, resetDate: now.addingTimeInterval(7 * 86400)),
            connectionState: .connected
        )
        resetTestManager.providerUsages = [.claude: zeroUsage]
        check(resetTestManager.nextResetCountdownText == "None pending", "nextResetCountdownText must be 'None pending' when all windows are 0%")

        // UsageMetricRowView renders "Window idle" without changing card height
        let idleCardUsage = ProviderUsage(
            provider: .claude,
            fiveHourMetric: UsageMetric(windowType: .fiveHour, usedPercent: 0.0, resetDate: now.addingTimeInterval(5 * 3600)),
            weeklyMetric: UsageMetric(windowType: .weekly, usedPercent: 40.0, resetDate: now.addingTimeInterval(86400)),
            connectionState: .connected
        )
        let activeCardUsage = ProviderUsage(
            provider: .claude,
            fiveHourMetric: UsageMetric(windowType: .fiveHour, usedPercent: 20.0, resetDate: now.addingTimeInterval(5 * 3600)),
            weeklyMetric: UsageMetric(windowType: .weekly, usedPercent: 40.0, resetDate: now.addingTimeInterval(86400)),
            connectionState: .connected
        )
        let idleHeight = NSHostingController(rootView: UsageMetricRowView(usage: idleCardUsage).frame(width: cardWidth)).sizeThatFits(in: CGSize(width: cardWidth, height: 1000)).height
        let activeHeight = NSHostingController(rootView: UsageMetricRowView(usage: activeCardUsage).frame(width: cardWidth)).sizeThatFits(in: CGSize(width: cardWidth, height: 1000)).height
        check(idleHeight == activeHeight, "Card height with 'Window idle' (\(idleHeight)) must match card height with active countdown (\(activeHeight))")
        print("✓ Idle window reset countdown suppression tests passed")

        // MARK: Live machine smoke output (informational)
        // Reads whatever is installed on this Mac. Nothing here can fail the run: on CI these sources are
        // absent, and the deterministic fixture checks above are what gate the build.
        print("— Live data on this machine (informational) —")

        // 4. Claude Real Data Provider Test
        let claudeProv = ClaudeProvider()
        if let u = try? await claudeProv.fetchUsage() {
            check(u.provider == .claude)
            print("• live Claude: 5h=\(pct(u.fiveHourMetric)), long window=\(pct(u.weeklyMetric)), state=\(u.connectionState.label() ?? "connected")")
            print("    • 5h \(u.fiveHourMetric?.formattedReset() ?? "n/a"), weekly \(u.weeklyMetric?.formattedReset() ?? "n/a")")
            if let cli = u.cliTokenUsage {
                print("    • Claude Code CLI last 5h: \(cli.last5h.summary)")
                print("    • Claude Code CLI last 7d: \(cli.last7d.summary)")
            }
        }

        // 4b. Codex Real Data Provider Test
        if let u = try? await CodexProvider().fetchUsage() {
            check(u.provider == .codex)
            print("• live Codex: 5h=\(pct(u.fiveHourMetric)), long window=\(pct(u.weeklyMetric)), state=\(u.connectionState.label() ?? "connected")")
            print("    • plan=\(u.planBadge ?? "-"), models=\(u.models.map(\.name)), weekly=\(u.weeklyMetric.map { "\($0.windowType.rawValue) \($0.usageSummary), \($0.formattedReset())" } ?? "n/a")")
            if let cli = u.cliTokenUsage {
                print("    • Codex CLI last 7d: \(cli.last7d.summary)")
            }
        }

        // 4c. Ollama Real Data Provider Test
        if let u = try? await OllamaProvider().fetchUsage() {
            print("• live Ollama: state=\(u.connectionState.label() ?? "connected"), badge=\(u.planBadge ?? "-"), models=\(u.models.map { "\($0.name) (\($0.detail ?? ""))" })")
        }

        // 5. Antigravity Real Data Provider Test
        let geminiProv = AntigravityProvider()
        let coldStart = Date()
        _ = try? await geminiProv.fetchUsage()
        let coldMs = Int(Date().timeIntervalSince(coldStart) * 1000)
        let warmStart = Date()
        if let u = try? await geminiProv.fetchUsage() {
            check(u.provider == .gemini)
            let warmMs = Int(Date().timeIntervalSince(warmStart) * 1000)
            print("• live Antigravity: 5h=\(pct(u.fiveHourMetric)), long window=\(pct(u.weeklyMetric)), state=\(u.connectionState.label() ?? "connected")")
            print("    • first fetch (discovery) \(coldMs)ms, second fetch \(warmMs)ms (cached endpoints)")
            for group in u.groups {
                print("    • \(group.name): " + group.metrics.map { "\($0.windowType.rawValue)=\($0.usageSummary)" }.joined(separator: ", "))
            }
        }

        if failures == 0 {
            print("All GravityBar self-tests passed successfully!")
            return 0
        }
        print("✗ \(failures) self-test check(s) failed")
        return 1
    }

    /// Writes fixture files to a temp directory and runs the real Claude and Codex providers against them,
    /// so the full read → parse → window pipeline is checked without depending on this machine's data.
    private static func providerFixtureChecks(now: Date) async {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("gravitybar-fixtures-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: root) }
        func write(_ text: String, to relativePath: String, modified: Date? = nil) {
            let url = root.appendingPathComponent(relativePath)
            try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? Data(text.utf8).write(to: url)
            if let modified {
                try? fm.setAttributes([.modificationDate: modified], ofItemAtPath: url.path)
            }
        }
        func ms(minutesAgo: Double) -> Int { Int((now.timeIntervalSince1970 - minutesAgo * 60) * 1000) }
        func iso(minutesAgo: Double) -> String { ISO8601DateFormatter().string(from: now.addingTimeInterval(-minutesAgo * 60)) }

        // Claude: active 5h window that started 60 min ago, weekly window from 2 days ago
        write("""
        {"version":1,"samples":[
          {"t":\(ms(minutesAgo: 3000)),"org":"o","u":{"fh":0,"sd":0}},
          {"t":\(ms(minutesAgo: 2880)),"org":"o","u":{"fh":4,"sd":2}},
          {"t":\(ms(minutesAgo: 2800)),"org":"o","u":{"fh":0,"sd":2}},
          {"t":\(ms(minutesAgo: 60)),"org":"o","u":{"fh":12,"sd":9}},
          {"t":\(ms(minutesAgo: 2)),"org":"o","u":{"fh":31,"sd":11}}
        ]}
        """, to: "claude/plan-usage-history.json")
        write("""
        {"type":"assistant","timestamp":"\(iso(minutesAgo: 30))","message":{"id":"m1","usage":{"input_tokens":10,"output_tokens":0,"cache_read_input_tokens":0,"cache_creation_input_tokens":0}}}
        {"type":"assistant","timestamp":"\(iso(minutesAgo: 30))","message":{"id":"m1","usage":{"input_tokens":10,"output_tokens":900,"cache_read_input_tokens":5000,"cache_creation_input_tokens":100}}}
        """, to: "claude/projects/-Users-x/session.jsonl")

        let claude = try? await ClaudeProvider(
            customStatePath: root.appendingPathComponent("claude/plan-usage-history.json").path,
            cliProjectsPath: root.appendingPathComponent("claude/projects").path
        ).fetchUsage()
        check(claude?.connectionState == .connected)
        check(claude?.fiveHourMetric?.usedPercent == 31)
        let fhRemaining = claude?.fiveHourMetric?.resetDate.timeIntervalSince(now) ?? 0
        let expectedFH: TimeInterval = 4 * 3600
        check(abs(fhRemaining - expectedFH) < 5, "5h resets from window start")
        check(claude?.weeklyMetric?.usedPercent == 11)
        let sdRemaining = claude?.weeklyMetric?.resetDate.timeIntervalSince(now) ?? 0
        let expectedSD: TimeInterval = 5 * 86400
        check(abs(sdRemaining - expectedSD) < 5, "7d resets from window start")
        check(claude?.cliTokenUsage?.last5h == TokenUsage(inputTokens: 10, outputTokens: 900, cacheReadTokens: 5000, cacheCreationTokens: 100))

        // Claude: both windows expired (Claude closed 8 days) → 0%, idle
        write("""
        {"version":1,"samples":[{"t":\(ms(minutesAgo: 8.0 * 1440)),"org":"o","u":{"fh":78,"sd":60}}]}
        """, to: "claude-stale/plan-usage-history.json")
        let staleClaude = try? await ClaudeProvider(
            customStatePath: root.appendingPathComponent("claude-stale/plan-usage-history.json").path,
            cliProjectsPath: root.appendingPathComponent("claude-stale/none").path
        ).fetchUsage()
        check(staleClaude?.fiveHourMetric?.usedPercent == 0 && staleClaude?.weeklyMetric?.usedPercent == 0)
        if case .idleCached = staleClaude?.connectionState {} else { check(false, "stale Claude should be idle") }

        // Claude: nothing on disk → not configured, no metrics
        let missingClaude = try? await ClaudeProvider(
            customStatePath: root.appendingPathComponent("nope.json").path,
            cliProjectsPath: root.appendingPathComponent("nope").path
        ).fetchUsage()
        check(missingClaude?.connectionState == .notConfigured && missingClaude?.allMetrics.isEmpty == true)

        // Codex: rollout under sessions/YYYY/MM/DD with weekly primary + 5h secondary
        let weeklyReset = Int(now.addingTimeInterval(3 * 86400).timeIntervalSince1970)
        let fiveHourReset = Int(now.addingTimeInterval(2 * 3600).timeIntervalSince1970)
        write("""
        {"timestamp":"\(iso(minutesAgo: 400))","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":1000,"cached_input_tokens":400,"cache_write_input_tokens":0,"output_tokens":50,"reasoning_output_tokens":10,"total_tokens":1050}},"rate_limits":{"limit_id":"codex","primary":{"used_percent":20.0,"window_minutes":10080,"resets_at":\(weeklyReset)},"secondary":null,"plan_type":"plus"}}}
        {"timestamp":"\(iso(minutesAgo: 5))","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":3000,"cached_input_tokens":2400,"cache_write_input_tokens":0,"output_tokens":250,"reasoning_output_tokens":60,"total_tokens":3250}},"rate_limits":{"limit_id":"codex","primary":{"used_percent":27.0,"window_minutes":10080,"resets_at":\(weeklyReset)},"secondary":{"used_percent":64.0,"window_minutes":300,"resets_at":\(fiveHourReset)},"plan_type":"plus"}}}
        """, to: "codex/sessions/2026/10/24/rollout-2026-10-24T10-00-00-abc.jsonl")
        write("not a rollout", to: "codex/sessions/2026/10/24/notes.txt")

        let codex = try? await CodexProvider(customStatePath: root.appendingPathComponent("codex/sessions").path).fetchUsage()
        check(codex?.fiveHourMetric?.usedPercent == 64 && codex?.weeklyMetric?.usedPercent == 27)
        check(codex?.planBadge == "Plus")
        check(codex?.cliTokenUsage?.last5h == TokenUsage(inputTokens: 600 - 600, outputTokens: 200, cacheReadTokens: 2000, cacheCreationTokens: 0), "5h delta: input 2000 incl. 2000 cached")
        check(codex?.cliTokenUsage?.last7d == TokenUsage(inputTokens: 600, outputTokens: 250, cacheReadTokens: 2400, cacheCreationTokens: 0))

        // Codex: 7-day scan window and fallback (GRBA-2)
        CodexRolloutScanner.clearCache()
        let oldModified = now.addingTimeInterval(-14 * 86400)
        let recentModified = now.addingTimeInterval(-2 * 86400)
        write("""
        {"timestamp":"\(iso(minutesAgo: 14 * 1440))","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":500,"cached_input_tokens":0,"cache_write_input_tokens":0,"output_tokens":50,"reasoning_output_tokens":0,"total_tokens":550}},"rate_limits":{"limit_id":"codex","primary":{"used_percent":10.0,"window_minutes":10080,"resets_at":\(Int(oldModified.timeIntervalSince1970))},"secondary":null,"plan_type":"plus"}}}
        """, to: "codex-window/sessions/2026/10/15/rollout-old.jsonl", modified: oldModified)
        write("""
        {"timestamp":"\(iso(minutesAgo: 2 * 1440))","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":800,"cached_input_tokens":0,"cache_write_input_tokens":0,"output_tokens":80,"reasoning_output_tokens":0,"total_tokens":880}},"rate_limits":{"limit_id":"codex","primary":{"used_percent":40.0,"window_minutes":10080,"resets_at":\(Int(recentModified.timeIntervalSince1970))},"secondary":null,"plan_type":"plus"}}}
        """, to: "codex-window/sessions/2026/10/27/rollout-recent.jsonl", modified: recentModified)

        let mixedEvents = CodexRolloutScanner.scan(path: root.appendingPathComponent("codex-window/sessions").path, now: now)
        check(mixedEvents.contains { $0.session.contains("rollout-recent.jsonl") }, "Recent rollout file must be parsed")
        check(!mixedEvents.contains { $0.session.contains("rollout-old.jsonl") }, "Rollout file older than 7d must be skipped when newer files exist")

        // Codex: when all files are older than 7 days, fall back to the single most recent older file
        CodexRolloutScanner.clearCache()
        let veryOldModified = now.addingTimeInterval(-30 * 86400)
        let latestOldModified = now.addingTimeInterval(-10 * 86400)
        let futureWeeklyReset = Int(now.addingTimeInterval(4 * 86400).timeIntervalSince1970)
        write("""
        {"timestamp":"\(iso(minutesAgo: 30 * 1440))","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":200,"cached_input_tokens":0,"cache_write_input_tokens":0,"output_tokens":20,"reasoning_output_tokens":0,"total_tokens":220}},"rate_limits":{"limit_id":"codex","primary":{"used_percent":5.0,"window_minutes":10080,"resets_at":\(Int(veryOldModified.timeIntervalSince1970))},"secondary":null,"plan_type":"plus"}}}
        """, to: "codex-idle/sessions/2026/09/29/rollout-very-old.jsonl", modified: veryOldModified)
        write("""
        {"timestamp":"\(iso(minutesAgo: 10 * 1440))","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":300,"cached_input_tokens":0,"cache_write_input_tokens":0,"output_tokens":30,"reasoning_output_tokens":0,"total_tokens":330}},"rate_limits":{"limit_id":"codex","primary":{"used_percent":15.0,"window_minutes":10080,"resets_at":\(futureWeeklyReset)},"secondary":null,"plan_type":"plus"}}}
        """, to: "codex-idle/sessions/2026/10/19/rollout-latest-old.jsonl", modified: latestOldModified)

        let idleEvents = CodexRolloutScanner.scan(path: root.appendingPathComponent("codex-idle/sessions").path, now: now)
        check(idleEvents.contains { $0.session.contains("rollout-latest-old.jsonl") }, "Latest old rollout file must be parsed as fallback")
        check(!idleEvents.contains { $0.session.contains("rollout-very-old.jsonl") }, "Older rollout files beyond the latest must be skipped")

        // Deterministic check without live machine app state
        let idleUsage = CodexProvider.makeUsage(events: idleEvents, chatGPTApp: nil, now: now)
        if case let .idleCached(lastSeen) = idleUsage.connectionState {
            check(abs(lastSeen.timeIntervalSince(now.addingTimeInterval(-10 * 86400))) < 5, "lastSeen must equal latest-old event timestamp")
        } else {
            check(false, "Codex idle >7d must report connectionState .idleCached")
        }
        check(idleUsage.weeklyMetric?.usedPercent == 15.0, "Active weekly window from fallback file must be surfaced")
        check(idleUsage.weeklyMetric?.windowType == .weekly, "Fallback window should be weekly")
        let resetDiff = idleUsage.weeklyMetric?.resetDate.timeIntervalSince(now) ?? 0
        check(abs(resetDiff - 4 * 86400) < 5, "Fallback window resetDate must match future resets_at")

        // 3m. CLI scanner cache eviction (GRBA-3)
        // ClaudeCodeUsageScanner cache pruning on deletion and aging out
        ClaudeCodeUsageScanner.clearCache()
        check(ClaudeCodeUsageScanner.cachedCount == 0)
        let claudeCacheDir = "claude-cache-test"
        write("""
        {"type":"assistant","timestamp":"\(iso(minutesAgo: 1440))","message":{"id":"m1","usage":{"input_tokens":10,"output_tokens":10,"cache_read_input_tokens":0,"cache_creation_input_tokens":0}}}
        """, to: "\(claudeCacheDir)/p1/session.jsonl", modified: now.addingTimeInterval(-86400))
        write("""
        {"type":"assistant","timestamp":"\(iso(minutesAgo: 2880))","message":{"id":"m2","usage":{"input_tokens":20,"output_tokens":20,"cache_read_input_tokens":0,"cache_creation_input_tokens":0}}}
        """, to: "\(claudeCacheDir)/p2/session.jsonl", modified: now.addingTimeInterval(-2 * 86400))

        let claudeScanDir = root.appendingPathComponent(claudeCacheDir).path
        _ = ClaudeCodeUsageScanner.scan(projectsPath: claudeScanDir, now: now)
        check(ClaudeCodeUsageScanner.cachedCount == 2, "Claude scanner must cache both active files")

        // Delete file 1 -> must be evicted from cache
        try? fm.removeItem(at: root.appendingPathComponent("\(claudeCacheDir)/p1/session.jsonl"))
        _ = ClaudeCodeUsageScanner.scan(projectsPath: claudeScanDir, now: now)
        check(ClaudeCodeUsageScanner.cachedCount == 1, "Deleted file must be evicted from Claude cache")

        // Age file 2 past 7 days -> must be evicted from cache
        let oldDate = now.addingTimeInterval(-10 * 86400)
        try? fm.setAttributes([.modificationDate: oldDate], ofItemAtPath: root.appendingPathComponent("\(claudeCacheDir)/p2/session.jsonl").path)
        _ = ClaudeCodeUsageScanner.scan(projectsPath: claudeScanDir, now: now)
        check(ClaudeCodeUsageScanner.cachedCount == 0, "Aged-out file (>7d) must be evicted from Claude cache")

        // CodexRolloutScanner cache pruning on deletion and aging out
        CodexRolloutScanner.clearCache()
        check(CodexRolloutScanner.cachedCount == 0)
        let codexCacheDir = "codex-cache-test"
        let codexScanDir = root.appendingPathComponent(codexCacheDir).path
        write("""
        {"timestamp":"\(iso(minutesAgo: 1440))","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":100,"cached_input_tokens":0,"cache_write_input_tokens":0,"output_tokens":10,"reasoning_output_tokens":0,"total_tokens":110}}}}
        """, to: "\(codexCacheDir)/rollout-1.jsonl", modified: now.addingTimeInterval(-86400))
        write("""
        {"timestamp":"\(iso(minutesAgo: 2880))","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":200,"cached_input_tokens":0,"cache_write_input_tokens":0,"output_tokens":20,"reasoning_output_tokens":0,"total_tokens":220}}}}
        """, to: "\(codexCacheDir)/rollout-2.jsonl", modified: now.addingTimeInterval(-2 * 86400))

        _ = CodexRolloutScanner.scan(path: codexScanDir, now: now)
        check(CodexRolloutScanner.cachedCount == 2, "Codex scanner must cache both active rollout files")

        // Delete file 1 -> must be evicted from cache
        try? fm.removeItem(at: root.appendingPathComponent("\(codexCacheDir)/rollout-1.jsonl"))
        _ = CodexRolloutScanner.scan(path: codexScanDir, now: now)
        check(CodexRolloutScanner.cachedCount == 1, "Deleted file must be evicted from Codex cache")

        // Add older file (>7d) and newer file -> older file must not be cached
        write("""
        {"timestamp":"\(iso(minutesAgo: 14 * 1440))","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":300,"cached_input_tokens":0,"cache_write_input_tokens":0,"output_tokens":30,"reasoning_output_tokens":0,"total_tokens":330}}}}
        """, to: "\(codexCacheDir)/rollout-3.jsonl", modified: now.addingTimeInterval(-14 * 86400))
        _ = CodexRolloutScanner.scan(path: codexScanDir, now: now)
        check(CodexRolloutScanner.cachedCount == 1, "Older file (>7d) must not be in cache when recent file exists")

        // Malformed input never crashes and yields nothing
        let garbage = Data("{not json\n\u{0}\u{1}".utf8)
        check(ClaudeProvider.parseSamples(from: garbage).isEmpty)
        check(AntigravityProvider.parseQuotaGroups(from: garbage) == nil)
        check(AntigravityProvider.parseQuotaGroups(from: Data("{\"response\":{\"groups\":\"oops\"}}".utf8)) == nil)
        check(CodexRolloutScanner.parseEvents(from: garbage, session: "g").isEmpty)
        check(ClaudeCodeUsageScanner.parseEntries(from: garbage).isEmpty)
        check(OllamaProvider.makeUsage(tagsData: garbage, psData: garbage, configuredModel: nil).models.isEmpty)

        // TLS trust is limited to loopback server-trust challenges
        check(LocalhostTrustDelegate.shouldTrust(host: "127.0.0.1", authenticationMethod: NSURLAuthenticationMethodServerTrust))
        check(LocalhostTrustDelegate.shouldTrust(host: "LOCALHOST", authenticationMethod: NSURLAuthenticationMethodServerTrust))
        check(LocalhostTrustDelegate.shouldTrust(host: "::1", authenticationMethod: NSURLAuthenticationMethodServerTrust))
        check(!LocalhostTrustDelegate.shouldTrust(host: "api.openai.com", authenticationMethod: NSURLAuthenticationMethodServerTrust))
        check(!LocalhostTrustDelegate.shouldTrust(host: "127.0.0.1.evil.com", authenticationMethod: NSURLAuthenticationMethodServerTrust))
        check(!LocalhostTrustDelegate.shouldTrust(host: "127.0.0.1", authenticationMethod: NSURLAuthenticationMethodHTTPBasic))

        // 3n. Provider toggle and path updates in Settings (GRBA-6)
        let savedIsMockMode = UserDefaults.standard.object(forKey: "GravityBar_isMockMode")
        let savedClaudePath = UserDefaults.standard.object(forKey: "GravityBar_claudePath")
        let savedCodexPath = UserDefaults.standard.object(forKey: "GravityBar_codexPath")
        let savedEnabledProviders = UserDefaults.standard.object(forKey: "GravityBar_enabledProviders")

        do {
            defer {
                if let saved = savedIsMockMode {
                    UserDefaults.standard.set(saved, forKey: "GravityBar_isMockMode")
                } else {
                    UserDefaults.standard.removeObject(forKey: "GravityBar_isMockMode")
                }
                if let saved = savedClaudePath {
                    UserDefaults.standard.set(saved, forKey: "GravityBar_claudePath")
                } else {
                    UserDefaults.standard.removeObject(forKey: "GravityBar_claudePath")
                }
                if let saved = savedCodexPath {
                    UserDefaults.standard.set(saved, forKey: "GravityBar_codexPath")
                } else {
                    UserDefaults.standard.removeObject(forKey: "GravityBar_codexPath")
                }
                if let saved = savedEnabledProviders {
                    UserDefaults.standard.set(saved, forKey: "GravityBar_enabledProviders")
                } else {
                    UserDefaults.standard.removeObject(forKey: "GravityBar_enabledProviders")
                }
            }

            let testManager = UsageManager(startPollingImmediately: false)
            testManager.isMockMode = true

            // Initial setup with ollama disabled
            if testManager.enabledProviders.contains(.ollama) {
                testManager.toggleProvider(.ollama)
            }
            let countAfterDisable = testManager.refreshCount

            // 1. Toggling on a disabled provider triggers refreshAll()
            testManager.toggleProvider(.ollama)
            check(testManager.enabledProviders.contains(.ollama), "toggleProvider must enable provider")
            for _ in 0..<50 {
                if testManager.refreshCount > countAfterDisable { break }
                try? await Task.sleep(nanoseconds: 20_000_000)
            }
            check(testManager.refreshCount > countAfterDisable, "toggleProvider on must trigger refreshAll()")

            // 2. Settings dismissal: when paths have changed, dismissSettings triggers refreshAll()
            testManager.showingSettings = true
            testManager.claudePath = "/tmp/test-claude-path-\(UUID().uuidString)"
            let countBeforeDismiss = testManager.refreshCount
            testManager.dismissSettings()
            check(!testManager.showingSettings, "dismissSettings must close settings")
            for _ in 0..<50 {
                if testManager.refreshCount > countBeforeDismiss { break }
                try? await Task.sleep(nanoseconds: 20_000_000)
            }
            check(testManager.refreshCount > countBeforeDismiss, "dismissSettings after path modification must trigger refreshAll()")

            // 3. Settings dismissal without changes does NOT trigger refreshAll()
            testManager.showingSettings = true
            let countBeforeNoop = testManager.refreshCount
            testManager.dismissSettings()
            check(!testManager.showingSettings, "dismissSettings without changes must close settings")
            try? await Task.sleep(nanoseconds: 50_000_000)
            check(testManager.refreshCount == countBeforeNoop, "dismissSettings without modifications must not trigger refreshAll()")

            // 4. Apply & Close (forceRefresh) always triggers refreshAll()
            testManager.showingSettings = true
            let countBeforeApply = testManager.refreshCount
            testManager.dismissSettings(forceRefresh: true)
            check(!testManager.showingSettings, "dismissSettings with forceRefresh must close settings")
            for _ in 0..<50 {
                if testManager.refreshCount > countBeforeApply { break }
                try? await Task.sleep(nanoseconds: 20_000_000)
            }
            check(testManager.refreshCount > countBeforeApply, "dismissSettings with forceRefresh must trigger refreshAll()")

            // 5. Direct showingSettings dismissal with path modification triggers refreshAll()
            testManager.showingSettings = true
            testManager.codexPath = "/tmp/test-codex-path-\(UUID().uuidString)"
            let countBeforeShowingDismiss = testManager.refreshCount
            testManager.showingSettings = false
            for _ in 0..<50 {
                if testManager.refreshCount > countBeforeShowingDismiss { break }
                try? await Task.sleep(nanoseconds: 20_000_000)
            }
            check(testManager.refreshCount > countBeforeShowingDismiss, "setting showingSettings = false after path modification must trigger refreshAll()")

            // 6. SettingsView dismiss calls manager.dismissSettings
            testManager.showingSettings = true
            let settingsView = SettingsView(manager: testManager)
            settingsView.dismiss()
            check(!testManager.showingSettings, "SettingsView.dismiss must close settings via UsageManager")
        }

        // 7. Verify UserDefaults restored
        let currentMock = UserDefaults.standard.object(forKey: "GravityBar_isMockMode")
        let currentClaude = UserDefaults.standard.object(forKey: "GravityBar_claudePath")
        let currentCodex = UserDefaults.standard.object(forKey: "GravityBar_codexPath")
        let currentProviders = UserDefaults.standard.object(forKey: "GravityBar_enabledProviders")
        check((savedIsMockMode == nil && currentMock == nil) || (savedIsMockMode as? Bool == currentMock as? Bool), "UserDefaults isMockMode must be restored")
        check((savedClaudePath == nil && currentClaude == nil) || (savedClaudePath as? String == currentClaude as? String), "UserDefaults claudePath must be restored")
        check((savedCodexPath == nil && currentCodex == nil) || (savedCodexPath as? String == currentCodex as? String), "UserDefaults codexPath must be restored")
        check((savedEnabledProviders == nil && currentProviders == nil) || (savedEnabledProviders as? [String] == currentProviders as? [String]), "UserDefaults enabledProviders must be restored")

        print("✓ Provider toggle and Settings refresh tests passed")
    }
}
