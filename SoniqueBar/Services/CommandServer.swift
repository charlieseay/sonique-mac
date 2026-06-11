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

            // Do NOT cancel on isComplete — the client finishing its upload (isComplete=true)
            // does not mean we're done. A long agentic call may still be running and will
            // write the response + cancel the connection itself (sendResponse). Cancelling
            // here resets the socket mid-request → client sees badResponse in ~40ms.
            if error != nil {
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
        } else if method == "POST" && path == "/command/stream" {
            await handleCommandStream(data, connection)
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

        var responseText: String
        var intentType: String
        var actions: [String] = []

        switch intent {
        case .conversation(let query):
            intentType = "conversation"
            responseText = await handleConversation(query)

        case .infrastructure(let command):
            intentType = "infrastructure"
            responseText = await InfrastructureExecutor.execute(command: command)
            actions.append("executed: \(command)")

        case .unknown(let input):
            intentType = "unknown"
            responseText = "I'm not sure what to do with: \(input)"
        }

        // Log to memory
        await MemoryService.shared.addExchange(
            user: text,
            assistant: responseText,
            intent: intentType,
            actions: actions.isEmpty ? nil : actions
        )

        return responseText
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

        // Get context from memory
        let context = await MemoryService.shared.getContextForLLM()

        // Build prompt with context
        let fullPrompt = """
        \(context)

        # Current Request
        \(text)

        Respond directly and concisely. Use the context above to inform your response but don't reference it explicitly.
        """

        // Escape for shell
        let escapedPrompt = fullPrompt.replacingOccurrences(of: "'", with: "'\\''")

        // Route to ask_helmsman with context
        let result = await InfrastructureExecutor.shell("ask_helmsman '\(escapedPrompt)'")

        if result.exitCode == 0 && !result.stdout.isEmpty {
            return result.stdout
        } else {
            return "Sorry, I couldn't process that request: \(result.stderr)"
        }
    }

    private func handleCommandStream(_ data: Data, _ connection: NWConnection) async {
        guard let requestString = String(data: data, encoding: .utf8) else {
            sendResponse("HTTP/1.1 400 Bad Request\r\n\r\n", to: connection)
            return
        }

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

        print("[CommandServer] Streaming command: \(text)")

        // Native-first: handle common local facts/actions instantly (time, date, open
        // app, volume) with macOS native tools — no LLM, deterministic and free.
        if let native = await NativeIntents.handle(text) {
            let body = buildNDJSONBody(segmentIntoSentences(native))
            sendNDJSONResponse(body, to: connection)
            await MemoryService.shared.addExchange(user: text, assistant: native, intent: "native", actions: nil)
            return
        }

        // Infrastructure routing (non-conversational commands don't need streaming)
        let intent = IntentRouter.classify(text)
        if case .conversation = intent {} else {
            let responseText = await executeCommand(text)
            let body = buildNDJSONBody(segmentIntoSentences(responseText))
            sendNDJSONResponse(body, to: connection)
            await MemoryService.shared.addExchange(user: text, assistant: responseText, intent: "infrastructure", actions: nil)
            return
        }

        // Conversational / agentic: claude --print WITH Bash tool access so it can ACT
        // (run date/cal/osascript/shortcuts) on novel requests, not just answer as text.
        // Subscription CLI, no API cost.
        // Persona + lessons + directives come from the iCloud-backed brain (shared persona
        // + this device's overlay); recent working memory from MemoryService.
        let persona = SoniqueBrain.shared.personaContext()
        let working = await MemoryService.shared.getContextForLLM()
        let userPrompt = """
        \(persona)

        \(working)

        # Current Request
        \(text)
        """
        let escapedPrompt = userPrompt.replacingOccurrences(of: "'", with: "'\\''")

        let system = """
        You are Sonique, a voice assistant running on Charlie's Mac with shell access. \
        USE the Bash tool to act on factual or action requests — date/cal for time math, \
        osascript for device control (volume, apps, system), shortcuts for automations, \
        system commands for status. Never say you "can't" do something the Mac can do; \
        run the command. Respond in 1–2 short spoken sentences, no markdown, no lists. \
        Do not infer the user's emotional state unless they say so; treat brief or stray \
        input as a literal question.
        """
        let escapedSystem = system.replacingOccurrences(of: "'", with: "'\\''")

        // Resolve the binary dynamically — /opt/homebrew/bin/claude (Homebrew cask).
        let claudePath = await resolveClaudePath()
        // stream-json + partial messages = token-level streaming, so we can speak the
        // first sentence as soon as it's formed instead of waiting for the full reply.
        let claudeCmd = "cd /tmp && '\(claudePath)' --print "
            + "--output-format stream-json --include-partial-messages --verbose "
            + "--allowedTools 'Bash' --permission-mode acceptEdits "
            + "--append-system-prompt '\(escapedSystem)' "
            + "'\(escapedPrompt)' 2>/dev/null"

        // Open a chunked HTTP response and emit each sentence as it completes.
        startChunkedResponse(to: connection)

        var sentenceBuf = ""
        var fullText = ""
        var index = 0
        let terminators = CharacterSet(charactersIn: ".!?…")

        let exit = await runStreaming(claudeCmd) { [weak self] line in
            guard let self, let token = self.extractTextDelta(line) else { return }
            sentenceBuf += token
            fullText += token
            // Flush complete sentences as they form.
            while let r = sentenceBuf.rangeOfCharacter(from: terminators) {
                let after = sentenceBuf.index(after: r.lowerBound)
                // sentence boundary = terminator followed by space/end
                if after == sentenceBuf.endIndex || sentenceBuf[after] == " " {
                    let sentence = String(sentenceBuf[...r.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
                    sentenceBuf = String(sentenceBuf[after...]).trimmingCharacters(in: .init(charactersIn: " "))
                    if !sentence.isEmpty {
                        Task { @MainActor in self.sendSentenceChunk(sentence, index: index, to: connection) }
                        index += 1
                    }
                } else { break }
            }
        }

        // Flush trailing partial sentence.
        let tail = sentenceBuf.trimmingCharacters(in: .whitespacesAndNewlines)
        if !tail.isEmpty {
            sendSentenceChunk(tail, index: index, to: connection)
        }

        // If nothing was produced, speak a graceful message — never silence, never an error.
        if fullText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let message: String
            if exit == -2 {
                // Timed out (wedged tool call / permission prompt). Friendly, retryable.
                message = "Sorry, that took too long. Please try again."
            } else {
                // Try the fallback brain once; if it too is empty, a friendly retry message.
                let fb = await InfrastructureExecutor.shell("ask_helmsman '\(escapedPrompt)'")
                message = fb.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    ? "Sorry, I ran into an issue with that. Please try again."
                    : fb.stdout
            }
            for (i, s) in segmentIntoSentences(message).enumerated() {
                sendSentenceChunk(s, index: i, to: connection)
            }
            fullText = message
        }

        _ = exit
        endChunkedResponse(to: connection)
        let finalText = fullText.trimmingCharacters(in: .whitespacesAndNewlines)
        await MemoryService.shared.addExchange(user: text, assistant: finalText, intent: "conversation", actions: nil)
        // Grow the iCloud brain (Desktop folder) — backed up + synced natively.
        SoniqueBrain.shared.recordExchange(user: text, assistant: finalText)
    }

    /// Resolve the `claude` CLI path. Prefers `which`, falls back to known Homebrew location.
    private func resolveClaudePath() async -> String {
        let result = await InfrastructureExecutor.shell("which claude 2>/dev/null")
        let path = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        if !path.isEmpty && FileManager.default.fileExists(atPath: path) { return path }
        // Known Homebrew cask location.
        if FileManager.default.fileExists(atPath: "/opt/homebrew/bin/claude") {
            return "/opt/homebrew/bin/claude"
        }
        return "claude"  // last resort — rely on PATH
    }

    /// Run a shell command, calling `onLine` for each stdout line AS IT ARRIVES.
    /// Returns the process exit code. Used to stream claude's stream-json output.
    /// Max wall-clock for a single agentic call. If a tool call wedges (e.g. a macOS
    /// permission prompt the background app can't surface, or a runaway loop), kill it so
    /// SoniqueBar never freezes for minutes. A healthy reply finishes in 12–20s.
    private let agenticTimeout: TimeInterval = 60

    private func runStreaming(_ command: String, onLine: @escaping (String) -> Void) async -> Int32 {
        await withCheckedContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/zsh")
            process.arguments = ["-c", command]
            let outPipe = Pipe()
            process.standardOutput = outPipe
            process.standardError = Pipe()

            // Resume the continuation exactly once (termination OR timeout).
            let resumed = NSLock()
            var didResume = false
            func finish(_ code: Int32) {
                resumed.lock(); defer { resumed.unlock() }
                guard !didResume else { return }
                didResume = true
                continuation.resume(returning: code)
            }

            let handle = outPipe.fileHandleForReading
            var buffer = Data()
            handle.readabilityHandler = { fh in
                let data = fh.availableData
                if data.isEmpty { return }
                buffer.append(data)
                while let nl = buffer.firstIndex(of: 0x0A) {
                    let lineData = buffer.subdata(in: buffer.startIndex..<nl)
                    buffer.removeSubrange(buffer.startIndex...nl)
                    if let line = String(data: lineData, encoding: .utf8), !line.isEmpty {
                        onLine(line)
                    }
                }
            }

            process.terminationHandler = { proc in
                handle.readabilityHandler = nil
                if !buffer.isEmpty, let line = String(data: buffer, encoding: .utf8), !line.isEmpty {
                    onLine(line)
                }
                finish(proc.terminationStatus)
            }

            // Watchdog: kill the process tree if it runs past the timeout.
            DispatchQueue.global().asyncAfter(deadline: .now() + agenticTimeout) {
                if process.isRunning {
                    print("[CommandServer] agentic call exceeded \(self.agenticTimeout)s — terminating")
                    process.terminate()
                    DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
                        if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                    }
                    finish(-2)   // -2 = timed out
                }
            }

            do { try process.run() }
            catch { finish(-1) }
        }
    }

    /// Extract the assistant text token from a claude stream-json line, if present.
    private func extractTextDelta(_ jsonLine: String) -> String? {
        guard let data = jsonLine.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              obj["type"] as? String == "stream_event",
              let event = obj["event"] as? [String: Any],
              event["type"] as? String == "content_block_delta",
              let delta = event["delta"] as? [String: Any],
              delta["type"] as? String == "text_delta",
              let text = delta["text"] as? String else { return nil }
        return text
    }

    /// Run a shell command and return its full stdout.
    /// Tries primaryCmd first; falls back to fallbackCmd on non-zero exit or empty output.
    private func streamShellCommand(_ primaryCmd: String, fallback: String) async -> String {
        let result = await InfrastructureExecutor.shell(primaryCmd)
        if result.exitCode == 0 && !result.stdout.isEmpty {
            return result.stdout
        }
        let fallbackResult = await InfrastructureExecutor.shell(fallback)
        return fallbackResult.exitCode == 0 && !fallbackResult.stdout.isEmpty
            ? fallbackResult.stdout
            : "Sorry, I couldn't process that request."
    }

    private func segmentIntoSentences(_ text: String) -> [String] {
        var chunks: [String] = []
        var current = ""
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)

        for word in clean.components(separatedBy: " ") {
            if word.isEmpty { continue }
            current += (current.isEmpty ? "" : " ") + word
            if let last = word.last, ".!?…".contains(last) {
                chunks.append(current)
                current = ""
            }
        }
        if !current.trimmingCharacters(in: .whitespaces).isEmpty {
            chunks.append(current)
        }
        return chunks.isEmpty ? [clean] : chunks
    }

    private func buildNDJSONBody(_ chunks: [String]) -> String {
        var body = ""
        for (i, chunk) in chunks.enumerated() {
            if let data = try? JSONSerialization.data(withJSONObject: [
                "chunk": chunk, "index": i, "is_final": (i == chunks.count - 1)
            ]), let line = String(data: data, encoding: .utf8) {
                body += line + "\n"
            }
        }
        body += "{\"done\":true}\n"
        return body
    }

    private func sendNDJSONResponse(_ body: String, to connection: NWConnection) {
        guard let bodyData = body.data(using: .utf8) else { return }
        let response = "HTTP/1.1 200 OK\r\nContent-Type: application/x-ndjson\r\nContent-Length: \(bodyData.count)\r\nCache-Control: no-cache\r\nConnection: close\r\n\r\n" + body
        sendResponse(response, to: connection)
    }

    // MARK: - Chunked (incremental) NDJSON streaming

    /// Send the HTTP/1.1 chunked-transfer response headers. After this, call
    /// `sendChunk` per NDJSON line and `endChunkedResponse` when done.
    private func startChunkedResponse(to connection: NWConnection) {
        let headers = "HTTP/1.1 200 OK\r\n"
            + "Content-Type: application/x-ndjson\r\n"
            + "Cache-Control: no-cache\r\n"
            + "Transfer-Encoding: chunked\r\n"
            + "Connection: close\r\n\r\n"
        if let data = headers.data(using: .utf8) {
            connection.send(content: data, completion: .contentProcessed { _ in })
        }
    }

    /// Send one NDJSON line as a single HTTP chunk (hex-length CRLF body CRLF).
    private func sendChunk(_ line: String, to connection: NWConnection) {
        let payload = line + "\n"
        guard let payloadData = payload.data(using: .utf8) else { return }
        let chunk = String(format: "%X\r\n", payloadData.count)
        var out = Data()
        out.append(chunk.data(using: .utf8)!)
        out.append(payloadData)
        out.append("\r\n".data(using: .utf8)!)
        connection.send(content: out, completion: .contentProcessed { _ in })
    }

    /// Emit one sentence chunk as NDJSON over the open chunked response.
    private func sendSentenceChunk(_ sentence: String, index: Int, to connection: NWConnection) {
        if let data = try? JSONSerialization.data(withJSONObject: ["chunk": sentence, "index": index, "is_final": false]),
           let line = String(data: data, encoding: .utf8) {
            sendChunk(line, to: connection)
        }
    }

    /// Close the chunked response: send the {"done":true} line + terminal 0-chunk.
    private func endChunkedResponse(to connection: NWConnection) {
        sendChunk("{\"done\":true}", to: connection)
        let terminator = "0\r\n\r\n"
        if let data = terminator.data(using: .utf8) {
            connection.send(content: data, completion: .contentProcessed { _ in
                connection.cancel()
            })
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
