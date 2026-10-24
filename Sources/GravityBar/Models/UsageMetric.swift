import Foundation

/// Urgency threshold levels matching color-coded indicators.
public enum QuotaThreshold: String, Codable, CaseIterable, Comparable {
    case normal
    case warning
    case critical

    /// Classifies a consumption level. `usedPercent` is always percentage USED (0 = untouched, 100 = exhausted).
    public static func from(usedPercent: Double) -> QuotaThreshold {
        if usedPercent > 85.0 {
            return .critical
        } else if usedPercent >= 60.0 {
            return .warning
        } else {
            return .normal
        }
    }

    private var sortOrder: Int {
        switch self {
        case .normal: return 0
        case .warning: return 1
        case .critical: return 2
        }
    }

    public static func < (lhs: QuotaThreshold, rhs: QuotaThreshold) -> Bool {
        return lhs.sortOrder < rhs.sortOrder
    }
}

/// The tracking window period.
public enum WindowType: String, Codable, CaseIterable {
    case fiveHour = "5-Hour Window"
    case weekly = "Weekly Window"
    case monthly = "Monthly Window"
}

/// Supported AI providers in GravityBar.
public enum ProviderType: String, Codable, CaseIterable, Identifiable {
    case claude = "Claude"
    case codex = "Codex"
    case gemini = "Antigravity / Gemini"

    public var id: String { rawValue }

    public var iconSymbol: String {
        switch self {
        case .claude: return "c.circle.fill"
        case .codex: return "bolt.circle.fill"
        case .gemini: return "sparkles"
        }
    }
}

/// A specific quota window metric.
public struct UsageMetric: Identifiable, Codable, Equatable {
    public let id: UUID
    public var windowType: WindowType
    /// Canonical consumption metric: percentage of the window USED (0–100).
    /// Providers reporting remaining quota must convert via `init(windowType:remainingFraction:resetDate:)`.
    public var usedPercent: Double
    public var resetDate: Date

    public init(id: UUID = UUID(), windowType: WindowType, usedPercent: Double, resetDate: Date) {
        self.id = id
        self.windowType = windowType
        self.usedPercent = max(0.0, min(100.0, usedPercent))
        self.resetDate = resetDate
    }

    /// Builds a metric from a provider that reports the fraction of quota REMAINING (1.0 = untouched).
    public init(id: UUID = UUID(), windowType: WindowType, remainingFraction: Double, resetDate: Date) {
        self.init(id: id, windowType: windowType, usedPercent: UsageMetric.usedPercent(fromRemainingFraction: remainingFraction), resetDate: resetDate)
    }

    /// Converts a REMAINING fraction (1.0 = untouched) into a rounded USED percentage (0–100).
    public static func usedPercent(fromRemainingFraction remainingFraction: Double) -> Double {
        let remaining = max(0.0, min(1.0, remainingFraction))
        return round((1.0 - remaining) * 100.0)
    }

    /// Percentage of the window still available (0–100).
    public var remainingPercent: Double {
        max(0.0, 100.0 - usedPercent)
    }

    /// Readout showing both polarities, e.g. "7% used • 93% left". Halves always sum to 100%.
    public var usageSummary: String {
        let used = Int(round(usedPercent))
        let left = max(0, 100 - used)
        return "\(used)% used • \(left)% left"
    }

    public var threshold: QuotaThreshold {
        QuotaThreshold.from(usedPercent: usedPercent)
    }

    /// Formats time remaining until reset into a clean human string (e.g. "Resets in 1h 42m").
    public func formattedReset(relativeTo now: Date = Date()) -> String {
        let diff = resetDate.timeIntervalSince(now)
        if diff <= 0 {
            return "Resets momentarily"
        }

        let totalMinutes = Int(diff) / 60
        let days = totalMinutes / (24 * 60)
        let hours = (totalMinutes % (24 * 60)) / 60
        let minutes = totalMinutes % 60

        if days > 0 {
            return "Resets in \(days)d \(hours)h"
        } else if hours > 0 {
            return "Resets in \(hours)h \(minutes)m"
        } else {
            return "Resets in \(max(1, minutes))m"
        }
    }
}

/// A named quota bucket group inside a provider (e.g. Antigravity's "Gemini Models", "Gemini 4 Argon",
/// "Claude and GPT models"). Either window may be absent; Argon, for example, only has a weekly bucket.
public struct QuotaGroup: Identifiable, Codable, Equatable {
    public var id: String { name }
    public let name: String
    public var fiveHourMetric: UsageMetric?
    public var weeklyMetric: UsageMetric?

