import Foundation
import Network
import os.log

/// Minimal HTTP server that routes voice commands to Claude Code CLI
/// Replaces 2,432 lines of pattern matching with simple bridge to Claude Code
@MainActor
class CommandServer: ObservableObject {
    static let shared = CommandServer()

    private let logger = Logger(subsystem: "com.seayniclabs.soniquebar", category: "CommandServer")

    @Published var isRunning = false
    @Published var lastCommand: String = ""
    @Published var requestCount: Int = 0

    private var listener: NWListener?
    private let port: NWEndpoint.Port = 8890
    private let claudeBridge = ClaudeCodeBridge()
    private let authToken: String
    private var bonjourService: NetService?

    private init() {
        NSLog("[CommandServer] init() starting")

        // Load auth token from secrets
        let tokenPath = "/Volumes/data/secrets/sonique_auth_token"
        if let token = try? String(contentsOfFile: tokenPath, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines), !token.isEmpty {
            self.authToken = token
            NSLog("[CommandServer] Loaded existing auth token")
        } else {
            // Generate and save a new token if none exists
            let newToken = UUID().uuidString
            try? newToken.write(toFile: tokenPath, atomically: true, encoding: .utf8)
            self.authToken = newToken
            NSLog("[CommandServer] Generated new auth token")
        }

        // Sync auth token to iCloud preferences so iOS can use it
        Task { @MainActor in
            var prefs = SoniqueBrain.shared.loadPreferences()
            prefs.authToken = self.authToken
            SoniqueBrain.shared.savePreferences(prefs)
            NSLog("[CommandServer] Synced auth token to iCloud preferences")
        }

        NSLog("[CommandServer] Calling setupListener()")
        setupListener()
        NSLog("[CommandServer] init() complete")
    }
    
    deinit {
        listener?.cancel()
        bonjourService?.stop()
    }
    
    // MARK: - Server Setup
    
    private func setupListener() {
        logger.info("[CommandServer] setupListener() called")

        do {
            logger.info("[CommandServer] Creating NWListener on port \(self.port.rawValue)")
            listener = try NWListener(using: .tcp, on: port)

            logger.info("[CommandServer] Listener created, setting handlers")

            listener?.newConnectionHandler = { [weak self] connection in
                self?.logger.info("[CommandServer] New connection received")
                self?.handleConnection(connection)
            }

            listener?.stateUpdateHandler = { [weak self] state in
                Task { @MainActor in
                    switch state {
                    case .ready:
                        self?.isRunning = true
                        self?.logger.info("[CommandServer] ✓ Listener READY on port \(self?.port.rawValue ?? 0)")
                        NSLog("[CommandServer] ✓ Listener READY and bound to port \(self?.port.rawValue ?? 0)")
                        // Start Bonjour advertising once listener is ready
                        self?.startBonjourAdvertising()
                    case .failed(let error):
                        self?.logger.error("[CommandServer] ❌ Listener FAILED: \(error.localizedDescription)")
                        NSLog("[CommandServer] ❌ Listener FAILED: \(error.localizedDescription)")
                        self?.isRunning = false
                        self?.bonjourService?.stop()
                    case .cancelled:
                        self?.isRunning = false
                        self?.logger.info("[CommandServer] Listener cancelled")
                        self?.bonjourService?.stop()
                    case .waiting(let error):
                        self?.logger.warning("[CommandServer] Listener waiting: \(error.localizedDescription)")
                        NSLog("[CommandServer] ⚠️ Listener WAITING: \(error.localizedDescription)")
                    case .setup:
                        self?.logger.info("[CommandServer] Listener in setup state")
                    @unknown default:
                        self?.logger.warning("[CommandServer] Listener unknown state")
                    }
                }
            }

            logger.info("[CommandServer] Starting listener on main queue")
            listener?.start(queue: .main)
            logger.info("[CommandServer] Listener.start() called")

        } catch {
            logger.error("[CommandServer] ❌ Failed to create listener: \(error.localizedDescription)")
            NSLog("[CommandServer] ❌ Failed to create listener: \(error.localizedDescription)")
        }
    }
    
