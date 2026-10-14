import Foundation

/// Provides synthetic usage metrics for offline previewing, testing, and out-of-the-box demonstration.
public final class MockProvider: UsageProvider {
    public let providerType: ProviderType

    public init(providerType: ProviderType) {
        self.providerType = providerType
    }

    public func fetchUsage() async throws -> ProviderUsage {
        let now = Date()

        switch providerType {
        case .claude:
            return ProviderUsage(
                provider: .claude,
                fiveHourMetric: UsageMetric(
                    windowType: .fiveHour,
                    percent: 78.0,
                    resetDate: now.addingTimeInterval((1 * 3600) + (42 * 60))
                ),
                weeklyMetric: UsageMetric(
                    windowType: .weekly,
                    percent: 34.0,
                    resetDate: now.addingTimeInterval((3 * 86400) + (14 * 3600))
                )
            )

        case .codex:
            return ProviderUsage(
                provider: .codex,
                fiveHourMetric: UsageMetric(
                    windowType: .fiveHour,
                    percent: 52.0,
                    resetDate: now.addingTimeInterval(42 * 60)
                ),
                weeklyMetric: UsageMetric(
                    windowType: .weekly,
                    percent: 41.0,
                    resetDate: now.addingTimeInterval((4 * 86400) + (8 * 3600))
                )
            )

        case .gemini:
            return ProviderUsage(
                provider: .gemini,
                fiveHourMetric: UsageMetric(
                    windowType: .fiveHour,
                    percent: 89.0,
                    resetDate: now.addingTimeInterval(24 * 60)
                ),
                weeklyMetric: UsageMetric(
                    windowType: .weekly,
                    percent: 62.0,
                    resetDate: now.addingTimeInterval((2 * 86400) + (18 * 3600))
                )
            )
        }
    }
}
