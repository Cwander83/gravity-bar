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

        if FileManager.default.fileExists(atPath: expandedPath),
           let data = try? Data(contentsOf: URL(fileURLWithPath: expandedPath)),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let fh = json["fiveHourPercent"] as? Double { fiveHour = fh }
            else if let fhInt = json["fiveHourPercent"] as? Int { fiveHour = Double(fhInt) }

            if let wk = json["weeklyPercent"] as? Double { weekly = wk }
            else if let wkInt = json["weeklyPercent"] as? Int { weekly = Double(wkInt) }

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
            )
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

        // Step C: Query RetrieveUserQuotaSummary
        let sessionConfig = URLSessionConfiguration.ephemeral
        sessionConfig.timeoutIntervalForRequest = 1.5
        let delegate = LocalhostTrustDelegate()
        let session = URLSession(configuration: sessionConfig, delegate: delegate, delegateQueue: nil)

        let isoFormatter = ISO8601DateFormatter()
        let now = Date()

        for (pid, ports) in pidPorts {
            guard let token = pidTokens[pid] else { continue }
            for port in ports {
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

                    if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                       let respObj = json["response"] as? [String: Any],
                       let groups = respObj["groups"] as? [[String: Any]] {

                        var fiveHourRemaining = 1.0
                        var weeklyRemaining = 1.0
                        var resetFiveHour = now.addingTimeInterval(5 * 3600)
                        var resetWeekly = now.addingTimeInterval(7 * 86400)

                        for group in groups {
                            let groupName = (group["displayName"] as? String) ?? ""
                            guard groupName.contains("Gemini") || groupName.contains("Models") else { continue }

                            if let buckets = group["buckets"] as? [[String: Any]] {
                                for bucket in buckets {
                                    let window = (bucket["window"] as? String) ?? ""
                                    let remaining = (bucket["remainingFraction"] as? Double) ?? 1.0 // Fraction LEFT, not used (1.0 = untouched)

                                    if let resetStr = bucket["resetTime"] as? String,
                                       let parsedDate = isoFormatter.date(from: resetStr) {
                                        if window == "5h" {
                                            fiveHourRemaining = remaining
                                            resetFiveHour = parsedDate
                                        } else if window == "weekly" {
                                            weeklyRemaining = remaining
                                            resetWeekly = parsedDate
                                        }
                                    } else {
                                        if window == "5h" { fiveHourRemaining = remaining }
                                        else if window == "weekly" { weeklyRemaining = remaining }
                                    }
                                }
                            }
                        }

                        return ProviderUsage(
                            provider: .gemini,
                            fiveHourMetric: UsageMetric(
                                windowType: .fiveHour,
                                remainingFraction: fiveHourRemaining,
                                resetDate: resetFiveHour
                            ),
                            weeklyMetric: UsageMetric(
                                windowType: .weekly,
                                remainingFraction: weeklyRemaining,
                                resetDate: resetWeekly
                            )
                        )
                    }
                } catch {
                    continue
                }
            }
        }

        return nil
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
