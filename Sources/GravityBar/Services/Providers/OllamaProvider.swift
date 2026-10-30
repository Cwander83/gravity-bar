import Foundation

/// Provider for local Llama / Ollama models. Ollama has no quota windows, so the card lists loaded models
/// (`/api/ps`), the installed model count (`/api/tags`) and the model Codex is configured to launch through
/// Ollama (`~/.codex/ollama-launch.config.toml`).
public final class OllamaProvider: UsageProvider {
    public let providerType: ProviderType = .ollama
    public var baseURL: URL
    public var codexLaunchConfigPath: String

    public init(
        baseURL: URL = URL(string: "http://127.0.0.1:11434")!,
        codexLaunchConfigPath: String = "~/.codex/ollama-launch.config.toml"
    ) {
        self.baseURL = baseURL
        self.codexLaunchConfigPath = codexLaunchConfigPath
    }

    /// Shared ephemeral session reused across polling cycles to avoid URLSession and connection pool leaks.
    static let sharedSession: URLSession = {
        let sessionConfig = URLSessionConfiguration.ephemeral
        sessionConfig.timeoutIntervalForRequest = 1.5
        sessionConfig.httpCookieStorage = nil
        sessionConfig.httpShouldSetCookies = false
        sessionConfig.urlCache = nil
        sessionConfig.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: sessionConfig)
    }()

    public func fetchUsage() async throws -> ProviderUsage {
        let configuredModel = OllamaProvider.configuredModel(atPath: codexLaunchConfigPath)
        let session = OllamaProvider.sharedSession

        // data(from:) doesn't throw on 4xx/5xx, so require a 200 before treating Ollama as connected
        guard let (tagsData, tagsResponse) = try? await session.data(from: baseURL.appendingPathComponent("api/tags")),
              (tagsResponse as? HTTPURLResponse)?.statusCode == 200 else {
            // Not reachable: installed-but-stopped is an error worth showing; otherwise it's simply absent
            let installed = FileManager.default.fileExists(atPath: "/Applications/Ollama.app") || configuredModel != nil
            return .unavailable(.ollama, state: installed ? .error("Ollama is not running") : .notConfigured)
        }
        var psData: Data?
        if let (data, response) = try? await session.data(from: baseURL.appendingPathComponent("api/ps")),
           (response as? HTTPURLResponse)?.statusCode == 200 {
            psData = data
        }

        return OllamaProvider.makeUsage(tagsData: tagsData, psData: psData, configuredModel: configuredModel)
    }

    /// How many installed models to list when none are loaded.
    static let installedModelPreviewLimit = 4

    static func makeUsage(tagsData: Data, psData: Data?, configuredModel: String?) -> ProviderUsage {
        func models(_ data: Data?) -> [[String: Any]] {
            guard let data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }
            return json["models"] as? [[String: Any]] ?? []
        }

        let installed = models(tagsData)
        let installedCount = installed.count
        var active = models(psData).compactMap { model -> ActiveModel? in
            guard let name = model["name"] as? String else { return nil }
            let vram = (model["size_vram"] as? NSNumber)?.int64Value ?? 0
            let detail = vram > 0
                ? "running · \(ByteCountFormatter.string(fromByteCount: vram, countStyle: .memory))"
                : "running"
            return ActiveModel(name: name, detail: detail, isRunning: true)
        }
        let hasRunningModels = !active.isEmpty

        if let configuredModel, !active.contains(where: { $0.name == configuredModel }) {
            active.append(ActiveModel(name: configuredModel, detail: "Codex default model"))
        }

        // When no models are running in VRAM, fill up to installedModelPreviewLimit total rows with installed models
        if !hasRunningModels {
            for model in installed {
                guard active.count < installedModelPreviewLimit else { break }
                guard let name = model["name"] as? String else { continue }
                if active.contains(where: { $0.name == name }) {
                    continue
                }
                let size = (model["size"] as? NSNumber)?.int64Value ?? 0
                // Cloud models report a tiny placeholder size, so only show sizes for real local weights
                let detail = size >= 1_000_000
                    ? "installed · \(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))"
                    : "installed"
                active.append(ActiveModel(name: name, detail: detail))
            }
        }

        return ProviderUsage(
            provider: .ollama,
            fiveHourMetric: nil,
            weeklyMetric: nil,
            connectionState: .connected,
            planBadge: "\(installedCount) model\(installedCount == 1 ? "" : "s")",
            models: active
        )
    }

    /// Reads the top-level `model = "..."` key from Codex's Ollama launch config.
    static func configuredModel(atPath path: String) -> String? {
        let expanded = (path as NSString).expandingTildeInPath
        guard let text = try? String(contentsOfFile: expanded, encoding: .utf8) else { return nil }
        return configuredModel(fromTOML: text)
    }

    static func configuredModel(fromTOML text: String) -> String? {
        for line in text.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("[") { break } // Only top-level keys
            let parts = trimmed.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            if parts.count == 2, parts[0] == "model" {
                return parts[1].trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            }
        }
        return nil
    }
}
