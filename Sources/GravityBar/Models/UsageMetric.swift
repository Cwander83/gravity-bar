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
        let remaining = max(0.0, min(1.0, remainingFraction))
        self.init(id: id, windowType: windowType, usedPercent: round((1.0 - remaining) * 100.0), resetDate: resetDate)
    }

    /// Percentage of the window still available (0–100).
    public var remainingPercent: Double {
        max(0.0, 100.0 - usedPercent)
    }

    /// Readout showing both polarities, e.g. "7% used • 93% left".
    public var usageSummary: String {
        "\(Int(round(usedPercent)))% used • \(Int(round(remainingPercent)))% left"
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

/// Aggregated usage state for a single provider.
public struct ProviderUsage: Identifiable, Codable, Equatable {
    public var id: String { provider.rawValue }
    public let provider: ProviderType
    public var fiveHourMetric: UsageMetric
    public var weeklyMetric: UsageMetric

    public init(
        provider: ProviderType,
        fiveHourMetric: UsageMetric,
        weeklyMetric: UsageMetric
    ) {
        self.provider = provider
        self.fiveHourMetric = fiveHourMetric
        self.weeklyMetric = weeklyMetric
    }

    public var highestPercent: Double {
        max(fiveHourMetric.usedPercent, weeklyMetric.usedPercent)
    }

    public var highestUrgency: QuotaThreshold {
        max(fiveHourMetric.threshold, weeklyMetric.threshold)
    }
}
