import Foundation
import Network

/// Simple HTTP server for receiving commands from iOS.
/// Handles text-based commands and routes them to infrastructure or LLM.
@MainActor
class CommandServer: ObservableObject {
    static let shared = CommandServer()

    @Published var isRunning = false
    @Published var lastCommand: String = ""
    @Published var requestCount: Int = 0

    private var listener: NWListener?
    private let port: NWEndpoint.Port = 8890

    private init() {
        setupListener()
    }

    deinit {
        // Can't call @MainActor methods from deinit
        listener?.cancel()
    }

    func start() {
        guard !isRunning else { return }

        listener?.start(queue: .main)
        print("[CommandServer] Started on port \(port)")
    }

    func stop() {
        guard isRunning else { return }

        listener?.cancel()
        isRunning = false
        print("[CommandServer] Stopped")
    }

    private func setupListener() {
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true

        do {
            listener = try NWListener(using: parameters, on: port)

            listener?.newConnectionHandler = { [weak self] connection in
                Task { @MainActor in
                    await self?.handleConnection(connection)
                }
            }

            listener?.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready:
                    Task { @MainActor in
                        self?.isRunning = true
                        print("[CommandServer] Listener ready - set isRunning=true")
                    }
                case .failed(let error):
                    print("[CommandServer] Listener failed: \(error)")
                    Task { @MainActor in
                        self?.isRunning = false
                    }
                default:
                    break
                }
            }
        } catch {
            print("[CommandServer] Failed to create listener: \(error)")
        }
    }

    private func handleConnection(_ connection: NWConnection) {
        connection.start(queue: .main)

        // Read the HTTP request
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self = self else { return }

            if let data = data, !data.isEmpty {
                Task { @MainActor in
                    await self.processRequest(data, connection: connection)
                }
            }

            if isComplete || error != nil {
                connection.cancel()
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

        print("[CommandServer] \(method) \(path)")

        // Route the request
        if method == "GET" && path == "/health" {
            await handleHealth(connection)
        } else if method == "GET" && path == "/config" {
            await handleConfig(connection)
        } else if method == "POST" && path == "/command" {
            await handleCommand(data, connection)
        } else {
            sendResponse("HTTP/1.1 404 Not Found\r\n\r\n", to: connection)
        }
    }

    private func handleHealth(_ connection: NWConnection) async {
        let response = """
        HTTP/1.1 200 OK\r
        Content-Type: application/json\r
        \r
        {"status":"ok","port":\(port)}
        """
        sendResponse(response, to: connection)
    }

    private func handleConfig(_ connection: NWConnection) async {
        // Read ElevenLabs API key from secrets file
        let secretPath = "/Volumes/data/secrets/elevenlabs_api_key"

        guard let apiKey = try? String(contentsOfFile: secretPath, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines) else {
            let errorResponse = """
            HTTP/1.1 500 Internal Server Error\r
            Content-Type: application/json\r
            \r
            {"error":"Could not read ElevenLabs API key from \(secretPath)"}
            """
            sendResponse(errorResponse, to: connection)
            return
        }

        let responseJSON = """
        {"elevenlabsAPIKey":"\(apiKey)"}
        """

        let response = """
        HTTP/1.1 200 OK\r
        Content-Type: application/json\r
        Content-Length: \(responseJSON.utf8.count)\r
        \r
        \(responseJSON)
        """

        sendResponse(response, to: connection)
    }

    private func handleCommand(_ data: Data, _ connection: NWConnection) async {
        // Extract JSON body from POST request
        guard let requestString = String(data: data, encoding: .utf8) else {
            sendResponse("HTTP/1.1 400 Bad Request\r\n\r\n", to: connection)
            return
        }

        // Find the JSON body (after the headers)
        let components = requestString.components(separatedBy: "\r\n\r\n")
        guard components.count >= 2,
              let bodyData = components[1].data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: bodyData) as? [String: Any],
              let text = json["text"] as? String else {
            sendResponse("HTTP/1.1 400 Bad Request\r\n\r\n{\"error\":\"Missing 'text' field\"}", to: connection)
            return
        }

        await MainActor.run {
            self.lastCommand = text
            self.requestCount += 1
        }

        print("[CommandServer] Received command: \(text)")

        // TODO: Route to IntentRouter
        // For now, just echo back
        let responseText = await executeCommand(text)

        let responseJSON = """
        {"response":"\(responseText)","timestamp":"\(ISO8601DateFormatter().string(from: Date()))"}
        """

        let response = """
        HTTP/1.1 200 OK\r
        Content-Type: application/json\r
        Content-Length: \(responseJSON.utf8.count)\r
        \r
        \(responseJSON)
        """

        sendResponse(response, to: connection)
    }

    private func executeCommand(_ text: String) async -> String {
        // Classify the intent
        let intent = IntentRouter.classify(text)

        switch intent {
        case .conversation(let query):
            return await handleConversation(query)

        case .infrastructure(let command):
            return await InfrastructureExecutor.execute(command: command)

        case .unknown(let input):
            return "I'm not sure what to do with: \(input)"
        }
    }

    private func handleConversation(_ text: String) async -> String {
        // Check if ask_helmsman is available
        let which = await InfrastructureExecutor.shell("which ask_helmsman")
        guard which.exitCode == 0 else {
            // Fallback: simple time check
            if text.lowercased().contains("time") {
                let formatter = DateFormatter()
                formatter.dateStyle = .none
                formatter.timeStyle = .short
                return "The current time is \(formatter.string(from: Date()))"
            }
            return "LLM not available. Check that ask_helmsman is in PATH."
        }

        // Route to ask_helmsman for conversational responses
        let result = await InfrastructureExecutor.shell("ask_helmsman '\(text.replacingOccurrences(of: "'", with: "'\\''"))'")

        if result.exitCode == 0 && !result.stdout.isEmpty {
            return result.stdout
        } else {
            return "Sorry, I couldn't process that request: \(result.stderr)"
        }
    }

    private func sendResponse(_ response: String, to connection: NWConnection) {
        guard let data = response.data(using: .utf8) else { return }

        connection.send(content: data, completion: .contentProcessed { error in
            if let error = error {
                print("[CommandServer] Send error: \(error)")
            }
            connection.cancel()
        })
    }
}
