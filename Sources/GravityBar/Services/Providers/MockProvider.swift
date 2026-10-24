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
                    usedPercent: 78.0,
                    resetDate: now.addingTimeInterval((1 * 3600) + (42 * 60))
                ),
                weeklyMetric: UsageMetric(
                    windowType: .weekly,
                    usedPercent: 34.0,
                    resetDate: now.addingTimeInterval((3 * 86400) + (14 * 3600))
                ),
                cliTokenUsage: CLITokenUsage(
                    last5h: TokenUsage(inputTokens: 18_400, outputTokens: 342_000, cacheReadTokens: 8_100_000, cacheCreationTokens: 410_000),
                    last7d: TokenUsage(inputTokens: 96_000, outputTokens: 2_300_000, cacheReadTokens: 61_000_000, cacheCreationTokens: 3_900_000)
                )
            )

        case .codex:
            return ProviderUsage(
                provider: .codex,
                fiveHourMetric: UsageMetric(
                    windowType: .fiveHour,
                    usedPercent: 52.0,
                    resetDate: now.addingTimeInterval(42 * 60)
                ),
                weeklyMetric: UsageMetric(
                    windowType: .weekly,
                    usedPercent: 41.0,
                    resetDate: now.addingTimeInterval((4 * 86400) + (8 * 3600))
                ),
                planBadge: "Plus"
            )

        case .gemini:
            return ProviderUsage(
                provider: .gemini,
                fiveHourMetric: UsageMetric(
                    windowType: .fiveHour,
                    usedPercent: 89.0,
                    resetDate: now.addingTimeInterval(24 * 60)
                ),
                weeklyMetric: UsageMetric(
                    windowType: .weekly,
                    usedPercent: 62.0,
                    resetDate: now.addingTimeInterval((2 * 86400) + (18 * 3600))
                ),
                groups: [
                    QuotaGroup(
                        name: "Gemini Models",
                        fiveHourMetric: UsageMetric(windowType: .fiveHour, usedPercent: 89.0, resetDate: now.addingTimeInterval(24 * 60)),
                        weeklyMetric: UsageMetric(windowType: .weekly, usedPercent: 41.0, resetDate: now.addingTimeInterval((2 * 86400) + (18 * 3600)))
                    ),
                    QuotaGroup(
                        name: "Gemini 4 Argon",
                        weeklyMetric: UsageMetric(windowType: .weekly, usedPercent: 62.0, resetDate: now.addingTimeInterval((3 * 86400) + (2 * 3600)))
                    ),
                    QuotaGroup(
                        name: "Claude and GPT models",
                        fiveHourMetric: UsageMetric(windowType: .fiveHour, usedPercent: 12.0, resetDate: now.addingTimeInterval(24 * 60)),
                        weeklyMetric: UsageMetric(windowType: .weekly, usedPercent: 5.0, resetDate: now.addingTimeInterval((6 * 86400) + (4 * 3600)))
                    )
                ]
            )

        case .ollama:
            return ProviderUsage(
                provider: .ollama,
                fiveHourMetric: nil,
                weeklyMetric: nil,
                planBadge: "10 models",
                models: [
                    ActiveModel(name: "llama3.3:70b", detail: "running · 42.5 GB", isRunning: true),
                    ActiveModel(name: "glm-5.3-flash:cloud", detail: "Codex default model")
                ]
            )
        }
    }
}