    // MARK: - Connection Handling

    nonisolated private func handleConnection(_ connection: NWConnection) {
        connection.start(queue: .main)

        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self = self else { return }

            // Fix connection leak: handle errors properly
            if let error = error {
                print("[CommandServer] Receive error: \(error.localizedDescription)")
                connection.cancel()
                return
            }

            if let data = data, !data.isEmpty {
                Task { @MainActor in
                    await self.processRequest(data, connection: connection)
                }
            }

            if isComplete {
                connection.cancel()
            } else {
                // Continue receiving
                self.handleConnection(connection)
            }
        }
    }
    
    private func processRequest(_ data: Data, connection: NWConnection) async {
        guard let requestString = String(data: data, encoding: .utf8) else {
            sendResponse("HTTP/1.1 400 Bad Request\r\n\r\n", to: connection)
            return
        }

        // Parse HTTP request
        let lines = requestString.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else {
            sendResponse("HTTP/1.1 400 Bad Request\r\n\r\n", to: connection)
            return
        }

        let parts = requestLine.components(separatedBy: " ")
        guard parts.count >= 2 else {
            sendResponse("HTTP/1.1 400 Bad Request\r\n\r\n", to: connection)
            return
        }

        let method = parts[0]
        let path = parts[1]

        logger.info("[CommandServer] \(method) \(path)")

        // Check bearer token for all non-health endpoints
        if path != "/health" {
            let authorized = lines.contains { line in
                line.lowercased().hasPrefix("authorization: bearer ") &&
                line.dropFirst("authorization: bearer ".count).trimmingCharacters(in: .whitespaces) == authToken
            }

            if !authorized {
                logger.warning("[CommandServer] Unauthorized request to \(path)")
                sendResponse("HTTP/1.1 401 Unauthorized\r\n\r\n{\"error\":\"Unauthorized\"}", to: connection)
                return
            }
        }

        // Route requests (removed /config endpoint - security fix)
        if path == "/health" {
            await handleHealth(connection)
        } else if path == "/command/stream" && method == "POST" {
            await handleCommandStream(data, connection)
        } else if path == "/command" && method == "POST" {
            await handleCommand(data, connection)
        } else if path == "/synthesize" && method == "POST" {
            await handleSynthesize(data, connection)
        } else {
            sendResponse("HTTP/1.1 404 Not Found\r\n\r\n{\"error\":\"Not found\"}", to: connection)
        }
    }
    
    // MARK: - Endpoints
    
    private func handleHealth(_ connection: NWConnection) async {
        let response = """
        {
            "status": "ok",
            "port": 8890,
            "version": "2.0",
            "build": "simplified",
            "mode": "claude-code-bridge"
        }
        """
        
        sendJSON(response, to: connection)
    }
    
    /// Streaming endpoint — emits NDJSON lines that iOS VoiceLoop consumes chunk-by-chunk.
    /// Format: {"chunk":"word "} … {"done":true}
    private func handleCommandStream(_ data: Data, _ connection: NWConnection) async {
        guard let text = extractCommandText(from: data) else {
            sendResponse("HTTP/1.1 400 Bad Request\r\n\r\n{\"error\":\"Missing 'text' field\"}", to: connection)
            return
        }

        logger.info("[CommandServer] Stream request: \(text.prefix(80))")
        lastCommand = text
        requestCount += 1

        // Send chunked HTTP header — keep connection open for NDJSON lines.
        let header = "HTTP/1.1 200 OK\r\nContent-Type: application/x-ndjson\r\nTransfer-Encoding: chunked\r\n\r\n"
        sendRaw(header, to: connection)

        do {
            let response = try await claudeBridge.execute(text: text)
            // Split response into word-sized chunks so iOS starts speaking immediately.
            let words = response.components(separatedBy: " ")
            for (i, word) in words.enumerated() {
                let isLast = i == words.index(before: words.endIndex)
                let piece = isLast ? word : word + " "
                if !piece.trimmingCharacters(in: .whitespaces).isEmpty {
                    await sendNDJSONChunk("{\"chunk\":\(escapeJSON(piece)),\"is_final\":false}", to: connection)
                }
            }
        } catch {
            logger.error("[CommandServer] Bridge error: \(error.localizedDescription)")
            let msg = "I encountered an error. Please try again."
            await sendNDJSONChunk("{\"chunk\":\(escapeJSON(msg)),\"is_final\":false}", to: connection)
        }

        await sendNDJSONChunk("{\"done\":true}", to: connection)
        // Send final chunk terminator (0\r\n\r\n)
        sendRaw("0\r\n\r\n", to: connection)
        connection.cancel()
    }

    /// Non-streaming fallback endpoint — returns single JSON response.
    private func handleCommand(_ data: Data, _ connection: NWConnection) async {
        guard let text = extractCommandText(from: data) else {
            sendResponse("HTTP/1.1 400 Bad Request\r\n\r\n{\"error\":\"Missing 'text' field\"}", to: connection)
            return
        }

        logger.info("[CommandServer] Command request: \(text.prefix(80))")
        lastCommand = text
        requestCount += 1

        do {
            let response = try await claudeBridge.execute(text: text)
            sendJSON("{\"response\":\(escapeJSON(response)),\"status\":\"ok\"}", to: connection)
        } catch {
            logger.error("[CommandServer] Bridge error: \(error.localizedDescription)")
            sendJSON("{\"response\":\"I encountered an error. Please try again.\",\"status\":\"error\"}", to: connection)
        }
    }
    

    /// TTS synthesis endpoint - Phase 6D: ElevenLabs or fallback to macOS 'say'
    private func handleSynthesize(_ data: Data, _ connection: NWConnection) async {
        guard let text = extractCommandText(from: data) else {
            sendResponse("HTTP/1.1 400 Bad Request\r\n\r\n{\"error\":\"Missing 'text' field\"}", to: connection)
            return
        }

        logger.info("[CommandServer] TTS request: \(text.prefix(80))")

        // Phase 6D: Try ElevenLabs first, fallback to macOS say
        if let audioData = try? await synthesizeWithElevenLabs(text: text) {
            let response = """
            HTTP/1.1 200 OK\r
            Content-Type: audio/mpeg\r
            Content-Length: \(audioData.count)\r
            \r

            """

            connection.send(content: response.data(using: .utf8)!, completion: .contentProcessed { _ in })
            connection.send(content: audioData, completion: .contentProcessed { _ in
                connection.cancel()
            })

            logger.info("[CommandServer] ElevenLabs TTS generated \(audioData.count) bytes")
            return
        }

        // Fallback to macOS 'say' command
        logger.info("[CommandServer] Falling back to macOS say")
        let tempFile = "/tmp/sonique-tts-\(UUID().uuidString).aiff"

        defer {
            try? FileManager.default.removeItem(atPath: tempFile)
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        process.arguments = ["-v", "Samantha", "-o", tempFile, text]

        do {
            try process.run()
            process.waitUntilExit()

            if process.terminationStatus == 0, let audioData = try? Data(contentsOf: URL(fileURLWithPath: tempFile)) {
                let response = """
                HTTP/1.1 200 OK\r
                Content-Type: audio/x-aiff\r
                Content-Length: \(audioData.count)\r
                \r

                """

                connection.send(content: response.data(using: .utf8)!, completion: .contentProcessed { _ in })
                connection.send(content: audioData, completion: .contentProcessed { _ in
                    connection.cancel()
                })

                logger.info("[CommandServer] macOS TTS generated \(audioData.count) bytes")
            } else {
                sendResponse("HTTP/1.1 500 Internal Server Error\r\n\r\n{\"error\":\"TTS generation failed\"}", to: connection)
            }
        } catch {
            logger.error("[CommandServer] TTS error: \(error.localizedDescription)")
            sendResponse("HTTP/1.1 500 Internal Server Error\r\n\r\n{\"error\":\"TTS error\"}", to: connection)
        }
    }

    // MARK: - Phase 6D: ElevenLabs TTS

    private func synthesizeWithElevenLabs(text: String) async throws -> Data {
        // Load API key from secrets
        let keyPath = "/Volumes/data/secrets/elevenlabs_api_key"
        guard let apiKey = try? String(contentsOfFile: keyPath, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines), !apiKey.isEmpty else {
            throw NSError(domain: "ElevenLabs", code: 1, userInfo: [NSLocalizedDescriptionKey: "API key not found"])
        }

        // Rachel voice ID (default)
        let voiceId = "21m00Tcm4TlvDq8ikWAM"

        let url = URL(string: "https://api.elevenlabs.io/v1/text-to-speech/\(voiceId)")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "xi-api-key")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: Any] = [
            "text": text,
            "model_id": "eleven_flash_v2_5",
            "voice_settings": [
                "stability": 0.5,
                "similarity_boost": 0.75
            ]
        ]

        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            throw NSError(domain: "ElevenLabs", code: 2, userInfo: [NSLocalizedDescriptionKey: "Request failed"])
        }

        return data
    }

    // MARK: - Helpers

    private func extractCommandText(from data: Data) -> String? {
        guard let requestString = String(data: data, encoding: .utf8),
              let range = requestString.range(of: "\r\n\r\n"),
              let bodyData = String(requestString[range.upperBound...]).data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: bodyData) as? [String: Any],
              let text = json["text"] as? String else { return nil }
        return text
    }

    nonisolated private func sendNDJSONChunk(_ line: String, to connection: NWConnection) async {
        let dataLine = line + "\n"
        let data = dataLine.data(using: .utf8)!
        // HTTP chunked encoding: size in hex + CRLF + data + CRLF
        let sizeHex = String(format: "%X", data.count)
        let chunk = "\(sizeHex)\r\n\(dataLine)\r\n"

        // Use async/await to wait for send completion
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            connection.send(content: chunk.data(using: .utf8)!, completion: .contentProcessed { error in
                if let error = error {
                    print("[CommandServer] Chunk send error: \(error)")
                }
                continuation.resume()
            })
        }
    }

    private func sendRaw(_ string: String, to connection: NWConnection) {
        connection.send(content: string.data(using: .utf8)!, completion: .contentProcessed { _ in })
    }
    
    private func escapeJSON(_ string: String) -> String {
        let escaped = string
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\t", with: "\\t")
        
        return "\"\(escaped)\""
    }
    
    private func sendJSON(_ json: String, to connection: NWConnection) {
        let response = """
        HTTP/1.1 200 OK\r
        Content-Type: application/json\r
        Content-Length: \(json.utf8.count)\r
        \r
        \(json)
        """
        
        sendResponse(response, to: connection)
    }
    
    private func sendResponse(_ response: String, to connection: NWConnection) {
        let data = response.data(using: .utf8)!

        connection.send(content: data, completion: .contentProcessed { error in
            if let error = error {
                print("[CommandServer] Send error: \(error)")
            }
            connection.cancel()
        })
    }

    // MARK: - Bonjour Advertising

    private func startBonjourAdvertising() {
        // Stop existing service if any
        bonjourService?.stop()

        // Create and publish Bonjour service
        bonjourService = NetService(domain: "local.", type: "_sonique._tcp.", name: "SoniqueBar", port: Int32(self.port.rawValue))
        bonjourService?.publish()

        logger.info("[CommandServer] ✓ Bonjour advertising started: _sonique._tcp.local on port \(self.port.rawValue)")
        NSLog("[CommandServer] ✓ Bonjour advertising: _sonique._tcp.local on port \(self.port.rawValue)")
    }
}
