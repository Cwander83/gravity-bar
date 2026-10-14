import Foundation

/// Provider for Codex usage metrics, returning actual quotas or 0% idle when not actively consuming.
public final class CodexProvider: UsageProvider {
    public let providerType: ProviderType = .codex
    public var customStatePath: String?

    public init(customStatePath: String? = nil) {
        self.customStatePath = customStatePath
    }

    public func fetchUsage() async throws -> ProviderUsage {
        let defaultPath = "~/.codex/session.json"
        let path = customStatePath ?? defaultPath
        let expandedPath = (path as NSString).expandingTildeInPath

        var fiveHour = 0.0
        var weekly = 0.0
        let now = Date()
        var resetFiveHour = now.addingTimeInterval(5 * 3600)
        var resetWeekly = now.addingTimeInterval(7 * 86400)

        if FileManager.default.fileExists(atPath: expandedPath),
           let data = try? Data(contentsOf: URL(fileURLWithPath: expandedPath)),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let fh = json["fiveHourPercent"] as? Double { fiveHour = fh }
            else if let fhInt = json["fiveHourPercent"] as? Int { fiveHour = Double(fhInt) }

            if let wk = json["weeklyPercent"] as? Double { weekly = wk }
            else if let wkInt = json["weeklyPercent"] as? Int { weekly = Double(wkInt) }

            if let r5 = json["fiveHourResetInSeconds"] as? Double { resetFiveHour = now.addingTimeInterval(r5) }
            if let rw = json["weeklyResetInSeconds"] as? Double { resetWeekly = now.addingTimeInterval(rw) }
        }

        return ProviderUsage(
            provider: .codex,
            fiveHourMetric: UsageMetric(
                windowType: .fiveHour,
                percent: fiveHour,
                resetDate: resetFiveHour
            ),
            weeklyMetric: UsageMetric(
                windowType: .weekly,
                percent: weekly,
                resetDate: resetWeekly
            )
        )
    }
}
