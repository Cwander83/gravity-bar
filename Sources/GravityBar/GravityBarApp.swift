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

        // 4. Claude Real Data Provider Test
        let claudeProv = ClaudeProvider()
        if let u = try? await claudeProv.fetchUsage() {
            assert(u.provider == .claude)
            print("✓ Claude real data provider parsed: 5h=\(Int(u.fiveHourMetric.usedPercent))% used, weekly=\(Int(u.weeklyMetric.usedPercent))% used")
        }

        // 5. Antigravity Real Data Provider Test
        let geminiProv = AntigravityProvider()
        if let u = try? await geminiProv.fetchUsage() {
            assert(u.provider == .gemini)
            print("✓ Antigravity real data provider parsed: 5h=\(Int(u.fiveHourMetric.usedPercent))% used, weekly=\(Int(u.weeklyMetric.usedPercent))% used")
        }

        print("All GravityBar self-tests passed successfully!")
    }

}
