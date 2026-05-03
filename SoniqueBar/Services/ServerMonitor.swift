import Foundation
import AppKit
import Network
import AVFoundation

@MainActor
class ServerMonitor: ObservableObject {
    @Published var isOnline = false
    @Published var profile: AssistantProfile?
    @Published var avatarImage: NSImage?
    @Published var hasActiveVoiceSession = false
    /// Best-effort Helmsman DB snapshot for the status popover (nil = not fetched yet).
    @Published private(set) var labPendingTaskCount: Int?
    @Published private(set) var labHelmsmanReachable = false
    @Published private(set) var labDockerContainerCount: Int?

    let settings = MacSettings()
    let sidecarManager = SidecarManager()
    let premium = PremiumManager()
    let systemControl = SystemControlManager()
    let chatManager = ChatManager()
    let voiceManager = VoiceManager()
    let memoryJanitor = MemoryJanitorService()
    let contractEndpoint = ContractEndpointService()

    private var pollTask: Task<Void, Never>?
    private var bootSelfHealAttempted = false
    private var readyChimeWatchdogTask: Task<Void, Never>?
    private var didPlayReadyChime = false
    private let readyChimePlayer = ReadyChimePlayer()

    init() {
        contractEndpoint.start()
        memoryJanitor.start()
        Task { [weak self] in
            guard let self else { return }
            // Let MenuBarExtra render once before embedded runtime unpack/probes.
            await Task.yield()
            await sidecarManager.start()
            if case .failed = sidecarManager.state {
                // Keep polling active so Doctor can drive remediation without Docker fallback.
                NSLog("[Sidecar] embedded runtime failed at boot")
            }
            startPolling()
            startReadyChimeWatchdog()
            await playReadyChimeWhenBackendIsReady(timeout: 45)
            await attemptBootSelfHealIfNeeded()
        }
    }

    deinit {
        readyChimeWatchdogTask?.cancel()
        memoryJanitor.stop()
        contractEndpoint.stop()
    }

