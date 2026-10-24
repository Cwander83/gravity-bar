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
        let defaultPath = "~/.gemini/antigravity-ide/metrics.json"
        let path = customStatePath ?? defaultPath
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

    private func fetchFromLocalLanguageServer() async -> ProviderUsage? {
        // Step A: Run lsof to get listening ports of language_server
        let lsofTask = Process()
        lsofTask.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        lsofTask.arguments = ["-iTCP", "-sTCP:LISTEN", "-P", "-n"]
        let lsofPipe = Pipe()
        lsofTask.standardOutput = lsofPipe

        var pidPorts: [String: [Int]] = [:]
        if (try? lsofTask.run()) != nil {
            let lsofData = lsofPipe.fileHandleForReading.readDataToEndOfFile()
            lsofTask.waitUntilExit()
            let lsofOutput = String(data: lsofData, encoding: .utf8) ?? ""
            for line in lsofOutput.components(separatedBy: "\n") {
                if line.contains("language_") {
                    let parts = line.split(separator: " ").map { String($0) }
                    if parts.count >= 9 {
                        let pid = parts[1]
                        let addr = parts[8]
                        if let colonIdx = addr.range(of: ":", options: .backwards) {
                            let portStr = String(addr[colonIdx.upperBound...])
                            if let port = Int(portStr) {
                                pidPorts[pid, default: []].append(port)
                            }
                        }
                    }
                }
            }
        }

        guard !pidPorts.isEmpty else { return nil }

        // Step B: Run ps to get csrf tokens for these PIDs
        let psTask = Process()
        psTask.executableURL = URL(fileURLWithPath: "/bin/ps")
        psTask.arguments = ["-ef"]
        let psPipe = Pipe()
        psTask.standardOutput = psPipe

        var pidTokens: [String: String] = [:]
        if (try? psTask.run()) != nil {
            let psData = psPipe.fileHandleForReading.readDataToEndOfFile()
            psTask.waitUntilExit()
            let psOutput = String(data: psData, encoding: .utf8) ?? ""
            for line in psOutput.components(separatedBy: "\n") {
                for pid in pidPorts.keys {
                    if line.contains(" \(pid) ") && line.contains("--csrf_token") {
                        if let range = line.range(of: "--csrf_token ") {
                            let sub = line[range.upperBound...]
                            if let token = sub.components(separatedBy: " ").first {
                                pidTokens[pid] = token
                            }
                        }
                    }
                }
            }
        }

        // Step C: Query RetrieveUserQuotaSummary on every language_server instance.
        // Several IDE windows can each run a language_server, and only some report every group
        // (e.g. "Gemini 4 Argon"), so walk PIDs/ports in sorted order and merge all responses.
        let sessionConfig = URLSessionConfiguration.ephemeral
        sessionConfig.timeoutIntervalForRequest = 1.5
        let delegate = LocalhostTrustDelegate()
        let session = URLSession(configuration: sessionConfig, delegate: delegate, delegateQueue: nil)

        let now = Date()
        var responses: [[QuotaGroup]] = []

        let sortedPids = pidPorts.keys.sorted { (Int($0) ?? 0) < (Int($1) ?? 0) }
        for pid in sortedPids {
            guard let token = pidTokens[pid], let ports = pidPorts[pid] else { continue }
            for port in ports.sorted() {
                guard let url = URL(string: "https://127.0.0.1:\(port)/exa.language_server_pb.LanguageServerService/RetrieveUserQuotaSummary") else {
                    continue
                }

                var request = URLRequest(url: url)
                request.httpMethod = "POST"
                request.addValue("application/json", forHTTPHeaderField: "Content-Type")
                request.addValue(token, forHTTPHeaderField: "X-Codeium-Csrf-Token")
                request.httpBody = Data("{}".utf8)

                do {
                    let (data, response) = try await session.data(for: request)
                    guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
                        continue
                    }

                    if let groups = AntigravityProvider.parseQuotaGroups(from: data, now: now) {
                        responses.append(groups)
                        break // One answering port per PID is enough
                    }
                } catch {
                    continue
                }
            }
        }

        guard !responses.isEmpty else { return nil }
        return AntigravityProvider.makeUsage(groups: AntigravityProvider.mergeQuotaGroups(responses), now: now)
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
final class LocalhostTrustDelegate: NSObject, URLSessionDelegate {
    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        if let trust = challenge.protectionSpace.serverTrust {
            completionHandler(.useCredential, URLCredential(trust: trust))
        } else {
            completionHandler(.performDefaultHandling, nil)
        }
    }
}
