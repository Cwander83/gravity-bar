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
            runSelfTests()
            exit(0)
        }

        // Run as menu bar accessory (hide Dock icon)
        NSApp.setActivationPolicy(.accessory)
        statusBarController = StatusBarController(manager: .shared)
    }

    private func runSelfTests() {
        print("Running GravityBar Self-Tests...")

        // 1. Thresholds
        assert(QuotaThreshold.from(percent: 0.0) == .normal)
        assert(QuotaThreshold.from(percent: 59.9) == .normal)
        assert(QuotaThreshold.from(percent: 60.0) == .warning)
        assert(QuotaThreshold.from(percent: 85.0) == .warning)
        assert(QuotaThreshold.from(percent: 85.1) == .critical)
        assert(QuotaThreshold.from(percent: 100.0) == .critical)
        print("✓ Quota threshold tests passed")

        // 2. Countdowns
        let now = Date()
        let in45m = now.addingTimeInterval(45 * 60)
        let m1 = UsageMetric(windowType: .fiveHour, percent: 50, resetDate: in45m)
        assert(m1.formattedReset(relativeTo: now) == "Resets in 45m")

        let in2h15m = now.addingTimeInterval((2 * 3600) + (15 * 60))
        let m2 = UsageMetric(windowType: .fiveHour, percent: 78, resetDate: in2h15m)
        assert(m2.formattedReset(relativeTo: now) == "Resets in 2h 15m")

        let in3d = now.addingTimeInterval((3 * 86400) + (14 * 3600))
        let m3 = UsageMetric(windowType: .weekly, percent: 34, resetDate: in3d)
        assert(m3.formattedReset(relativeTo: now) == "Resets in 3d 14h")
        print("✓ Countdown formatting tests passed")

        // 3. Provider Urgency Aggregation
        let usage = ProviderUsage(
            provider: .claude,
            fiveHourMetric: UsageMetric(windowType: .fiveHour, percent: 78, resetDate: now),
            weeklyMetric: UsageMetric(windowType: .weekly, percent: 34, resetDate: now)
        )
        assert(usage.highestPercent == 78.0)
        assert(usage.highestUrgency == .warning)
        print("✓ Provider urgency aggregation tests passed")

        print("All GravityBar self-tests passed successfully!")
    }
}
