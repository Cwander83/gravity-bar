import SwiftUI
import AppKit

@main
struct GravityBarApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        Settings {
            EmptyView()
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusBarController: StatusBarController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        if CommandLine.arguments.contains("--test") {
            Task {
                await runSelfTestsAsync()
                exit(0)
            }
            return
        }

        // Run as menu bar accessory (hide Dock icon)
        NSApp.setActivationPolicy(.accessory)
        statusBarController = StatusBarController(manager: .shared)
    }

    private func runSelfTestsAsync() async {
        print("Running GravityBar Self-Tests...")

        // 1. Thresholds
        assert(QuotaThreshold.from(usedPercent: 0.0) == .normal)
        assert(QuotaThreshold.from(usedPercent: 59.9) == .normal)
        assert(QuotaThreshold.from(usedPercent: 60.0) == .warning)
        assert(QuotaThreshold.from(usedPercent: 85.0) == .warning)
        assert(QuotaThreshold.from(usedPercent: 85.1) == .critical)
        assert(QuotaThreshold.from(usedPercent: 100.0) == .critical)
        print("✓ Quota threshold tests passed")

        // 2. Countdowns
        let now = Date()
        let in45m = now.addingTimeInterval(45 * 60)
        let m1 = UsageMetric(windowType: .fiveHour, usedPercent: 50, resetDate: in45m)
        assert(m1.formattedReset(relativeTo: now) == "Resets in 45m")

        let in2h15m = now.addingTimeInterval((2 * 3600) + (15 * 60))
        let m2 = UsageMetric(windowType: .fiveHour, usedPercent: 78, resetDate: in2h15m)
        assert(m2.formattedReset(relativeTo: now) == "Resets in 2h 15m")

        let in3d = now.addingTimeInterval((3 * 86400) + (14 * 3600))
        let m3 = UsageMetric(windowType: .weekly, usedPercent: 34, resetDate: in3d)
        assert(m3.formattedReset(relativeTo: now) == "Resets in 3d 14h")
        print("✓ Countdown formatting tests passed")

        // 3. Provider Urgency Aggregation
        let usage = ProviderUsage(
            provider: .claude,
            fiveHourMetric: UsageMetric(windowType: .fiveHour, usedPercent: 78, resetDate: now),
            weeklyMetric: UsageMetric(windowType: .weekly, usedPercent: 34, resetDate: now)
        )
        assert(usage.highestPercent == 78.0)
        assert(usage.highestUrgency == .warning)
        print("✓ Provider urgency aggregation tests passed")

        // 3b. Quota polarity: remainingFraction is converted to used %
        let untouched = UsageMetric(windowType: .fiveHour, remainingFraction: 1.0, resetDate: now)
        assert(untouched.usedPercent == 0.0 && untouched.remainingPercent == 100.0)
        assert(untouched.threshold == .normal)
        let exhausted = UsageMetric(windowType: .fiveHour, remainingFraction: 0.0, resetDate: now)
        assert(exhausted.usedPercent == 100.0 && exhausted.threshold == .critical)
        let quarterUsed = UsageMetric(windowType: .weekly, remainingFraction: 0.75, resetDate: now)
        assert(quarterUsed.usedPercent == 25.0 && quarterUsed.usageSummary == "25% used • 75% left")
        let roundingEdge = UsageMetric(windowType: .fiveHour, usedPercent: 12.5, resetDate: now)
        assert(roundingEdge.usageSummary == "13% used • 87% left")
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
        assert(argonGroups.map { $0.name } == ["Gemini Models", "Claude and GPT models", "Gemini 4 Argon"])
        assert(argonGroups[2].fiveHourMetric == nil && argonGroups[2].weeklyMetric?.usedPercent == 26.0)
        assert(argonGroups[0].fiveHourMetric?.usedPercent == 0.0, "Argon weekly bucket must not overwrite Gemini Models")
        assert(AntigravityProvider.parseQuotaGroups(from: Data("{}".utf8)) == nil)

        let mergedAB = AntigravityProvider.mergeQuotaGroups([argonGroups, otherGroups])
        let mergedBA = AntigravityProvider.mergeQuotaGroups([otherGroups, argonGroups])
        assert(mergedAB.count == 3 && mergedBA.count == 3)
        for (a, b) in zip(mergedAB, mergedBA) {
            assert(a.name == b.name)
            assert(a.fiveHourMetric?.usedPercent == b.fiveHourMetric?.usedPercent)
            assert(a.weeklyMetric?.usedPercent == b.weeklyMetric?.usedPercent)
        }
        let merged = AntigravityProvider.makeUsage(groups: mergedAB, now: now)
        assert(merged.fiveHourMetric.usedPercent == 10.0)
        assert(merged.weeklyMetric.usedPercent == 26.0)
        assert(merged.groups.count == 3)
        assert(mergedAB.map { $0.name } == AntigravityProvider.groupDisplayOrder)

        // Different PIDs returning different subsets / orders must merge identically
        let subsetA = [argonGroups[2], argonGroups[0]]          // Argon, Gemini Models
        let subsetB = [otherGroups[1], argonGroups[1]]          // Claude and GPT (other PID), Claude and GPT (argon PID)
        let unknown = [QuotaGroup(name: "Aardvark Models", weeklyMetric: UsageMetric(windowType: .weekly, usedPercent: 3, resetDate: now))]
        let forward = AntigravityProvider.mergeQuotaGroups([subsetA, subsetB, unknown])
        let backward = AntigravityProvider.mergeQuotaGroups([unknown, subsetB, subsetA])
        assert(forward.map { $0.name } == backward.map { $0.name })
        assert(forward.map { $0.name } == AntigravityProvider.groupDisplayOrder + ["Aardvark Models"])

        // Protobuf JSON timestamps may include fractional seconds
        let fractionalReset = AntigravityProvider.parseResetTime("2026-10-24T03:42:18.491Z")
        let wholeReset = AntigravityProvider.parseResetTime("2026-10-24T03:42:18Z")
        assert(fractionalReset != nil && wholeReset != nil)
        assert(abs(fractionalReset!.timeIntervalSince(wholeReset!) - 0.491) < 0.001)
        let fractionalResponse = Data("""
        {"response":{"groups":[{"displayName":"Gemini Models","buckets":[
          {"window":"5h","remainingFraction":0.5,"resetTime":"2026-10-24T03:42:18.491Z"}]}]}}
        """.utf8)
        let fractionalGroups = AntigravityProvider.parseQuotaGroups(from: fractionalResponse, now: now)
        assert(fractionalGroups?.first?.fiveHourMetric?.resetDate == fractionalReset, "Fractional resetTime must not fall back to now + 5h")
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
        assert(activeFH.usedPercent == 23 && abs(activeFH.resetDate.timeIntervalSince(now) - (5 * 3600 - 60 * 60)) < 1)
        assert(activeSD.usedPercent == 5 && abs(activeSD.resetDate.timeIntervalSince(now) - (7 * 86400 - 60 * 60)) < 1)

        // Step down means the window reset between samples: new window starts at the lower reading
        let (steppedFH, _) = windows(planSamples([(200, 40, 10), (120, 5, 10)]))
        assert(steppedFH.usedPercent == 5 && abs(steppedFH.resetDate.timeIntervalSince(now) - (5 * 3600 - 120 * 60)) < 1)

        // Stale: Claude closed for 6h, so the 5h window expired and decays to 0%; weekly still active
        let (staleFH, staleSD) = windows(planSamples([(400, 60, 20), (360, 78, 22)]))
        assert(staleFH.usedPercent == 0 && staleSD.usedPercent == 22)

        // Weekly expires after 7 days
        let (_, expiredSD) = windows(planSamples([(8 * 24 * 60, 50, 30)]))
        assert(expiredSD.usedPercent == 0)
        print("✓ Claude window inference tests passed")

        // 3e. Claude Code CLI token aggregation de-duplicates streamed message ids
        func cliLine(_ id: String, minutesAgo: Double, input: Int, output: Int) -> String {
            let stamp = ISO8601DateFormatter().string(from: now.addingTimeInterval(-minutesAgo * 60))
            return "{\"type\":\"assistant\",\"timestamp\":\"\(stamp)\",\"message\":{\"id\":\"\(id)\",\"usage\":{\"input_tokens\":\(input),\"output_tokens\":\(output),\"cache_read_input_tokens\":100,\"cache_creation_input_tokens\":10}}}"
        }
        let transcript = Data([
            cliLine("msg_a", minutesAgo: 10, input: 5, output: 50),
            cliLine("msg_a", minutesAgo: 10, input: 5, output: 50),       // streamed duplicate
            "{\"type\":\"user\",\"message\":{\"role\":\"user\"}}",
            cliLine("msg_b", minutesAgo: 6 * 60, input: 7, output: 70),   // 7d only
            cliLine("msg_c", minutesAgo: 8 * 24 * 60, input: 9, output: 90) // outside 7d
        ].joined(separator: "\n").utf8)
        let cli = ClaudeCodeUsageScanner.aggregate(ClaudeCodeUsageScanner.parseEntries(from: transcript), now: now)
        assert(cli.last5h == TokenUsage(inputTokens: 5, outputTokens: 50, cacheReadTokens: 100, cacheCreationTokens: 10))
        assert(cli.last7d == TokenUsage(inputTokens: 12, outputTokens: 120, cacheReadTokens: 200, cacheCreationTokens: 20))
        assert(TokenUsage.compact(950) == "950" && TokenUsage.compact(12_300) == "12.3K" && TokenUsage.compact(4_500_000) == "4.5M")
        print("✓ Claude Code CLI token aggregation tests passed")

        // 4. Claude Real Data Provider Test
        let claudeProv = ClaudeProvider()
        if let u = try? await claudeProv.fetchUsage() {
            assert(u.provider == .claude)
            print("✓ Claude real data provider parsed: 5h=\(Int(u.fiveHourMetric.usedPercent))% used, weekly=\(Int(u.weeklyMetric.usedPercent))% used")
            print("    • 5h resets: \(u.fiveHourMetric.formattedReset()), weekly: \(u.weeklyMetric.formattedReset())")
            if let cli = u.cliTokenUsage {
                print("    • Claude Code CLI last 5h: \(cli.last5h.summary)")
                print("    • Claude Code CLI last 7d: \(cli.last7d.summary)")
            }
        }

        // 5. Antigravity Real Data Provider Test
        let geminiProv = AntigravityProvider()
        if let u = try? await geminiProv.fetchUsage() {
            assert(u.provider == .gemini)
            print("✓ Antigravity real data provider parsed: 5h=\(Int(u.fiveHourMetric.usedPercent))% used, weekly=\(Int(u.weeklyMetric.usedPercent))% used")
            for group in u.groups {
                print("    • \(group.name): " + group.metrics.map { "\($0.windowType == .fiveHour ? "5h" : "weekly")=\($0.usageSummary)" }.joined(separator: ", "))
            }
        }

        print("All GravityBar self-tests passed successfully!")
    }

}
