import Foundation

/// Provider for Google Antigravity / Gemini metrics, querying the local language server RPC or fallback metrics.
public final class AntigravityProvider: UsageProvider {
    public let providerType: ProviderType = .gemini
    public var customStatePath: String?

    public init(customStatePath: String? = nil) {
        self.customStatePath = customStatePath
    }

    public func fetchUsage() async throws -> ProviderUsage {
        let now = Date()
        var fiveHour = 0.0
        var weekly = 0.0
        var resetFiveHour = now.addingTimeInterval(5 * 3600)
        var resetWeekly = now.addingTimeInterval(7 * 86400)

        // 1. Try querying local LanguageServerService via RPC (live Antigravity IDE process)
        if let liveMetrics = await fetchFromLocalLanguageServer() {
            return liveMetrics
        }

        // 2. Fallback to custom / default JSON file if configured
        let path = ProviderPaths.resolve(customStatePath, default: ProviderPaths.geminiDefault)
        let expandedPath = (path as NSString).expandingTildeInPath

        // No live language server and no fallback file: Antigravity isn't running or installed here
        guard FileManager.default.fileExists(atPath: expandedPath) else {
            return .unavailable(.gemini, state: .notConfigured)
        }
        let modified = (try? FileManager.default.attributesOfItem(atPath: expandedPath)[.modificationDate]) as? Date ?? now

        if let data = try? Data(contentsOf: URL(fileURLWithPath: expandedPath)),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let fh = json["fiveHourPercent"] as? Double { fiveHour = fh }
            else if let fhInt = json["fiveHourPercent"] as? Int { fiveHour = Double(fhInt) }

            if let wk = json["weeklyPercent"] as? Double { weekly = wk }
            else if let wkInt = json["weeklyPercent"] as? Int { weekly = Double(wkInt) }

            // Remaining-fraction keys (1.0 = untouched) mirror the live RPC polarity; used only when no percent key is present
            if json["fiveHourPercent"] == nil, let fr = json["fiveHourRemainingFraction"] as? Double {
                fiveHour = UsageMetric.usedPercent(fromRemainingFraction: fr)
            }
            if json["weeklyPercent"] == nil, let wr = json["weeklyRemainingFraction"] as? Double {
                weekly = UsageMetric.usedPercent(fromRemainingFraction: wr)
            }

            if let r5 = json["fiveHourResetInSeconds"] as? Double { resetFiveHour = now.addingTimeInterval(r5) }
            if let rw = json["weeklyResetInSeconds"] as? Double { resetWeekly = now.addingTimeInterval(rw) }
        }

