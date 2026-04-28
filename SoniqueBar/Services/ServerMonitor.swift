import Foundation
import AppKit
import Network

@MainActor
class ServerMonitor: ObservableObject {
    @Published var isOnline = false
    @Published var profile: AssistantProfile?
    @Published var avatarImage: NSImage?
    @Published var hasActiveVoiceSession = false

    let settings = MacSettings()
    let containerManager = ContainerManager()
    let sidecarManager = SidecarManager()
    let premium = PremiumManager()
    let systemControl = SystemControlManager()
    let chatManager = ChatManager()
    let contractEndpoint = ContractEndpointService()

    private var pollTask: Task<Void, Never>?
    private var bootSelfHealAttempted = false

    init() {
        contractEndpoint.start()
        Task { [weak self] in
            guard let self else { return }
            // Let MenuBarExtra render once before embedded unpack / Docker probes.
            await Task.yield()
            switch settings.deploymentMode {
            case .networked:
                await containerManager.setup(caelDirectory: settings.caelDirectory)
            case .embedded:
                await sidecarManager.start()
                if case .failed = sidecarManager.state {
                    // Embedded runtime can fail under sandbox exec/signing constraints.
                    // Fall back to the networked CAAL stack so voice remains available.
                    settings.deploymentMode = .networked
                    await containerManager.setup(caelDirectory: settings.caelDirectory)
                }
            }
            startPolling()
            await attemptBootSelfHealIfNeeded()
        }
    }

    deinit {
        contractEndpoint.stop()
    }

    /// Apply a deployment-mode change at runtime: tear down the supervisor
    /// that's currently driving CAAL and bring up the other. Called from the
    /// Settings UI when the user flips the toggle.
    func applyDeploymentMode(_ mode: SidecarManager.DeploymentMode) async {
        settings.deploymentMode = mode
        switch mode {
        case .networked:
            sidecarManager.stop()
            await containerManager.setup(caelDirectory: settings.caelDirectory)
        case .embedded:
            // Leave networked stack running — user may have other tools
            // pointed at it. Just bring up the sidecar instead.
            await sidecarManager.start()
        }
    }

    func startPolling() {
        pollTask?.cancel()
        chatManager.configure(backendURL: settings.backendURL, apiKey: settings.apiKey)
        systemControl.start(backendURL: settings.backendURL, apiKey: settings.apiKey)
        pollTask = Task {
            while !Task.isCancelled {
                await refresh()
                try? await Task.sleep(for: .seconds(30))
            }
        }
    }

    func refresh() async {
        guard settings.isConfigured else { return }
        await checkHealth()
        await fetchProfile()
    }

    private var timezoneSynced = false

    private func checkHealth() async {
        guard let url = URL(string: "\(settings.effectiveURL)/api/settings") else {
            isOnline = false; return
        }
        var req = URLRequest(url: url, timeoutInterval: 5)
        if !settings.apiKey.isEmpty { req.setValue(settings.apiKey, forHTTPHeaderField: "x-api-key") }
        do {
            let (_, response) = try await URLSession.shared.data(for: req)
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            let wasOffline = !isOnline
            isOnline = code == 200 || code == 401
            if isOnline && (wasOffline || !timezoneSynced) {
                await syncTimezone()
            }
        } catch { isOnline = false }

        await checkActiveSession()
    }

    private func checkActiveSession() async {
        // /health returns active_sessions: [...LiveKit room names...] — non-empty means
        // a voice session is live. This is accurate because LiveKit rooms only exist
        // while there's an active WebRTC connection.
        guard isOnline,
              let url = URL(string: "\(settings.backendURL)/health")
        else { hasActiveVoiceSession = false; return }
        var req = URLRequest(url: url, timeoutInterval: 3)
        if !settings.apiKey.isEmpty { req.setValue(settings.apiKey, forHTTPHeaderField: "x-api-key") }
        guard let (data, _) = try? await URLSession.shared.data(for: req),
              let payload = try? JSONDecoder().decode(HealthPayload.self, from: data)
        else { hasActiveVoiceSession = false; return }
        hasActiveVoiceSession = !payload.activeSessions.isEmpty
    }

