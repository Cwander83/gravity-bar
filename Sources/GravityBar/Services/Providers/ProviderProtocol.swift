import Foundation

/// Protocol defining a quota and usage provider for GravityBar.
public protocol UsageProvider: AnyObject {
    var providerType: ProviderType { get }
    func fetchUsage() async throws -> ProviderUsage
}

/// Default local data locations, and resolution of user overrides from Settings.
public enum ProviderPaths {
    public static let claudeDefault = "~/Library/Application Support/Claude/plan-usage-history.json"
    public static let codexDefault = "~/.codex/sessions"
    public static let geminiDefault = "~/.gemini/antigravity-ide/metrics.json"

    /// Uses the override unless it is nil, empty or whitespace-only (e.g. a cleared Settings field).
    public static func resolve(_ custom: String?, default defaultPath: String) -> String {
        let trimmed = custom?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? defaultPath : trimmed
    }
}