        return ProviderUsage(
            provider: .gemini,
            fiveHourMetric: UsageMetric(
                windowType: .fiveHour,
                usedPercent: fiveHour,
                resetDate: resetFiveHour
            ),
            weeklyMetric: UsageMetric(
                windowType: .weekly,
                usedPercent: weekly,
                resetDate: resetWeekly
            ),
            connectionState: .idleCached(lastSeen: modified)
        )
    }

    // MARK: - Local LanguageServerService RPC Discovery

    /// A discovered language_server RPC endpoint.
    struct Endpoint: Equatable {
        let pid: Int32
        let port: Int
        let csrfToken: String
    }

    /// Endpoints from the last discovery. Providers are rebuilt on every refresh, so the cache is static.
    private static let endpointLock = NSLock()
    private static var cachedEndpoints: [Endpoint] = []
    private static var endpointsDiscoveredAt: Date?
    /// Rediscover periodically so language_server instances started later (new IDE windows) are picked up.
    static let endpointCacheLifetime: TimeInterval = 5 * 60

    private func fetchFromLocalLanguageServer() async -> ProviderUsage? {
        let sessionConfig = URLSessionConfiguration.ephemeral
        sessionConfig.timeoutIntervalForRequest = 1.5
        let session = URLSession(configuration: sessionConfig, delegate: LocalhostTrustDelegate(), delegateQueue: nil)
        let now = Date()

        // Fast path: query cached endpoints directly (no subprocesses). Any failure falls back to discovery.
        let (cached, discoveredAt) = AntigravityProvider.endpointLock.withLock {
            (AntigravityProvider.cachedEndpoints, AntigravityProvider.endpointsDiscoveredAt)
        }
        if !cached.isEmpty, let discoveredAt, now.timeIntervalSince(discoveredAt) < AntigravityProvider.endpointCacheLifetime {
            var responses: [[QuotaGroup]] = []
            for endpoint in cached {
                guard let groups = await AntigravityProvider.queryQuotaSummary(endpoint, session: session, now: now) else {
                    responses = []
                    break
                }
                responses.append(groups)
            }
            if !responses.isEmpty {
                return AntigravityProvider.makeUsage(groups: AntigravityProvider.mergeQuotaGroups(responses), now: now)
            }
        }

        // Discovery: one light `ps` pass for language_server PIDs + CSRF tokens, then `lsof` limited to those PIDs.
        // Several IDE windows can each run a language_server, and only some report every group
        // (e.g. "Gemini 4 Argon"), so walk PIDs/ports in sorted order and merge all responses.
        let servers = AntigravityProvider.parseLanguageServers(
            psOutput: await AntigravityProvider.runCommand("/bin/ps", ["-ax", "-o", "pid=,command="])
        )
        guard !servers.isEmpty else {
            AntigravityProvider.storeEndpoints([], at: now)
            return nil
        }

        let pidList = servers.keys.sorted().map(String.init).joined(separator: ",")
        let ports = AntigravityProvider.parseListeningPorts(
            lsofOutput: await AntigravityProvider.runCommand("/usr/sbin/lsof", ["-Pan", "-p", pidList, "-iTCP", "-sTCP:LISTEN"])
        )

        var endpoints: [Endpoint] = []
        var responses: [[QuotaGroup]] = []
        for pid in servers.keys.sorted() {
            guard let token = servers[pid] else { continue }
            for port in (ports[pid] ?? []).sorted() {
                let endpoint = Endpoint(pid: pid, port: port, csrfToken: token)
                if let groups = await AntigravityProvider.queryQuotaSummary(endpoint, session: session, now: now) {
                    endpoints.append(endpoint)
                    responses.append(groups)
                    break // One answering port per PID is enough
                }
            }
        }

        AntigravityProvider.storeEndpoints(endpoints, at: now)
        guard !responses.isEmpty else { return nil }
        return AntigravityProvider.makeUsage(groups: AntigravityProvider.mergeQuotaGroups(responses), now: now)
    }

    private static func storeEndpoints(_ endpoints: [Endpoint], at date: Date) {
        endpointLock.withLock {
            cachedEndpoints = endpoints
            endpointsDiscoveredAt = endpoints.isEmpty ? nil : date
        }
    }

    /// POSTs RetrieveUserQuotaSummary; nil on any transport error, non-200 status or unparseable body.
    static func queryQuotaSummary(_ endpoint: Endpoint, session: URLSession, now: Date) async -> [QuotaGroup]? {
        guard let url = URL(string: "https://127.0.0.1:\(endpoint.port)/exa.language_server_pb.LanguageServerService/RetrieveUserQuotaSummary") else {
            return nil
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")
        request.addValue(endpoint.csrfToken, forHTTPHeaderField: "X-Codeium-Csrf-Token")
        request.httpBody = Data("{}".utf8)

        guard let (data, response) = try? await session.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200 else {
            return nil
        }
        return parseQuotaGroups(from: data, now: now)
    }

    /// Maps language_server PIDs to their `--csrf_token` from `ps -ax -o pid=,command=` output.
    /// Matches the exact `--csrf_token` argument, not `--extension_server_csrf_token`.
    static func parseLanguageServers(psOutput: String) -> [Int32: String] {
        var servers: [Int32: String] = [:]
        for line in psOutput.split(separator: "\n") where line.contains("language_server") {
            let parts = line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
            guard let pid = parts.first.flatMap({ Int32($0) }),
                  let flagIndex = parts.firstIndex(of: "--csrf_token"),
                  flagIndex + 1 < parts.count else {
                continue
            }
            servers[pid] = parts[flagIndex + 1]
        }
        return servers
    }

    /// Maps PIDs to listening TCP ports from `lsof -Pan -p <pids> -iTCP -sTCP:LISTEN` output.
    static func parseListeningPorts(lsofOutput: String) -> [Int32: [Int]] {
        var ports: [Int32: [Int]] = [:]
        for line in lsofOutput.split(separator: "\n") where line.contains("(LISTEN)") {
            let parts = line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
            guard parts.count >= 9,
                  let pid = Int32(parts[1]),
                  let address = parts.dropLast().last, // NAME column, before "(LISTEN)"
                  let colon = address.range(of: ":", options: .backwards),
                  let port = Int(address[colon.upperBound...]) else {
                continue
            }
            ports[pid, default: []].append(port)
        }
        return ports
    }

    /// Runs a short-lived command on a GCD worker so its blocking pipe read and `waitUntilExit`
    /// never tie up the main thread or a Swift concurrency thread. Returns stdout, or "" on failure.
    static func runCommand(_ path: String, _ arguments: [String]) async -> String {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: path)
                process.arguments = arguments
                let pipe = Pipe()
                process.standardOutput = pipe
                process.standardError = FileHandle.nullDevice

                guard (try? process.run()) != nil else {
                    continuation.resume(returning: "")
                    return
                }
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                continuation.resume(returning: String(data: data, encoding: .utf8) ?? "")
            }
        }
    }

    // MARK: - Quota Summary Parsing & Aggregation

    /// Parses every group in a `RetrieveUserQuotaSummary` response. Returns nil when the payload has no `response.groups`.
    static func parseQuotaGroups(from data: Data, now: Date = Date()) -> [QuotaGroup]? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let respObj = json["response"] as? [String: Any],
              let groups = respObj["groups"] as? [[String: Any]] else {
            return nil
        }

        return groups.compactMap { group in
            guard let name = group["displayName"] as? String, !name.isEmpty else { return nil }
            var parsed = QuotaGroup(name: name)

            for bucket in (group["buckets"] as? [[String: Any]]) ?? [] {
                let window = (bucket["window"] as? String) ?? ""
                let remaining = (bucket["remainingFraction"] as? Double) ?? 1.0 // Fraction LEFT, not used (1.0 = untouched)
                let parsedReset = (bucket["resetTime"] as? String).flatMap(parseResetTime)

                if window == "5h" {
                    parsed.fiveHourMetric = UsageMetric(
                        windowType: .fiveHour,
                        remainingFraction: remaining,
                        resetDate: parsedReset ?? now.addingTimeInterval(5 * 3600)
                    )
                } else if window == "weekly" {
                    parsed.weeklyMetric = UsageMetric(
                        windowType: .weekly,
                        remainingFraction: remaining,
                        resetDate: parsedReset ?? now.addingTimeInterval(7 * 86400)
                    )
                }
            }

            return parsed.metrics.isEmpty ? nil : parsed
        }
    }

    /// Parses protobuf-JSON timestamps, which may or may not carry fractional seconds (e.g. "2026-10-24T03:42:18.491Z").
    static func parseResetTime(_ string: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: string) { return date }

        let whole = ISO8601DateFormatter()
        whole.formatOptions = [.withInternetDateTime]
        return whole.date(from: string)
    }

    /// Display order for known groups; unknown groups follow alphabetically.
    static let groupDisplayOrder = ["Gemini Models", "Gemini 4 Argon", "Claude and GPT models"]

    /// Merges groups from several language_server responses by group name, keeping the most-consumed
    /// bucket per window. Output uses `groupDisplayOrder` then name, so it is independent of response order and subsets.
    static func mergeQuotaGroups(_ responses: [[QuotaGroup]]) -> [QuotaGroup] {
        var merged: [QuotaGroup] = []
        for groups in responses {
            for group in groups {
                if let idx = merged.firstIndex(where: { $0.name == group.name }) {
                    merged[idx].fiveHourMetric = mostConsumed(merged[idx].fiveHourMetric, group.fiveHourMetric)
                    merged[idx].weeklyMetric = mostConsumed(merged[idx].weeklyMetric, group.weeklyMetric)
                } else {
                    merged.append(group)
                }
            }
        }
        return merged.sorted { lhs, rhs in
            let lhsRank = groupDisplayOrder.firstIndex(of: lhs.name) ?? groupDisplayOrder.count
            let rhsRank = groupDisplayOrder.firstIndex(of: rhs.name) ?? groupDisplayOrder.count
            return lhsRank != rhsRank ? lhsRank < rhsRank : lhs.name < rhs.name
        }
    }

    /// Builds the provider usage: headline metrics are the most-consumed bucket per window across all groups.
    static func makeUsage(groups: [QuotaGroup], now: Date = Date()) -> ProviderUsage {
        let fiveHour = groups.compactMap { $0.fiveHourMetric }.reduce(nil, mostConsumed)
        let weekly = groups.compactMap { $0.weeklyMetric }.reduce(nil, mostConsumed)

        return ProviderUsage(
            provider: .gemini,
            fiveHourMetric: fiveHour,
            weeklyMetric: weekly,
            groups: groups,
            connectionState: .connected
        )
    }

    /// Picks the higher-usage metric; ties go to the earlier reset so the countdown stays conservative.
    private static func mostConsumed(_ lhs: UsageMetric?, _ rhs: UsageMetric?) -> UsageMetric? {
        guard let lhs else { return rhs }
        guard let rhs else { return lhs }
        if rhs.usedPercent != lhs.usedPercent {
            return rhs.usedPercent > lhs.usedPercent ? rhs : lhs
        }
        return rhs.resetDate < lhs.resetDate ? rhs : lhs
    }
}

/// Helper delegate accepting self-signed TLS certificates for localhost language server connections.
/// Only loopback hosts are trusted this way; any other host gets the system's normal certificate checks.
final class LocalhostTrustDelegate: NSObject, URLSessionDelegate {
    static let loopbackHosts: Set<String> = ["127.0.0.1", "localhost", "::1"]

    /// True only for a server-trust challenge from a loopback host.
    static func shouldTrust(host: String, authenticationMethod: String) -> Bool {
        authenticationMethod == NSURLAuthenticationMethodServerTrust && loopbackHosts.contains(host.lowercased())
    }

    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        let space = challenge.protectionSpace
        if LocalhostTrustDelegate.shouldTrust(host: space.host, authenticationMethod: space.authenticationMethod),
           let trust = space.serverTrust {
            completionHandler(.useCredential, URLCredential(trust: trust))
        } else {
            completionHandler(.performDefaultHandling, nil)
        }
    }
}