    /// Detect the local Tailscale IP (if Tailscale is installed and connected).
    func detectTailscaleIP() async -> String? {
        await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .utility).async {
                let task = Process()
                task.executableURL = URL(fileURLWithPath: "/usr/bin/env")
                task.arguments = ["tailscale", "ip", "-4"]
                let pipe = Pipe()
                task.standardOutput = pipe
                task.standardError = Pipe()
                try? task.run()
                task.waitUntilExit()
                let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                if task.terminationStatus == 0, !output.isEmpty {
                    cont.resume(returning: output)
                } else {
                    cont.resume(returning: nil)
                }
            }
        }
    }

    private struct HealthPayload: Decodable {
        let status: String
        let activeSessions: [String]
        enum CodingKeys: String, CodingKey {
            case status
            case activeSessions = "active_sessions"
        }
    }

    /// Posts the macOS system timezone to CAAL so the agent uses the correct local time.
    /// Task #284: merge `LLMRoutingCAALKeys` values from `MacSettings` into this POST body
    /// once `/api/settings` accepts them (same pattern as timezone keys).
    private func syncTimezone() async {
        guard let url = URL(string: "\(settings.effectiveURL)/api/settings") else { return }
        let (tzId, tzDisplay) = ContainerManager.systemTimezone()
        guard let body = try? JSONSerialization.data(withJSONObject: [
            "settings": ["timezone_id": tzId, "timezone_display": tzDisplay]
        ]) else { return }
        var req = URLRequest(url: url, timeoutInterval: 5)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !settings.apiKey.isEmpty { req.setValue(settings.apiKey, forHTTPHeaderField: "x-api-key") }
        req.httpBody = body
        _ = try? await URLSession.shared.data(for: req)
        timezoneSynced = true
    }

    private func fetchProfile() async {
        guard let url = URL(string: "\(settings.effectiveURL)/api/assistant/profile") else { return }
        var req = URLRequest(url: url, timeoutInterval: 5)
        if !settings.apiKey.isEmpty { req.setValue(settings.apiKey, forHTTPHeaderField: "x-api-key") }
        do {
            let (data, _) = try await URLSession.shared.data(for: req)
            let p = try JSONDecoder().decode(AssistantProfile.self, from: data)
            if p != profile { profile = p }
            if let avatarPath = p.avatarUrl,
               let avatarURL = URL(string: "\(settings.effectiveURL)\(avatarPath)") {
                await fetchAvatar(from: avatarURL)
            }
        } catch {}
    }

    private func fetchAvatar(from url: URL) async {
        var req = URLRequest(url: url, timeoutInterval: 5)
        if !settings.apiKey.isEmpty { req.setValue(settings.apiKey, forHTTPHeaderField: "x-api-key") }
        do {
            let (data, _) = try await URLSession.shared.data(for: req)
            if let img = NSImage(data: data) { avatarImage = img }
        } catch {}
    }

    /// One-shot startup guardrail: if CAAL is still offline shortly after boot,
    /// retry the currently selected runtime path once.
    private func attemptBootSelfHealIfNeeded() async {
        guard !bootSelfHealAttempted else { return }
        bootSelfHealAttempted = true
        try? await Task.sleep(for: .seconds(8))
        await checkHealth()
        guard !isOnline else { return }
        switch settings.deploymentMode {
        case .embedded:
            await sidecarManager.start()
        case .networked:
            await containerManager.setup(caelDirectory: settings.caelDirectory)
        }
        try? await Task.sleep(for: .seconds(3))
        await checkHealth()
    }
}

final class ContractEndpointService: ObservableObject {
    @Published private(set) var baseURLString: String?

    private var listener: NWListener?
    private let queue = DispatchQueue(label: "com.seayniclabs.sonique.contract-endpoint")
    private let token: String
    private let tokenHeaderName = "x-sonique-contract-token"

    init() {
        self.token = Self.loadOrCreateToken()
    }

