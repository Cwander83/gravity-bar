import Foundation

/// Provider for Claude usage metrics, parsing local state from ~/Library/Application Support/Claude/plan-usage-history.json
/// and Claude Code CLI token usage from ~/.claude/projects/**/*.jsonl transcripts.
public final class ClaudeProvider: UsageProvider {
    public let providerType: ProviderType = .claude
    public var customStatePath: String?
    public var cliProjectsPath: String

    public init(customStatePath: String? = nil, cliProjectsPath: String = "~/.claude/projects") {
        self.customStatePath = customStatePath
        self.cliProjectsPath = cliProjectsPath
    }

    public func fetchUsage() async throws -> ProviderUsage {
        let path = ProviderPaths.resolve(customStatePath, default: ProviderPaths.claudeDefault)
        let expandedPath = (path as NSString).expandingTildeInPath
        let now = Date()

        var samples: [PlanSample] = []
        if FileManager.default.fileExists(atPath: expandedPath),
           let data = try? Data(contentsOf: URL(fileURLWithPath: expandedPath)) {
            samples = ClaudeProvider.parseSamples(from: data)
        }

        let cli = ClaudeCodeUsageScanner.scan(projectsPath: cliProjectsPath, now: now)
        let lastSeen = [samples.last?.date, cli?.lastActivity].compactMap { $0 }.max()
        guard let lastSeen else {
            return .unavailable(.claude, state: .notConfigured)
        }

        // Plan windows come from Claude Desktop; a CLI-only install has token counts but no plan percentages
        let hasPlanHistory = !samples.isEmpty
        return ProviderUsage(
            provider: .claude,
            fiveHourMetric: hasPlanHistory ? ClaudeProvider.currentWindow(
                samples: samples, value: \.fiveHour, windowType: .fiveHour, length: 5 * 3600, now: now
            ) : nil,
            weeklyMetric: hasPlanHistory ? ClaudeProvider.currentWindow(
                samples: samples, value: \.weekly, windowType: .weekly, length: 7 * 86400, now: now
            ) : nil,
            cliTokenUsage: cli,
            connectionState: .fromLastSeen(lastSeen, now: now)
        )
    }

    // MARK: - Plan Usage History

    /// One entry of `plan-usage-history.json` `samples`: `{ "t": <epoch_ms>, "u": { "fh": 7, "sd": 3 } }`.
    struct PlanSample {
        let date: Date
        /// "fh" = 5-hour window percent USED
        let fiveHour: Double?
        /// "sd" = seven-day window percent USED
        let weekly: Double?
    }

    /// Parses samples sorted by time. Samples with an empty `u` keep nil values and are skipped by window inference.
    static func parseSamples(from data: Data) -> [PlanSample] {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rawSamples = json["samples"] as? [[String: Any]] else {
            return []
        }

        return rawSamples.compactMap { sample -> PlanSample? in
            guard let timestampMs = (sample["t"] as? NSNumber)?.doubleValue else { return nil }
            let u = sample["u"] as? [String: Any]
            return PlanSample(
                date: Date(timeIntervalSince1970: timestampMs / 1000.0),
                fiveHour: (u?["fh"] as? NSNumber)?.doubleValue,
                weekly: (u?["sd"] as? NSNumber)?.doubleValue
            )
        }
        .sorted { $0.date < $1.date }
    }

    /// Infers the active window from sample history. A sample's `t` is when it was recorded, not when the window
    /// began, so the window start is the first sample of the current non-zero run. A new run starts after a zero
    /// reading, when usage steps down (the window reset between samples), or once a full window length has elapsed.
    /// A window whose start + length has passed has already reset, so it decays to 0% even if Claude is closed
    /// and the last sample is stale.
    static func currentWindow(
        samples: [PlanSample],
        value: KeyPath<PlanSample, Double?>,
        windowType: WindowType,
        length: TimeInterval,
        now: Date = Date()
    ) -> UsageMetric {
        var windowStart: Date?
        var previous: Double?
        var latest: Double?

        for sample in samples {
            guard let used = sample[keyPath: value] else { continue }
            if used <= 0 {
                windowStart = nil
            } else if let start = windowStart, (previous ?? 0) <= used, sample.date < start.addingTimeInterval(length) {
                // Same window continues
            } else {
                windowStart = sample.date
            }
            previous = used
            latest = used
        }

        let idle = UsageMetric(windowType: windowType, usedPercent: 0, resetDate: now.addingTimeInterval(length))
        guard let used = latest, used > 0, let start = windowStart else { return idle }

        let resetDate = start.addingTimeInterval(length)
        guard resetDate > now else { return idle } // Window expired since the last sample
        return UsageMetric(windowType: windowType, usedPercent: used, resetDate: resetDate)
    }
}

