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
            self.enabledProviders = Set(savedProviders.compactMap { ProviderType(rawValue: $0) })
        } else {
            self.enabledProviders = Set(ProviderType.allCases)
        }

        self.isMockMode = defaults.object(forKey: "GravityBar_isMockMode") as? Bool ?? false
        self.hoverToOpen = defaults.object(forKey: "GravityBar_hoverToOpen") as? Bool ?? true

        let interval = defaults.double(forKey: "GravityBar_pollingInterval")
        self.pollingIntervalSeconds = interval > 0 ? interval : 60.0

        self.claudePath = defaults.string(forKey: "GravityBar_claudePath") ?? "~/Library/Application Support/Claude/plan-usage-history.json"
        self.codexPath = defaults.string(forKey: "GravityBar_codexPath") ?? "~/.codex/session.json"
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
                .gemini: MockProvider(providerType: .gemini)
            ]
        } else {
            providers = [
                .claude: ClaudeProvider(customStatePath: claudePath),
                .codex: CodexProvider(customStatePath: codexPath),
                .gemini: AntigravityProvider(customStatePath: geminiPath)
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
                let fallback = ProviderUsage(
                    provider: providerType,
                    fiveHourMetric: UsageMetric(windowType: .fiveHour, usedPercent: 0.0, resetDate: Date().addingTimeInterval(5 * 3600)),
                    weeklyMetric: UsageMetric(windowType: .weekly, usedPercent: 0.0, resetDate: Date().addingTimeInterval(7 * 86400))
                )
                providerUsages[providerType] = fallback
            }

        }

        lastUpdated = Date()
        isRefreshing = false
    }

    public var activeUsages: [ProviderUsage] {
        ProviderType.allCases
            .filter { enabledProviders.contains($0) }
            .compactMap { providerUsages[$0] }
    }

    public var maxUrgencyPercent: Double {
        activeUsages.map { $0.highestPercent }.max() ?? 0.0
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
        let allMetrics = activeUsages.flatMap { [$0.fiveHourMetric, $0.weeklyMetric] }
        guard let earliest = allMetrics.map({ $0.resetDate }).filter({ $0 > Date() }).min() else {
            return "Resets momentarily"
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
