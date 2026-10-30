import SwiftUI

/// Design system tokens for GravityBar popover and menu bar presentation.
public enum GravityBarTokens {
    // Thresholds
    public static let thresholdNormalLimit: Double = 60.0
    public static let thresholdWarningLimit: Double = 85.0

    // Geometry
    public static let popoverWidth: CGFloat = 360
    public static let cardCornerRadius: CGFloat = 12
    public static let progressBarHeight: CGFloat = 7

    // Colors
    public static let colorNormal = Color(red: 0.06, green: 0.73, blue: 0.51)      // #10b981
    public static let colorWarning = Color(red: 0.96, green: 0.62, blue: 0.04)     // #f59e0b
    public static let colorCritical = Color(red: 0.94, green: 0.27, blue: 0.27)    // #ef4444
    public static let colorAccent = Color(red: 0.39, green: 0.40, blue: 0.95)      // #6366f1

    // Adaptive Surfaces, Borders & Tracks (Light & Dark mode contrast)
    public static let buttonBackground = Color.primary.opacity(0.06)
    public static let badgeBackground = Color.primary.opacity(0.08)
    public static let progressTrack = Color.primary.opacity(0.08)
    public static let circularGaugeTrack = Color.primary.opacity(0.09)
    public static let cardBorder = Color.primary.opacity(0.09)

    public static func colorFor(threshold: QuotaThreshold) -> Color {
        switch threshold {
        case .normal: return colorNormal
        case .warning: return colorWarning
        case .critical: return colorCritical
        }
    }
}
