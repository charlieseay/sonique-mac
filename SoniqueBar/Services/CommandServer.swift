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
    
    private init() {
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
            
            if let data = data, !data.isEmpty {
                Task { @MainActor in
                    await self.processRequest(data, connection: connection)
                }
            }
            
            if isComplete {
                connection.cancel()
            } else if error == nil {
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
        
        // Route requests
        if path == "/health" {
            await handleHealth(connection)
        } else if path == "/stream" && method == "POST" {
            await handleStream(data, connection)
        } else if path == "/config" {
            await handleConfig(connection)
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
    
    private func handleStream(_ data: Data, _ connection: NWConnection) async {
        // Extract JSON body
        guard let body = extractBody(from: data),
              let bodyData = body.data(using: .utf8),
              let json = try? JSONDecoder().decode([String: String].self, from: bodyData),
              let text = json["text"] else {
            sendResponse("HTTP/1.1 400 Bad Request\r\n\r\n{\"error\":\"Missing 'text' field\"}", to: connection)
            return
        }
        
        logger.info("[CommandServer] Voice command: \(text.prefix(80))")
        
        Task { @MainActor in
            self.lastCommand = text
            self.requestCount += 1
        }
        
        // Route to Claude Code via bridge
        do {
            let response = try await claudeBridge.execute(text: text)
            
            let json = """
            {
                "text": \(escapeJSON(response)),
                "status": "ok"
            }
            """
            
            sendJSON(json, to: connection)
            
        } catch {
            logger.error("[CommandServer] Bridge error: \(error.localizedDescription)")
            
            let errorJSON = """
            {
                "text": "I encountered an error: \(escapeJSON(error.localizedDescription))",
                "status": "error"
            }
            """
            
            sendJSON(errorJSON, to: connection)
        }
    }
    
    private func handleConfig(_ connection: NWConnection) async {
        // Return ElevenLabs API key for iOS
        let apiKeyPath = "/Volumes/data/secrets/elevenlabs_api_key"
        
        if let apiKey = try? String(contentsOfFile: apiKeyPath, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines) {
            let json = """
            {
                "elevenlabsAPIKey": "\(apiKey)"
            }
            """
            sendJSON(json, to: connection)
        } else {
            sendResponse("HTTP/1.1 500 Internal Server Error\r\n\r\n{\"error\":\"API key not found\"}", to: connection)
        }
    }
    
    // MARK: - Helpers
    
    private func extractBody(from data: Data) -> String? {
        guard let requestString = String(data: data, encoding: .utf8) else {
            return nil
        }
        
        // Find empty line that separates headers from body
        if let range = requestString.range(of: "\r\n\r\n") {
            return String(requestString[range.upperBound...])
        }
        
        return nil
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
