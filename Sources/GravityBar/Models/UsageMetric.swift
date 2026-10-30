import Foundation

/// Urgency threshold levels matching color-coded indicators.
public enum QuotaThreshold: String, Codable, CaseIterable, Comparable {
    case normal
    case warning
    case critical

    /// Classifies a consumption level. `usedPercent` is always percentage USED (0 = untouched, 100 = exhausted).
    public static func from(usedPercent: Double) -> QuotaThreshold {
        if usedPercent > GravityBarTokens.thresholdWarningLimit {
            return .critical
        } else if usedPercent >= GravityBarTokens.thresholdNormalLimit {
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

/// Supported AI providers in GravityBar. Raw values are persisted in `GravityBar_enabledProviders`, so keep them stable.
public enum ProviderType: String, Codable, CaseIterable, Identifiable {
    case claude = "Claude"
    case codex = "Codex"
    case gemini = "Antigravity / Gemini"
    case ollama = "Ollama / Llama"

    public var id: String { rawValue }

    /// User-facing name; Codex also covers ChatGPT, which shares the OpenAI account limits.
    public static func displayName(for type: ProviderType) -> String {
        switch type {
        case .codex: return "Codex / ChatGPT"
        default: return type.rawValue
        }
    }

    public var displayName: String {
        Self.displayName(for: self)
    }
}

/// Whether a provider's data is live, cached from an earlier session, or unavailable.
public enum ProviderConnectionState: Codable, Equatable {
    /// Fresh data from a running app/CLI/server.
    case connected
    /// Installed and has data, but nothing new since `lastSeen` (e.g. app closed).
    case idleCached(lastSeen: Date)
    /// Nothing installed or no local data found.
    case notConfigured
    /// Detected but unreadable or not running.
    case error(String)

    /// Connected or idle providers are "detected" and shown by default; the rest are hidden unless
    /// Show Offline Providers is on.
    public var isDetected: Bool {
        switch self {
        case .connected, .idleCached: return true
        case .notConfigured, .error: return false
        }
    }

    /// Short status for the provider card header, e.g. "Last seen 2h ago". Nil when connected.
    public func label(relativeTo now: Date = Date()) -> String? {
        switch self {
        case .connected:
            return nil
        case .idleCached(let lastSeen):
            let minutes = max(0, Int(now.timeIntervalSince(lastSeen)) / 60)
            if minutes < 60 { return "Last seen \(max(1, minutes))m ago" }
            if minutes < 24 * 60 { return "Last seen \(minutes / 60)h ago" }
            return "Last seen \(minutes / (24 * 60))d ago"
        case .notConfigured:
            return "Not configured"
        case .error(let message):
            return message
        }
    }

    /// Data older than this counts as idle rather than connected.
    public static let freshnessInterval: TimeInterval = 15 * 60

    /// Connected when `lastSeen` is recent, otherwise idle since `lastSeen`.
    public static func fromLastSeen(_ lastSeen: Date, now: Date = Date()) -> ProviderConnectionState {
        now.timeIntervalSince(lastSeen) <= freshnessInterval ? .connected : .idleCached(lastSeen: lastSeen)
    }
}

/// A model detected for a provider (e.g. an Ollama model loaded in memory, or the ChatGPT desktop app).
public struct ActiveModel: Identifiable, Codable, Equatable {
    public var id: String { name }
    public let name: String
    /// Secondary text such as "running · 4.7 GB" or "default model".
    public var detail: String?
    public var isRunning: Bool

    public init(name: String, detail: String? = nil, isRunning: Bool = false) {
        self.name = name
        self.detail = detail
        self.isRunning = isRunning
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
    /// Time of the most recent counted CLI activity.
    public var lastActivity: Date?

    public init(last5h: TokenUsage, last7d: TokenUsage, lastActivity: Date? = nil) {
        self.last5h = last5h
        self.last7d = last7d
        self.lastActivity = lastActivity
    }
}

/// Aggregated usage state for a single provider.
public struct ProviderUsage: Identifiable, Codable, Equatable {
    public var id: String { provider.rawValue }
    public let provider: ProviderType
    /// Headline metrics; nil when the provider does not report that window (e.g. Codex Plus has no 5-hour
    /// window, Ollama has no quotas). For multi-group providers these are the most-consumed bucket per window.
    public var fiveHourMetric: UsageMetric?
    public var weeklyMetric: UsageMetric?
    /// Per-group breakdown; empty for providers that expose a single quota.
    public var groups: [QuotaGroup]
    /// CLI token usage (Claude Code, Codex); nil when the provider has no CLI or no recent usage.
    public var cliTokenUsage: CLITokenUsage?
    public var connectionState: ProviderConnectionState
    /// Plan or tier badge, e.g. "Plus" or "10 models".
    public var planBadge: String?
    /// Detected models / apps (running Ollama models, ChatGPT desktop).
    public var models: [ActiveModel]

    public init(
        provider: ProviderType,
        fiveHourMetric: UsageMetric?,
        weeklyMetric: UsageMetric?,
        groups: [QuotaGroup] = [],
        cliTokenUsage: CLITokenUsage? = nil,
        connectionState: ProviderConnectionState = .connected,
        planBadge: String? = nil,
        models: [ActiveModel] = []
    ) {
        self.provider = provider
        self.fiveHourMetric = fiveHourMetric
        self.weeklyMetric = weeklyMetric
        self.groups = groups
        self.cliTokenUsage = cliTokenUsage
        self.connectionState = connectionState
        self.planBadge = planBadge
        self.models = models
    }

    /// A provider with no data, e.g. not installed or a fetch error.
    public static func unavailable(_ provider: ProviderType, state: ProviderConnectionState) -> ProviderUsage {
        ProviderUsage(provider: provider, fiveHourMetric: nil, weeklyMetric: nil, connectionState: state)
    }

    /// Every reported window: headline metrics plus per-group buckets.
    public var allMetrics: [UsageMetric] {
        [fiveHourMetric, weeklyMetric].compactMap { $0 } + groups.flatMap(\.metrics)
    }

    public var highestPercent: Double {
        allMetrics.map(\.usedPercent).max() ?? 0
    }

    public var highestUrgency: QuotaThreshold {
        allMetrics.map(\.threshold).max() ?? .normal
    }
}
