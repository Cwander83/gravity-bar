import Foundation
import AppKit

/// Provider for Codex usage metrics, parsing the Codex CLI rollout logs in ~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl.
/// Each `token_count` event carries the account's rate-limit windows and the session's cumulative token usage.
public final class CodexProvider: UsageProvider {
    public let providerType: ProviderType = .codex
    /// A sessions directory (scanned recursively) or a single rollout `.jsonl` file.
    public var customStatePath: String?

    public init(customStatePath: String? = nil) {
        self.customStatePath = customStatePath
    }

    public func fetchUsage() async throws -> ProviderUsage {
        let path = ProviderPaths.resolve(customStatePath, default: ProviderPaths.codexDefault)
        let now = Date()
        let events = CodexRolloutScanner.scan(path: path)
        return CodexProvider.makeUsage(events: events, chatGPTApp: CodexProvider.detectChatGPTApp(), now: now)
    }

    /// ChatGPT desktop shares the account's OpenAI limits; list it on the card when installed.
    static func detectChatGPTApp() -> ActiveModel? {
        let running = NSWorkspace.shared.runningApplications.contains { $0.bundleIdentifier == "com.openai.chat" }
        let installed = running || FileManager.default.fileExists(atPath: "/Applications/ChatGPT.app")
        guard installed else { return nil }
        return ActiveModel(name: "ChatGPT desktop", detail: running ? "running" : "installed", isRunning: running)
    }

    /// Builds usage from the latest event that reports rate limits, plus rolling token totals.
    /// Only windows Codex actually reports are set (e.g. Plus currently reports a weekly window only).
    static func makeUsage(events: [CodexRolloutScanner.Event], chatGPTApp: ActiveModel? = nil, now: Date = Date()) -> ProviderUsage {
        let models = [chatGPTApp].compactMap { $0 }
        // A running ChatGPT desktop app means the account is in use now, whatever the CLI logs say
        let chatGPTRunning = chatGPTApp?.isRunning == true
        guard let lastSeen = events.map(\.date).max() else {
            return ProviderUsage(
                provider: .codex,
                fiveHourMetric: nil,
                weeklyMetric: nil,
                connectionState: chatGPTRunning ? .connected : .notConfigured,
                models: models
            )
        }

        let latest = events
            .filter { !$0.windows.isEmpty }
            .max { $0.date < $1.date }

        let metrics = (latest?.windows ?? []).map { $0.metric(now: now) }
        let fiveHour = metrics.first { $0.windowType == .fiveHour }
        let longest = (latest?.windows ?? [])
            .filter { $0.windowMinutes > 360 }
            .max { $0.windowMinutes < $1.windowMinutes }?
            .metric(now: now)

        let tokens = CodexRolloutScanner.tokenUsage(events, now: now)

        // Only windows Codex reports are set; the card hides the missing one
        return ProviderUsage(
            provider: .codex,
            fiveHourMetric: fiveHour,
            weeklyMetric: longest,
            cliTokenUsage: tokens.last7d.totalTokens > 0 ? tokens : nil,
            connectionState: chatGPTRunning ? .connected : .fromLastSeen(lastSeen, now: now),
            planBadge: latest?.planType?.capitalized,
            models: models
        )
    }
}

// MARK: - Rollout Parsing

/// Parses `token_count` events out of Codex rollout JSONL files, caching each file by modification date.
enum CodexRolloutScanner {
    struct Window: Equatable {
        let usedPercent: Double
        let windowMinutes: Int
        let resetsAt: Date

        var windowType: WindowType {
            switch windowMinutes {
            case ...360: return .fiveHour
            case ...(14 * 1440): return .weekly
            default: return .monthly
            }
        }

        /// A window whose `resets_at` has passed has already reset: 0% used, next reset one window later.
        func metric(now: Date = Date()) -> UsageMetric {
            guard resetsAt <= now else {
                return UsageMetric(windowType: windowType, usedPercent: usedPercent, resetDate: resetsAt)
            }
            let length = TimeInterval(max(windowMinutes, 1) * 60)
            let elapsedWindows = (now.timeIntervalSince(resetsAt) / length).rounded(.down) + 1
            return UsageMetric(windowType: windowType, usedPercent: 0, resetDate: resetsAt.addingTimeInterval(elapsedWindows * length))
        }
    }

    struct Event {
        /// Rollout file the event came from; `total_token_usage` is cumulative within one session file.
        let session: String
        let date: Date
        let windows: [Window]
        let planType: String?
        let totalUsage: TokenUsage?
    }

    private static let lock = NSLock()
    private static var cache: [String: (modified: Date, events: [Event])] = [:]