    func start() {
        guard listener == nil else { return }
        guard let port = NWEndpoint.Port(rawValue: 8894) else { return }
        do {
            let listener = try NWListener(using: .tcp, on: port)
            self.listener = listener
            self.baseURLString = "http://127.0.0.1:\(port.rawValue)"
            listener.newConnectionHandler = { [weak self] connection in
                self?.handle(connection: connection)
            }
            listener.stateUpdateHandler = { [weak self] state in
                if case .failed = state {
                    Task { @MainActor in
                        self?.baseURLString = nil
                        self?.listener = nil
                    }
                }
            }
            listener.start(queue: queue)
        } catch {
            baseURLString = nil
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
        baseURLString = nil
    }

    var runtimeContractPullURL: String? {
        guard let baseURLString else { return nil }
        return "\(baseURLString)/contracts/runtime?token=\(token)"
    }

    var preflightTrendPullURL: String? {
        guard let baseURLString else { return nil }
        return "\(baseURLString)/contracts/preflight/trend?token=\(token)"
    }

    private func handle(connection: NWConnection) {
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] data, _, _, _ in
            guard let self else {
                connection.cancel()
                return
            }
            guard let data, !data.isEmpty else {
                connection.cancel()
                return
            }
            let requestText = String(decoding: data, as: UTF8.self)
            self.respond(to: requestText, connection: connection)
        }
    }

    private func respond(to request: String, connection: NWConnection) {
        let lines = request.components(separatedBy: "\r\n")
        guard let first = lines.first else {
            send(status: 400, body: #"{"error":"bad request"}"#, connection: connection)
            return
        }
        let parts = first.split(separator: " ")
        guard parts.count >= 2 else {
            send(status: 400, body: #"{"error":"bad request"}"#, connection: connection)
            return
        }

        let method = String(parts[0])
        let rawTarget = String(parts[1])
        guard method == "GET" else {
            send(status: 405, body: #"{"error":"method not allowed"}"#, connection: connection)
            return
        }

        guard let targetURL = URL(string: "http://localhost\(rawTarget)"),
              isAuthorized(targetURL: targetURL, lines: lines) else {
            send(status: 401, body: #"{"error":"unauthorized"}"#, connection: connection)
            return
        }

        let path = targetURL.path
        if path == "/contracts/runtime" {
            respondWithFile(named: "runtime-contract.latest.json", connection: connection)
            return
        }
        if path == "/contracts/preflight/latest" {
            respondWithFile(named: "preflight-telemetry.latest.json", connection: connection)
            return
        }
        if path == "/contracts/preflight/history" {
            let limit = max(1, min(200, Int(targetURL.queryItem(named: "limit") ?? "") ?? 50))
            respondWithHistory(limit: limit, connection: connection)
            return
        }
        if path == "/contracts/preflight/trend" {
            respondWithTrend(connection: connection)
            return
        }

        send(status: 404, body: #"{"error":"not found"}"#, connection: connection)
    }

    private func isAuthorized(targetURL: URL, lines: [String]) -> Bool {
        if targetURL.queryItem(named: "token") == token {
            return true
        }
        let expected = "\(tokenHeaderName): \(token)"
        return lines.contains(where: { $0.lowercased() == expected.lowercased() })
    }

    private func respondWithFile(named fileName: String, connection: NWConnection) {
        let fileURL = Self.contractsDirURL.appendingPathComponent(fileName)
        guard let data = try? Data(contentsOf: fileURL) else {
            send(status: 404, body: #"{"error":"not published"}"#, connection: connection)
            return
        }
        send(status: 200, bodyData: data, contentType: "application/json", connection: connection)
    }

    private func respondWithHistory(limit: Int, connection: NWConnection) {
        let historyURL = Self.contractsDirURL.appendingPathComponent("preflight-telemetry.history.jsonl")
        guard let content = try? String(contentsOf: historyURL, encoding: .utf8) else {
            send(status: 404, body: #"{"error":"history unavailable"}"#, connection: connection)
            return
        }
        let lines = content
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map(String.init)
        let selected = Array(lines.suffix(limit))
        let arrayBody = "[\(selected.joined(separator: ","))]"
        send(status: 200, body: arrayBody, connection: connection)
    }

    private func respondWithTrend(connection: NWConnection) {
        let latestURL = Self.contractsDirURL.appendingPathComponent("preflight-telemetry.latest.json")
        let historyURL = Self.contractsDirURL.appendingPathComponent("preflight-telemetry.history.jsonl")
        let latest = (try? Data(contentsOf: latestURL)).flatMap { try? JSONSerialization.jsonObject(with: $0) }
        let historyCount: Int
        if let content = try? String(contentsOf: historyURL, encoding: .utf8) {
            historyCount = content.split(separator: "\n", omittingEmptySubsequences: true).count
        } else {
            historyCount = 0
        }
        let payload: [String: Any] = [
            "historyCount": historyCount,
            "latest": latest ?? NSNull()
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys]) else {
            send(status: 500, body: #"{"error":"serialize failed"}"#, connection: connection)
            return
        }
        send(status: 200, bodyData: data, contentType: "application/json", connection: connection)
    }

    private func send(status: Int, body: String, connection: NWConnection) {
        send(status: status, bodyData: Data(body.utf8), contentType: "application/json", connection: connection)
    }

    private func send(status: Int, bodyData: Data, contentType: String, connection: NWConnection) {
        let statusText: String
        switch status {
        case 200: statusText = "OK"
        case 400: statusText = "Bad Request"
        case 401: statusText = "Unauthorized"
        case 404: statusText = "Not Found"
        case 405: statusText = "Method Not Allowed"
        default: statusText = "Error"
        }
        var head = "HTTP/1.1 \(status) \(statusText)\r\n"
        head += "Content-Type: \(contentType)\r\n"
        head += "Content-Length: \(bodyData.count)\r\n"
        head += "Connection: close\r\n\r\n"
        let packet = Data(head.utf8) + bodyData
        connection.send(content: packet, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    private static var contractsDirURL: URL {
        let root = ("~/Library/Application Support/SoniqueBar/contracts" as NSString).expandingTildeInPath
        return URL(fileURLWithPath: root, isDirectory: true)
    }

    private static func loadOrCreateToken() -> String {
        let fm = FileManager.default
        let dir = contractsDirURL
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let tokenURL = dir.appendingPathComponent("contract-endpoint.token")
        if let existing = try? String(contentsOf: tokenURL, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !existing.isEmpty {
            return existing
        }
        let value = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        try? value.write(to: tokenURL, atomically: true, encoding: .utf8)
        try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: tokenURL.path)
        return value
    }
}

private extension URL {
    func queryItem(named name: String) -> String? {
        URLComponents(url: self, resolvingAgainstBaseURL: false)?
            .queryItems?
            .first(where: { $0.name == name })?
            .value
    }
}