    public init(name: String, fiveHourMetric: UsageMetric? = nil, weeklyMetric: UsageMetric? = nil) {
        self.name = name
        self.fiveHourMetric = fiveHourMetric
        self.weeklyMetric = weeklyMetric
    }

    public var metrics: [UsageMetric] {
        [fiveHourMetric, weeklyMetric].compactMap { $0 }
    }
}

/// Token counts for a span of Claude Code CLI activity.
public struct TokenUsage: Codable, Equatable {
    public var inputTokens: Int
    public var outputTokens: Int
    public var cacheReadTokens: Int
    public var cacheCreationTokens: Int

    public init(inputTokens: Int = 0, outputTokens: Int = 0, cacheReadTokens: Int = 0, cacheCreationTokens: Int = 0) {
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cacheReadTokens = cacheReadTokens
        self.cacheCreationTokens = cacheCreationTokens
    }

    public var cacheTokens: Int { cacheReadTokens + cacheCreationTokens }
    public var totalTokens: Int { inputTokens + outputTokens + cacheTokens }

    public static func + (lhs: TokenUsage, rhs: TokenUsage) -> TokenUsage {
        TokenUsage(
            inputTokens: lhs.inputTokens + rhs.inputTokens,
            outputTokens: lhs.outputTokens + rhs.outputTokens,
            cacheReadTokens: lhs.cacheReadTokens + rhs.cacheReadTokens,
            cacheCreationTokens: lhs.cacheCreationTokens + rhs.cacheCreationTokens
        )
    }

    /// Difference of cumulative counters, clamped at 0 per field.
    public static func - (lhs: TokenUsage, rhs: TokenUsage) -> TokenUsage {
        TokenUsage(
            inputTokens: max(0, lhs.inputTokens - rhs.inputTokens),
            outputTokens: max(0, lhs.outputTokens - rhs.outputTokens),
            cacheReadTokens: max(0, lhs.cacheReadTokens - rhs.cacheReadTokens),
            cacheCreationTokens: max(0, lhs.cacheCreationTokens - rhs.cacheCreationTokens)
        )
    }

    /// Readout like "1.2M in • 340K out • 8.1M cache".
    public var summary: String {
        "\(TokenUsage.compact(inputTokens)) in • \(TokenUsage.compact(outputTokens)) out • \(TokenUsage.compact(cacheTokens)) cache"
    }

    /// Compact count: 950, 12.3K, 342K, 4.5M, 1.2B (a trailing ".0" is dropped).
    public static func compact(_ count: Int) -> String {
        func scaled(_ value: Double, _ suffix: String) -> String {
            let text = String(format: "%.1f", value)
            return (text.hasSuffix(".0") ? String(text.dropLast(2)) : text) + suffix
        }

        let value = Double(count)
        switch value {
        case 1_000_000_000...: return scaled(value / 1_000_000_000, "B")
        case 1_000_000...: return scaled(value / 1_000_000, "M")
        case 1_000...: return scaled(value / 1_000, "K")
        default: return "\(count)"
        }
    }
}

/// CLI token usage (Claude Code, Codex) over rolling spans ending now.
public struct CLITokenUsage: Codable, Equatable {
    public var last5h: TokenUsage
    public var last7d: TokenUsage

    public init(last5h: TokenUsage, last7d: TokenUsage) {
        self.last5h = last5h
        self.last7d = last7d
    }
}

/// Aggregated usage state for a single provider.
public struct ProviderUsage: Identifiable, Codable, Equatable {
    public var id: String { provider.rawValue }
    public let provider: ProviderType
    /// Headline metrics. For multi-group providers these are the most-consumed bucket per window across all groups.
    public var fiveHourMetric: UsageMetric
    public var weeklyMetric: UsageMetric
    /// Per-group breakdown; empty for providers that expose a single quota.
    public var groups: [QuotaGroup]
    /// CLI token usage (Claude Code, Codex); nil when the provider has no CLI or no recent usage.
    public var cliTokenUsage: CLITokenUsage?

    public init(
        provider: ProviderType,
        fiveHourMetric: UsageMetric,
        weeklyMetric: UsageMetric,
        groups: [QuotaGroup] = [],
        cliTokenUsage: CLITokenUsage? = nil
    ) {
        self.provider = provider
        self.fiveHourMetric = fiveHourMetric
        self.weeklyMetric = weeklyMetric
        self.groups = groups
        self.cliTokenUsage = cliTokenUsage
    }

    public var highestPercent: Double {
        max(fiveHourMetric.usedPercent, weeklyMetric.usedPercent)
    }

    public var highestUrgency: QuotaThreshold {
        max(fiveHourMetric.threshold, weeklyMetric.threshold)
    }
}