// MARK: - Claude Code CLI Token Usage

/// Aggregates Claude Code CLI token usage from transcript JSONL files. Each assistant line carries
/// `message.usage`; streamed responses repeat the same `message.id`, so entries are de-duplicated by id.
enum ClaudeCodeUsageScanner {
    struct Entry {
        let id: String
        let date: Date
        let usage: TokenUsage
    }

    private static let lock = NSLock()
    /// Parsed entries per file, reused while the file's modification date is unchanged.
    private static var cache: [String: (modified: Date, entries: [Entry])] = [:]

    /// Returns nil when there is no CLI token usage in the last 7 days (e.g. CLI not installed or idle).
    static func scan(projectsPath: String, now: Date = Date()) -> CLITokenUsage? {
        let root = URL(fileURLWithPath: (projectsPath as NSString).expandingTildeInPath)
        let weekAgo = now.addingTimeInterval(-7 * 86400)

        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return nil
        }

        var entries: [Entry] = []
        lock.lock()
        defer { lock.unlock() }

        for case let url as URL in enumerator where url.pathExtension == "jsonl" {
            guard let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey]),
                  values.isRegularFile == true,
                  let modified = values.contentModificationDate,
                  modified >= weekAgo else {
                continue
            }

            if let cached = cache[url.path], cached.modified == modified {
                entries.append(contentsOf: cached.entries)
            } else if let data = try? Data(contentsOf: url) {
                let parsed = parseEntries(from: data)
                cache[url.path] = (modified, parsed)
                entries.append(contentsOf: parsed)
            }
        }

        // Old transcripts get touched by background indexing/cleanup, so a recent mtime alone does not
        // mean recent usage. No tokens in the last 7 days means nothing to show.
        let aggregated = aggregate(entries, now: now)
        return aggregated.last7d.totalTokens > 0 ? aggregated : nil
    }

    /// Parses assistant lines carrying `message.usage` from one transcript.
    static func parseEntries(from data: Data) -> [Entry] {
        let text = String(decoding: data, as: UTF8.self)
        var entries: [Entry] = []

        for line in text.split(separator: "\n") where line.contains("\"usage\"") {
            guard let json = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let message = json["message"] as? [String: Any],
                  let usage = message["usage"] as? [String: Any],
                  let timestamp = json["timestamp"] as? String,
                  let date = parseTimestamp(timestamp),
                  let id = (message["id"] as? String) ?? (json["requestId"] as? String) else {
                continue
            }

            func tokens(_ key: String) -> Int { (usage[key] as? NSNumber)?.intValue ?? 0 }
            entries.append(Entry(
                id: id,
                date: date,
                usage: TokenUsage(
                    inputTokens: tokens("input_tokens"),
                    outputTokens: tokens("output_tokens"),
                    cacheReadTokens: tokens("cache_read_input_tokens"),
                    cacheCreationTokens: tokens("cache_creation_input_tokens")
                )
            ))
        }

        return entries
    }

    /// Sums de-duplicated entries over rolling 5-hour and 7-day spans ending at `now`.
    /// Streamed multi-block turns log the same `message.id` several times, and early lines can report
    /// `output_tokens: 0`, so the line with the highest total wins (ties go to the later line).
    static func aggregate(_ entries: [Entry], now: Date = Date()) -> CLITokenUsage {
        var byId: [String: Entry] = [:]
        for entry in entries {
            if let existing = byId[entry.id],
               existing.usage.totalTokens > entry.usage.totalTokens
                || (existing.usage.totalTokens == entry.usage.totalTokens && existing.date > entry.date) {
                continue
            }
            byId[entry.id] = entry
        }

        var last5h = TokenUsage()
        var last7d = TokenUsage()
        var lastActivity: Date?

        for entry in byId.values {
            let age = now.timeIntervalSince(entry.date)
            guard age >= 0, age <= 7 * 86400 else { continue }
            lastActivity = max(lastActivity ?? entry.date, entry.date)
            last7d = last7d + entry.usage
            if age <= 5 * 3600 {
                last5h = last5h + entry.usage
            }
        }

        return CLITokenUsage(last5h: last5h, last7d: last7d, lastActivity: lastActivity)
    }

    // Shared formatters: transcripts can hold thousands of lines per poll
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
