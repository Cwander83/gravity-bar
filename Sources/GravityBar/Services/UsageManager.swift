import Foundation
import Combine

/// Central observable manager coordinating providers, background polling, and user preferences.
@MainActor
public final class UsageManager: ObservableObject {
    public static let shared = UsageManager()

    @Published public private(set) var providerUsages: [ProviderType: ProviderUsage] = [:]
    @Published public var enabledProviders: Set<ProviderType> {
        didSet {
            saveEnabledProviders()
        }
    }

    @Published public var isMockMode: Bool {
        didSet {
            UserDefaults.standard.set(isMockMode, forKey: "GravityBar_isMockMode")
            Task { await refreshAll() }
        }
    }

    /// Show providers that are not installed or not running. Off by default: only detected providers appear.
    @Published public var showOfflineProviders: Bool {
        didSet {
            UserDefaults.standard.set(showOfflineProviders, forKey: "GravityBar_showOfflineProviders")
        }
    }

    @Published public var hoverToOpen: Bool {
        didSet {
            UserDefaults.standard.set(hoverToOpen, forKey: "GravityBar_hoverToOpen")
        }
    }

    @Published public var pollingIntervalSeconds: TimeInterval {
        didSet {
            UserDefaults.standard.set(pollingIntervalSeconds, forKey: "GravityBar_pollingInterval")
            restartPolling()
        }
    }

    @Published public var claudePath: String {
        didSet {
            UserDefaults.standard.set(claudePath, forKey: "GravityBar_claudePath")
        }
    }

    @Published public var codexPath: String {
        didSet {
            UserDefaults.standard.set(codexPath, forKey: "GravityBar_codexPath")
        }
    }

    @Published public var geminiPath: String {
        didSet {
            UserDefaults.standard.set(geminiPath, forKey: "GravityBar_geminiPath")
        }
    }

    @Published public var showingSettings: Bool = false
    @Published public var isSpinning: Bool = false

    @Published public private(set) var isRefreshing: Bool = false
    @Published public private(set) var lastUpdated: Date?

    private var pollingTimer: Timer?
    private var countdownTimer: Timer?

    private var providers: [ProviderType: UsageProvider] = [:]

    public init() {
        // Load persisted settings or fallback to defaults
        let defaults = UserDefaults.standard

        if let savedProviders = defaults.array(forKey: "GravityBar_enabledProviders") as? [String] {
            // Providers added after the list was saved (e.g. Ollama) start enabled; ones the user turned off stay off
            let known = Set((defaults.array(forKey: "GravityBar_knownProviders") as? [String]) ?? ["Claude", "Codex", "Antigravity / Gemini"])
            let added = ProviderType.allCases.filter { !known.contains($0.rawValue) }
            self.enabledProviders = Set(savedProviders.compactMap { ProviderType(rawValue: $0) } + added)
        } else {
            self.enabledProviders = Set(ProviderType.allCases)
        }
        defaults.set(ProviderType.allCases.map(\.rawValue), forKey: "GravityBar_knownProviders")

        self.isMockMode = defaults.object(forKey: "GravityBar_isMockMode") as? Bool ?? false
        self.hoverToOpen = defaults.object(forKey: "GravityBar_hoverToOpen") as? Bool ?? true
        self.showOfflineProviders = defaults.object(forKey: "GravityBar_showOfflineProviders") as? Bool ?? false

        let interval = defaults.double(forKey: "GravityBar_pollingInterval")
        self.pollingIntervalSeconds = interval > 0 ? interval : 60.0

        let claudeDefaultPath = "~/Library/Application Support/Claude/plan-usage-history.json"
        let legacyClaudePath = "~/.claude/state.json"
        // Earlier builds defaulted to ~/.claude/state.json, which Claude never writes; migrate it to the real file
        if let saved = defaults.string(forKey: "GravityBar_claudePath"), saved != legacyClaudePath {
            self.claudePath = saved
        } else {
            self.claudePath = claudeDefaultPath
        }
        let codexDefaultPath = "~/.codex/sessions"
        // Earlier builds defaulted to ~/.codex/session.json, which Codex never writes; migrate it to the rollout logs
        if let saved = defaults.string(forKey: "GravityBar_codexPath"), saved != "~/.codex/session.json" {
            self.codexPath = saved
        } else {
            self.codexPath = codexDefaultPath
        }
        self.geminiPath = defaults.string(forKey: "GravityBar_geminiPath") ?? "~/.gemini/antigravity-ide/metrics.json"


        setupProviders()
        startPolling()
        startCountdownTimer()

        Task {
            await refreshAll()
        }
    }

