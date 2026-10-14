import Foundation

/// Provider for Codex usage metrics, parsing local state from ~/.codex/ with graceful mock fallback.
public final class CodexProvider: UsageProvider {
    public let providerType: ProviderType = .codex
    public var customStatePath: String?

    private let fallbackProvider = MockProvider(providerType: .codex)

    public init(customStatePath: String? = nil) {
        self.customStatePath = customStatePath
    }

    public func fetchUsage() async throws -> ProviderUsage {
        let path = customStatePath ?? "~/.codex/session.json"
        let expandedPath = (path as NSString).expandingTildeInPath

        guard FileManager.default.fileExists(atPath: expandedPath) else {
            return try await fallbackProvider.fetchUsage()
        }

        do {
            let data = try Data(contentsOf: URL(fileURLWithPath: expandedPath))
            if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
               let fiveHour = json["fiveHourPercent"] as? Double,
               let weekly = json["weeklyPercent"] as? Double {
                let now = Date()
                let fiveHourResetSeconds = (json["fiveHourResetInSeconds"] as? Double) ?? (42 * 60)
                let weeklyResetSeconds = (json["weeklyResetInSeconds"] as? Double) ?? (104 * 3600)

                return ProviderUsage(
                    provider: .codex,
                    fiveHourMetric: UsageMetric(
                        windowType: .fiveHour,
                        percent: fiveHour,
                        resetDate: now.addingTimeInterval(fiveHourResetSeconds)
                    ),
                    weeklyMetric: UsageMetric(
                        windowType: .weekly,
                        percent: weekly,
                        resetDate: now.addingTimeInterval(weeklyResetSeconds)
                    )
                )
            }
        } catch {
            // Parsing failure fallback
        }

        return try await fallbackProvider.fetchUsage()
    }
}
