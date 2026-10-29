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
            setupProvidersIfNeeded()
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
            setupProvidersIfNeeded()
        }
    }

    @Published public var codexPath: String {
        didSet {
            UserDefaults.standard.set(codexPath, forKey: "GravityBar_codexPath")
            setupProvidersIfNeeded()
        }
    }

    @Published public var geminiPath: String {
        didSet {
            UserDefaults.standard.set(geminiPath, forKey: "GravityBar_geminiPath")
            setupProvidersIfNeeded()
        }
    }

    @Published public var showingSettings: Bool = false
    @Published public var isSpinning: Bool = false
    @Published public var isPopoverOpen: Bool = false {
        didSet {
            guard isPopoverOpen != oldValue else { return }
            if isPopoverOpen {
                startCountdownTimer()
                objectWillChange.send()
            } else {
                stopCountdownTimer()
            }
        }
    }

    public var isCountdownTimerRunning: Bool {
        countdownTimer != nil
    }

    @Published public private(set) var isRefreshing: Bool = false
    @Published public private(set) var lastUpdated: Date?

    private var pollingTimer: Timer?
    private var countdownTimer: Timer?

    private var lastConfiguredMockMode: Bool?
    private var lastConfiguredClaudePath: String?
    private var lastConfiguredCodexPath: String?
    private var lastConfiguredGeminiPath: String?

    internal private(set) var providers: [ProviderType: UsageProvider] = [:]

    public init(startPollingImmediately: Bool = true) {
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

        let claudeDefaultPath = ProviderPaths.claudeDefault
        let legacyClaudePath = "~/.claude/state.json"
        // Earlier builds defaulted to ~/.claude/state.json, which Claude never writes; migrate it to the real file
        if let saved = defaults.string(forKey: "GravityBar_claudePath"), saved != legacyClaudePath {
            self.claudePath = saved
        } else {
            self.claudePath = claudeDefaultPath
        }
        let codexDefaultPath = ProviderPaths.codexDefault
        // Earlier builds defaulted to ~/.codex/session.json, which Codex never writes; migrate it to the rollout logs
        if let saved = defaults.string(forKey: "GravityBar_codexPath"), saved != "~/.codex/session.json" {
            self.codexPath = saved
        } else {
            self.codexPath = codexDefaultPath
        }
        self.geminiPath = defaults.string(forKey: "GravityBar_geminiPath") ?? ProviderPaths.geminiDefault


        setupProvidersIfNeeded()
        if startPollingImmediately {
            startPolling()
            if isPopoverOpen {
                startCountdownTimer()
            }

            Task {
                await refreshAll()
            }
        }
    }

    func setupProvidersIfNeeded() {
        guard providers.isEmpty ||
            lastConfiguredMockMode != isMockMode ||
            lastConfiguredClaudePath != claudePath ||
            lastConfiguredCodexPath != codexPath ||
            lastConfiguredGeminiPath != geminiPath else {
            return
        }
        setupProviders()
    }

    private func setupProviders() {
        lastConfiguredMockMode = isMockMode
        lastConfiguredClaudePath = claudePath
        lastConfiguredCodexPath = codexPath
        lastConfiguredGeminiPath = geminiPath

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
        setupProvidersIfNeeded()

        // Fetch all enabled providers in parallel. fetchUsage is nonisolated async, so child tasks run off the
        // main actor; only the result assignment below happens on it.
        let toFetch = ProviderType.allCases
            .filter { enabledProviders.contains($0) }
            .compactMap { type in providers[type].map { (type, $0) } }

        let results = await withTaskGroup(of: (ProviderType, ProviderUsage).self) { group in
            for (providerType, provider) in toFetch {
                group.addTask {
                    do {
                        return (providerType, try await provider.fetchUsage())
                    } catch {
                        // Surface the failure instead of fabricating 0% with fake reset timers
                        return (providerType, .unavailable(providerType, state: .error(error.localizedDescription)))
                    }
                }
            }

            var collected: [ProviderType: ProviderUsage] = [:]
            for await (providerType, usage) in group {
                collected[providerType] = usage
            }
            return collected
        }

        for (providerType, usage) in results {
            providerUsages[providerType] = usage
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

    /// True once a refresh has finished and at least one shown provider has real data, so 0% is a reading
    /// rather than "not loaded yet".
    public var hasReadings: Bool {
        lastUpdated != nil && !detectedUsages.isEmpty
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
        guard isPopoverOpen else {
            countdownTimer = nil
            return
        }
        countdownTimer = Timer.scheduledTimer(withTimeInterval: 15.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self = self, self.isPopoverOpen else { return }
                self.objectWillChange.send()
            }
        }
    }

    private func stopCountdownTimer() {
        countdownTimer?.invalidate()
        countdownTimer = nil
    }

    deinit {
        pollingTimer?.invalidate()
        countdownTimer?.invalidate()
    }
}