    private func setupProviders() {
        if isMockMode {
            providers = [
                .claude: MockProvider(providerType: .claude),
                .codex: MockProvider(providerType: .codex),
                .gemini: MockProvider(providerType: .gemini),
                .ollama: MockProvider(providerType: .ollama)
            ]
        } else {
            providers = [
                .claude: ClaudeProvider(customStatePath: claudePath),
                .codex: CodexProvider(customStatePath: codexPath),
                .gemini: AntigravityProvider(customStatePath: geminiPath),
                .ollama: OllamaProvider()
            ]
        }
    }

    public func refreshAll() async {
        isRefreshing = true
        setupProviders()

        for providerType in ProviderType.allCases {
            guard let provider = providers[providerType] else { continue }
            do {
                let usage = try await provider.fetchUsage()
                providerUsages[providerType] = usage
            } catch {
                // Surface the failure instead of fabricating 0% with fake reset timers
                providerUsages[providerType] = .unavailable(providerType, state: .error(error.localizedDescription))
            }

        }

        lastUpdated = Date()
        isRefreshing = false
    }

    /// Enabled providers shown in the popover: detected ones, plus offline ones when Show Offline Providers is on.
    public var activeUsages: [ProviderUsage] {
        ProviderType.allCases
            .filter { enabledProviders.contains($0) }
            .compactMap { providerUsages[$0] }
            .filter { showOfflineProviders || $0.connectionState.isDetected }
    }

    /// Usages whose numbers feed the status bar, banner and countdown (never offline placeholders).
    private var detectedUsages: [ProviderUsage] {
        activeUsages.filter { $0.connectionState.isDetected }
    }

    public var maxUrgencyPercent: Double {
        detectedUsages.map { $0.highestPercent }.max() ?? 0.0
    }

    public var highestUrgency: QuotaThreshold {
        QuotaThreshold.from(usedPercent: maxUrgencyPercent)
    }

    public var overallStatusText: String {
        let pct = Int(round(maxUrgencyPercent))
        switch highestUrgency {
        case .critical:
            return "Critical Quota (\(pct)% used)"
        case .warning:
            return "Elevated Usage (\(pct)% used)"
        case .normal:
            return "Normal / Healthy (\(pct)% used)"
        }
    }

    public var nextResetCountdownText: String {
        // Include per-group buckets: one may reset sooner than the most-consumed headline bucket.
        // Windows at 0% have nothing to reset (their reset is just "next use + window"), so skip them.
        let allMetrics = detectedUsages.flatMap(\.allMetrics).filter { $0.usedPercent > 0 }
        guard let earliest = allMetrics.map({ $0.resetDate }).filter({ $0 > Date() }).min() else {
            return "None pending"
        }
        let metric = UsageMetric(windowType: .fiveHour, usedPercent: 0, resetDate: earliest)
        return metric.formattedReset()
    }

    public func toggleProvider(_ provider: ProviderType) {
        if enabledProviders.contains(provider) {
            enabledProviders.remove(provider)
        } else {
            enabledProviders.insert(provider)
        }
    }

    private func saveEnabledProviders() {
        let rawValues = enabledProviders.map { $0.rawValue }
        UserDefaults.standard.set(rawValues, forKey: "GravityBar_enabledProviders")
    }

    private func startPolling() {
        pollingTimer?.invalidate()
        pollingTimer = Timer.scheduledTimer(withTimeInterval: pollingIntervalSeconds, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.refreshAll()
            }
        }
    }

    private func restartPolling() {
        startPolling()
    }

    private func startCountdownTimer() {
        countdownTimer?.invalidate()
        countdownTimer = Timer.scheduledTimer(withTimeInterval: 15.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.objectWillChange.send()
            }
        }
    }

    deinit {
        pollingTimer?.invalidate()
        countdownTimer?.invalidate()
    }
}