    func loadMemoryHealthSnapshot() -> MemoryHealthSnapshot {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("SoniqueBar/memory", isDirectory: true)
        let turnsURL = dir.appendingPathComponent("conversation-turns.json")
        let episodesURL = dir.appendingPathComponent("conversation-episodes.json")
        let personaURL = dir.appendingPathComponent("persona-profile.json")
        let statusURL = dir.appendingPathComponent("memory-health.json")

        let turnsCount = (try? Data(contentsOf: turnsURL))
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [Any] }?
            .count ?? 0
        let episodesCount = (try? Data(contentsOf: episodesURL))
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [Any] }?
            .count ?? 0

        let personaSummary = (try? Data(contentsOf: personaURL))
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }?["summary"] as? String
            ?? "No persona summary yet."

        let status = (try? Data(contentsOf: statusURL))
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
        let mode = status["mode"] as? String ?? "unknown"
        let lastRunAt = status["lastRunAt"] as? String
        let lastCompactAt = status["lastCompactAt"] as? String

        return MemoryHealthSnapshot(
            rawTurnCount: turnsCount,
            episodeCount: episodesCount,
            personaSummary: personaSummary,
            janitorMode: mode,
            lastRunAtISO8601: lastRunAt,
            lastCompactAtISO8601: lastCompactAt
        )
    }

    func startPolling() {
        pollTask?.cancel()
        chatManager.configure(backendURL: settings.backendURL, apiKey: settings.apiKey)
        voiceManager.configure(backendURL: settings.backendURL, apiKey: settings.apiKey)
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
        await refreshLabSnapshot()
    }

    private var timezoneSynced = false

    private func refreshLabSnapshot() async {
        let base = settings.helmsmanURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: base + "/tasks?status=pending&limit=200") else {
            labHelmsmanReachable = false
            return
        }
        var req = URLRequest(url: url, timeoutInterval: 4)
        req.httpMethod = "GET"
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            labHelmsmanReachable = (200..<300).contains(code)
            if labHelmsmanReachable, let arr = try? JSONSerialization.jsonObject(with: data) as? [Any] {
                labPendingTaskCount = arr.count
            } else {
                labPendingTaskCount = nil
            }
        } catch {
            labHelmsmanReachable = false
            labPendingTaskCount = nil
        }

        let dockerCount: Int? = await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .utility).async {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
                p.arguments = ["docker", "ps", "-q"]
                let pipe = Pipe()
                p.standardOutput = pipe
                p.standardError = FileHandle.nullDevice
                do {
                    try p.run()
                    p.waitUntilExit()
                    let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                    let n = out.split(whereSeparator: \.isNewline).filter { !$0.isEmpty }.count
                    cont.resume(returning: p.terminationStatus == 0 ? n : nil)
                } catch {
                    cont.resume(returning: nil)
                }
            }
        }
        labDockerContainerCount = dockerCount
    }

    private func checkHealth() async {
        guard let url = URL(string: "\(settings.backendURL)/health") else {
            isOnline = false; return
        }
        var req = URLRequest(url: url, timeoutInterval: 5)
        if !settings.apiKey.isEmpty { req.setValue(settings.apiKey, forHTTPHeaderField: "x-api-key") }
        do {
            let (_, response) = try await URLSession.shared.data(for: req)
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            let wasOffline = !isOnline
            isOnline = code == 200
            if isOnline && (wasOffline || !timezoneSynced) {
                await syncTimezone()
            }
            maybePlayReadyChime()
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
        guard let url = URL(string: "\(settings.backendURL)/settings") else { return }
        let tz = TimeZone.current
        let tzId = tz.identifier
        let tzDisplay = (tz.localizedName(for: .standard, locale: .current) ?? "Local Time")
            .replacingOccurrences(of: " Standard Time", with: " Time")
            .replacingOccurrences(of: " Daylight Time", with: " Time")
            .replacingOccurrences(of: " Daylight Saving Time", with: " Time")
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
        guard let url = URL(string: "\(settings.backendURL)/assistant/profile") else { return }
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
        await sidecarManager.start()
        try? await Task.sleep(for: .seconds(3))
        await checkHealth()
        maybePlayReadyChime()
    }

    private func startReadyChimeWatchdog() {
        readyChimeWatchdogTask?.cancel()
        readyChimeWatchdogTask = Task { [weak self] in
            guard let self else { return }
            let deadline = Date().addingTimeInterval(180)
            while !Task.isCancelled && Date() < deadline && !didPlayReadyChime {
                await evaluateReadyChimeTrigger()
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    private func playReadyChimeWhenBackendIsReady(timeout: TimeInterval) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline && !didPlayReadyChime {
            if await isBackendReadyForChime() {
                maybePlayReadyChime()
                return
            }
            try? await Task.sleep(for: .seconds(1))
        }
    }

    private func isBackendReadyForChime() async -> Bool {
        if isOnline { return true }
        guard let localURL = URL(string: "http://127.0.0.1:8891/health") else { return false }
        var req = URLRequest(url: localURL, timeoutInterval: 1.5)
        req.httpMethod = "GET"
        do {
            let (_, response) = try await URLSession.shared.data(for: req)
            if let http = response as? HTTPURLResponse {
                return (200..<300).contains(http.statusCode)
            }
            return false
        } catch {
            return false
        }
    }

    private func evaluateReadyChimeTrigger() async {
        if isOnline {
            maybePlayReadyChime()
            return
        }
        guard let localURL = URL(string: "http://127.0.0.1:8891/health") else { return }
        var req = URLRequest(url: localURL, timeoutInterval: 1.5)
        req.httpMethod = "GET"
        do {
            let (_, response) = try await URLSession.shared.data(for: req)
            if let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) {
                if !didPlayReadyChime {
                    let marker = chimeMarkerURL()
                    let stamp = ISO8601DateFormatter().string(from: Date())
                    try? stamp.write(to: marker, atomically: true, encoding: .utf8)
                    NSLog("[Sonique] ready chime triggered from local health at \(stamp)")
                    readyChimePlayer.playFaintThreeNote()
                    didPlayReadyChime = true
                }
            }
        } catch {
            return
        }
    }

    private func maybePlayReadyChime() {
        guard !didPlayReadyChime else { return }
        let marker = chimeMarkerURL()
        let stamp = ISO8601DateFormatter().string(from: Date())
        try? stamp.write(to: marker, atomically: true, encoding: .utf8)
        NSLog("[Sonique] ready chime triggered at \(stamp)")
        readyChimePlayer.playFaintThreeNote()
        didPlayReadyChime = true
    }

    private func chimeMarkerURL() -> URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support", isDirectory: true)
        let dir = appSupport.appendingPathComponent("SoniqueBar", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("ready-chime.last")
    }
}

@MainActor
private final class ReadyChimePlayer: NSObject, AVAudioPlayerDelegate {
    private var player: AVAudioPlayer?

    func playFaintThreeNote() {
        guard let wav = Self.makeThreeNoteWav() else { return }
        do {
            let p = try AVAudioPlayer(data: wav, fileTypeHint: AVFileType.wav.rawValue)
            p.delegate = self
            p.volume = 0.7
            p.prepareToPlay()
            if !p.play() {
                NSSound.beep()
            }
            player = p
        } catch {
            NSLog("[Sonique] ready chime playback failed: \(error.localizedDescription)")
            NSSound.beep()
        }
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in
            self.player = nil
        }
    }

    private static func makeThreeNoteWav() -> Data? {
        let sampleRate = 44_100
        let channels: UInt16 = 1
        let bitsPerSample: UInt16 = 16

        let noteDuration = 0.17
        let gapDuration = 0.055
        let attack = 0.014
        let release = 0.036
        let frequencies: [Double] = [523.25, 659.25, 783.99]

        var samples: [Int16] = []
        samples.reserveCapacity(Int(Double(sampleRate) * (noteDuration * Double(frequencies.count) + gapDuration * 2)))

        func appendSilence(_ duration: Double) {
            let count = max(0, Int(Double(sampleRate) * duration))
            samples.append(contentsOf: repeatElement(0, count: count))
        }

        func appendNote(_ freq: Double, duration: Double) {
            let count = max(1, Int(Double(sampleRate) * duration))
            let attackCount = Int(Double(sampleRate) * attack)
            let releaseCount = Int(Double(sampleRate) * release)
            let amplitude = 0.5

            for i in 0..<count {
                let t = Double(i) / Double(sampleRate)
                var env = 1.0
                if i < attackCount {
                    env = Double(i) / Double(max(1, attackCount))
                } else if i > count - releaseCount {
                    env = Double(count - i) / Double(max(1, releaseCount))
                }
                let value = sin(2.0 * .pi * freq * t) * env * amplitude
                let pcm = Int16(max(-1.0, min(1.0, value)) * Double(Int16.max))
                samples.append(pcm)
            }
        }

        for index in frequencies.indices {
            appendNote(frequencies[index], duration: noteDuration)
            if index < frequencies.count - 1 {
                appendSilence(gapDuration)
            }
        }

        let dataSize = UInt32(samples.count * MemoryLayout<Int16>.size)
        let byteRate = UInt32(sampleRate) * UInt32(channels) * UInt32(bitsPerSample) / 8
        let blockAlign = channels * (bitsPerSample / 8)
        let riffChunkSize = 36 + dataSize

        var data = Data(capacity: Int(44 + dataSize))
        data.append("RIFF".data(using: .ascii)!)
        data.appendLE(riffChunkSize)
        data.append("WAVE".data(using: .ascii)!)
        data.append("fmt ".data(using: .ascii)!)
        data.appendLE(UInt32(16))
        data.appendLE(UInt16(1))
        data.appendLE(channels)
        data.appendLE(UInt32(sampleRate))
        data.appendLE(byteRate)
        data.appendLE(blockAlign)
        data.appendLE(bitsPerSample)
        data.append("data".data(using: .ascii)!)
        data.appendLE(dataSize)

        for sample in samples {
            data.appendLE(UInt16(bitPattern: sample))
        }
        return data
    }
}

private extension Data {
    mutating func appendLE<T: FixedWidthInteger>(_ value: T) {
        var little = value.littleEndian
        Swift.withUnsafeBytes(of: &little) { bytes in
            append(bytes.bindMemory(to: UInt8.self))
        }
    }
}

struct MemoryHealthSnapshot {
    let rawTurnCount: Int
    let episodeCount: Int
    let personaSummary: String
    let janitorMode: String
    let lastRunAtISO8601: String?
    let lastCompactAtISO8601: String?

    static let empty = MemoryHealthSnapshot(
        rawTurnCount: 0,
        episodeCount: 0,
        personaSummary: "No persona summary yet.",
        janitorMode: "unknown",
        lastRunAtISO8601: nil,
        lastCompactAtISO8601: nil
    )
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
