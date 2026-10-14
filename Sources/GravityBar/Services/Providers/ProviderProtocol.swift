import Foundation

/// Protocol defining a quota and usage provider for GravityBar.
public protocol UsageProvider: AnyObject {
    var providerType: ProviderType { get }
    func fetchUsage() async throws -> ProviderUsage
}
