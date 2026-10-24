import Foundation

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

        // Protobuf JSON timestamps may include fractional seconds
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
        check(activeFH.usedPercent == 23 && abs(activeFH.resetDate.timeIntervalSince(now) - (5 * 3600 - 60 * 60)) < 1)
        check(activeSD.usedPercent == 5 && abs(activeSD.resetDate.timeIntervalSince(now) - (7 * 86400 - 60 * 60)) < 1)

        // Step down means the window reset between samples: new window starts at the lower reading
        let (steppedFH, _) = windows(planSamples([(200, 40, 10), (120, 5, 10)]))
        check(steppedFH.usedPercent == 5 && abs(steppedFH.resetDate.timeIntervalSince(now) - (5 * 3600 - 120 * 60)) < 1)

        // Stale: Claude closed for 6h, so the 5h window expired and decays to 0%; weekly still active
        let (staleFH, staleSD) = windows(planSamples([(400, 60, 20), (360, 78, 22)]))
        check(staleFH.usedPercent == 0 && staleSD.usedPercent == 22)

        // Weekly expires after 7 days
        let (_, expiredSD) = windows(planSamples([(8 * 24 * 60, 50, 30)]))
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
            cliLine("msg_b", minutesAgo: 6 * 60, input: 7, output: 70),   // 7d only
            cliLine("msg_c", minutesAgo: 8 * 24 * 60, input: 9, output: 90) // outside 7d
        ].joined(separator: "\n").utf8)
        let cli = ClaudeCodeUsageScanner.aggregate(ClaudeCodeUsageScanner.parseEntries(from: transcript), now: now)
        check(cli.last5h == TokenUsage(inputTokens: 5, outputTokens: 50, cacheReadTokens: 100, cacheCreationTokens: 10))
        check(cli.last5h.outputTokens == 50, "Streamed message must keep its final output_tokens, not the early 0")

        // A recently touched transcript holding only old messages must not surface an empty CLI section
        let staleDir = FileManager.default.temporaryDirectory.appendingPathComponent("gravitybar-cli-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: staleDir, withIntermediateDirectories: true)
        try? Data(cliLine("msg_old", minutesAgo: 30 * 24 * 60, input: 1, output: 1).utf8).write(to: staleDir.appendingPathComponent("old.jsonl"))
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
            codexEvent(minutesAgo: 8 * 60, windows: "\"primary\":{\"used_percent\":40.0,\"window_minutes\":10080,\"resets_at\":\(inOneDay)},\"secondary\":null", input: 1_000, cached: 600, output: 100),
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
        check(CodexProvider.makeUsage(events: codexEvents, chatGPTApp: chatGPTRunning, now: now.addingTimeInterval(14 * 86400)).connectionState == .connected)
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
        func write(_ text: String, to relativePath: String) {
            let url = root.appendingPathComponent(relativePath)
            try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? Data(text.utf8).write(to: url)
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
        check(abs((claude?.fiveHourMetric?.resetDate.timeIntervalSince(now) ?? 0) - (5 * 3600 - 3600)) < 5, "5h resets from window start")
        check(claude?.weeklyMetric?.usedPercent == 11)
        check(abs((claude?.weeklyMetric?.resetDate.timeIntervalSince(now) ?? 0) - (7 * 86400 - 2880 * 60)) < 5, "7d resets from window start")
        check(claude?.cliTokenUsage?.last5h == TokenUsage(inputTokens: 10, outputTokens: 900, cacheReadTokens: 5000, cacheCreationTokens: 100))

        // Claude: both windows expired (Claude closed 8 days) → 0%, idle
        write("""
        {"version":1,"samples":[{"t":\(ms(minutesAgo: 8 * 1440)),"org":"o","u":{"fh":78,"sd":60}}]}
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
    }
}
