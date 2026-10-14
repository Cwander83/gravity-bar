import Foundation

/// Provider for Claude usage metrics, parsing local state from ~/Library/Application Support/Claude/plan-usage-history.json.
public final class ClaudeProvider: UsageProvider {
    public let providerType: ProviderType = .claude
    public var customStatePath: String?

    public init(customStatePath: String? = nil) {
        self.customStatePath = customStatePath
    }

    public func fetchUsage() async throws -> ProviderUsage {
        let defaultPath = "~/Library/Application Support/Claude/plan-usage-history.json"
        let path = customStatePath ?? defaultPath
        let expandedPath = (path as NSString).expandingTildeInPath

        var fiveHour = 0.0
        var weekly = 0.0
        let now = Date()
        var resetFiveHour = now.addingTimeInterval(5 * 3600)
        var resetWeekly = now.addingTimeInterval(7 * 86400)

        if FileManager.default.fileExists(atPath: expandedPath),
           let data = try? Data(contentsOf: URL(fileURLWithPath: expandedPath)),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let samples = json["samples"] as? [[String: Any]],
           let lastSample = samples.last {
            if let u = lastSample["u"] as? [String: Any] {
                // "fh" = 5-hour rolling percent
                if let fh = u["fh"] as? Double {
                    fiveHour = fh
                } else if let fhInt = u["fh"] as? Int {
                    fiveHour = Double(fhInt)
                }

                // "sd" = seven-day rolling percent
                if let sd = u["sd"] as? Double {
                    weekly = sd
                } else if let sdInt = u["sd"] as? Int {
                    weekly = Double(sdInt)
                }
            }

            if let timestampMs = lastSample["t"] as? Double {
                let sampleDate = Date(timeIntervalSince1970: timestampMs / 1000.0)
                resetFiveHour = sampleDate.addingTimeInterval(5 * 3600)
                resetWeekly = sampleDate.addingTimeInterval(7 * 86400)
            }
        }

        return ProviderUsage(
            provider: .claude,
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
