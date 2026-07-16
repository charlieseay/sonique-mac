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

    private init() {
        // Load auth token from secrets
        let tokenPath = "/Volumes/data/secrets/sonique_auth_token"
        if let token = try? String(contentsOfFile: tokenPath, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines), !token.isEmpty {
            self.authToken = token
        } else {
            // Generate and save a new token if none exists
            let newToken = UUID().uuidString
            try? newToken.write(toFile: tokenPath, atomically: true, encoding: .utf8)
            self.authToken = newToken
        }
        setupListener()
    }
    
    deinit {
        listener?.cancel()
    }
    
    // MARK: - Server Setup
    
    private func setupListener() {
        do {
            listener = try NWListener(using: .tcp, on: port)
            
            listener?.newConnectionHandler = { [weak self] connection in
                self?.handleConnection(connection)
            }
            
            listener?.stateUpdateHandler = { [weak self] state in
                Task { @MainActor in
                    switch state {
                    case .ready:
                        self?.isRunning = true
                        self?.logger.info("[CommandServer] Started on port \(self?.port.rawValue ?? 0)")
                    case .failed(let error):
                        self?.logger.error("[CommandServer] Failed: \(error.localizedDescription)")
                        self?.isRunning = false
                    case .cancelled:
                        self?.isRunning = false
                        self?.logger.info("[CommandServer] Stopped")
                    default:
                        break
                    }
                }
            }
            
            listener?.start(queue: .main)
            
        } catch {
            logger.error("[CommandServer] Failed to create listener: \(error.localizedDescription)")
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
    

    /// TTS synthesis endpoint - uses macOS 'say' command to generate audio
    private func handleSynthesize(_ data: Data, _ connection: NWConnection) async {
        guard let requestString = String(data: data, encoding: .utf8),
              let range = requestString.range(of: "\r\n\r\n"),
              let bodyData = String(requestString[range.upperBound...]).data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: bodyData) as? [String: Any],
              let text = json["text"] as? String else {
            sendResponse("HTTP/1.1 400 Bad Request\r\n\r\n{\"error\":\"Missing 'text' field\"}", to: connection)
            return
        }

        logger.info("[CommandServer] TTS request: \(text.prefix(80))")

        // Use macOS 'say' command to generate AIFF audio
        let tempFile = "/tmp/sonique-tts-\(UUID().uuidString).aiff"

        // Fix temp file leak: always clean up with defer
        defer {
            try? FileManager.default.removeItem(atPath: tempFile)
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        process.arguments = ["-o", tempFile, text]

        do {
            try process.run()
            process.waitUntilExit()

            if process.terminationStatus == 0, let audioData = try? Data(contentsOf: URL(fileURLWithPath: tempFile)) {
                // Send AIFF audio file
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

                logger.info("[CommandServer] TTS generated \(audioData.count) bytes")
            } else {
                sendResponse("HTTP/1.1 500 Internal Server Error\r\n\r\n{\"error\":\"TTS generation failed\"}", to: connection)
            }
        } catch {
            logger.error("[CommandServer] TTS error: \(error.localizedDescription)")
            sendResponse("HTTP/1.1 500 Internal Server Error\r\n\r\n{\"error\":\"TTS error\"}", to: connection)
        }
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
}