    static func scan(path: String) -> [Event] {
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else { return [] }

        let files: [URL]
        if isDirectory.boolValue {
            let enumerator = FileManager.default.enumerator(
                at: url,
                includingPropertiesForKeys: [.contentModificationDateKey],
                options: [.skipsHiddenFiles]
            )
            files = (enumerator?.allObjects as? [URL] ?? []).filter {
                $0.pathExtension == "jsonl" && $0.lastPathComponent.hasPrefix("rollout-")
            }
        } else {
            files = [url]
        }

        lock.lock()
        defer { lock.unlock() }

        var events: [Event] = []
        for file in files {
            guard let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate else {
                continue
            }
            if let cached = cache[file.path], cached.modified == modified {
                events.append(contentsOf: cached.events)
            } else if let data = try? Data(contentsOf: file) {
                let parsed = parseEvents(from: data, session: file.path)
                cache[file.path] = (modified, parsed)
                events.append(contentsOf: parsed)
            }
        }
        return events
    }

    /// Parses `{"timestamp": ..., "type": "event_msg", "payload": {"type": "token_count", "info": ..., "rate_limits": ...}}` lines.
    static func parseEvents(from data: Data, session: String) -> [Event] {
        let text = String(decoding: data, as: UTF8.self)
        var events: [Event] = []

        for line in text.split(separator: "\n") where line.contains("\"token_count\"") {
            guard let json = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let payload = json["payload"] as? [String: Any],
                  payload["type"] as? String == "token_count",
                  let timestamp = json["timestamp"] as? String,
                  let date = parseTimestamp(timestamp) else {
                continue
            }

            let rateLimits = payload["rate_limits"] as? [String: Any]
            let windows = ["primary", "secondary"].compactMap { key -> Window? in
                guard let window = rateLimits?[key] as? [String: Any],
                      let used = (window["used_percent"] as? NSNumber)?.doubleValue,
                      let minutes = (window["window_minutes"] as? NSNumber)?.intValue,
                      let resetsAt = (window["resets_at"] as? NSNumber)?.doubleValue else {
                    return nil
                }
                return Window(usedPercent: used, windowMinutes: minutes, resetsAt: Date(timeIntervalSince1970: resetsAt))
            }

            var totalUsage: TokenUsage?
            if let info = payload["info"] as? [String: Any],
               let total = info["total_token_usage"] as? [String: Any] {
                func tokens(_ key: String) -> Int { (total[key] as? NSNumber)?.intValue ?? 0 }
                let cached = tokens("cached_input_tokens")
                // Codex input_tokens includes cached input; split it so the cache column isn't double counted.
                // output_tokens already includes reasoning_output_tokens.
                totalUsage = TokenUsage(
                    inputTokens: max(0, tokens("input_tokens") - cached),
                    outputTokens: tokens("output_tokens"),
                    cacheReadTokens: cached,
                    cacheCreationTokens: tokens("cache_write_input_tokens")
                )
            }

            events.append(Event(
                session: session,
                date: date,
                windows: windows,
                planType: rateLimits?["plan_type"] as? String,
                totalUsage: totalUsage
            ))
        }

        return events
    }

    /// Tokens used over rolling 5h / 7d spans. `total_token_usage` is cumulative per session, so each
    /// session contributes (last total inside the span) − (last total before the span starts).
    static func tokenUsage(_ events: [Event], now: Date = Date()) -> CLITokenUsage {
        func used(since start: Date) -> TokenUsage {
            var sum = TokenUsage()
            for (_, sessionEvents) in Dictionary(grouping: events.filter { $0.totalUsage != nil }, by: \.session) {
                let sorted = sessionEvents.sorted { $0.date < $1.date }
                guard let end = sorted.last(where: { $0.date <= now })?.totalUsage,
                      sorted.contains(where: { $0.date > start && $0.date <= now }) else {
                    continue
                }
                let baseline = sorted.last(where: { $0.date <= start })?.totalUsage ?? TokenUsage()
                sum = sum + end - baseline
            }
            return sum
        }

        return CLITokenUsage(
            last5h: used(since: now.addingTimeInterval(-5 * 3600)),
            last7d: used(since: now.addingTimeInterval(-7 * 86400)),
            lastActivity: events.filter { $0.totalUsage != nil && $0.date <= now }.map(\.date).max()
        )
    }

    private static let fractionalFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
    private static let wholeSecondFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    private static func parseTimestamp(_ string: String) -> Date? {
        fractionalFormatter.date(from: string) ?? wholeSecondFormatter.date(from: string)
    }
}
