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
        // Use default TCP parameters - NWListener will bind to both IPv4 and IPv6
        // by creating separate listeners internally
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        parameters.acceptLocalOnly = false  // Allow remote connections

        // Explicitly set IPv4 options to ensure it binds to IPv4
        let ipOptions = parameters.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options
        ipOptions?.version = .v4

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
        } else if method == "GET" && path.hasPrefix("/artifact/") {
            await handleArtifact(path, connection)
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

    /// Serve an ephemeral artifact image: GET /artifact/<filename>.png
    private func handleArtifact(_ path: String, _ connection: NWConnection) async {
        // Sanitize: only a bare filename from the artifacts dir, no traversal.
        let name = (path as NSString).lastPathComponent
        guard !name.contains(".."), !name.isEmpty else {
            sendResponse("HTTP/1.1 400 Bad Request\r\n\r\n", to: connection); return
        }
        let filePath = "\(Self.artifactDir)/\(name)"
        guard let data = FileManager.default.contents(atPath: filePath) else {
            sendResponse("HTTP/1.1 404 Not Found\r\n\r\n", to: connection); return
        }
        let mime = name.lowercased().hasSuffix(".jpg") || name.lowercased().hasSuffix(".jpeg") ? "image/jpeg" : "image/png"
        let header = "HTTP/1.1 200 OK\r\nContent-Type: \(mime)\r\nContent-Length: \(data.count)\r\nCache-Control: no-cache\r\nConnection: close\r\n\r\n"
        var out = Data(header.utf8)
        out.append(data)
        connection.send(content: out, completion: .contentProcessed { _ in connection.cancel() })
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
        // Voice replies must be FAST. Prefer ask_llm (routes to healthy low-latency
        // providers — groq/cerebras, sub-second) over ask_helmsman (NVIDIA-first;
        // when NVIDIA inference stalls it drags every reply through a 20-30s
        // timeout+fallback chain, which makes the assistant feel hung/broken).
        let llmBin: String
        if await InfrastructureExecutor.shell("which ask_llm").exitCode == 0 {
            llmBin = "ask_llm --lane fast"
        } else if await InfrastructureExecutor.shell("which ask_helmsman").exitCode == 0 {
            llmBin = "ask_helmsman"
        } else {
            // Fallback: simple time check
            if text.lowercased().contains("time") {
                let formatter = DateFormatter()
                formatter.dateStyle = .none
                formatter.timeStyle = .short
                return "The current time is \(formatter.string(from: Date()))"
            }
            return "LLM not available. Check that ask_llm or ask_helmsman is in PATH."
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

        // Route to the chosen LLM with context, BOUND by a hard timeout so a
        // voice reply is fast or fails gracefully (`timeout` returns 124 on expiry).
        let result = await InfrastructureExecutor.shell(
            "timeout 12 \(llmBin) '\(escapedPrompt)'"
        )

        if result.exitCode == 0 && !result.stdout.isEmpty {
            return result.stdout
        } else if result.exitCode == 124 {
            return "Sorry, that took too long to answer. Please try again."
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

        // Conversational / agentic: Bedrock Haiku PRIMARY, Claude CLI Haiku FALLBACK
        // PRIMARY: ask_claude_bedrock --lane haiku (metered, $1/$5 per MTok, faster)
        // FALLBACK: claude CLI --model haiku (subscription, flat-rate safety net)
        // Persona + lessons + directives come from the iCloud-backed brain (shared persona
        // + this device's overlay); recent working memory from MemoryService.
        let persona = SoniqueBrain.shared.personaContext()
        let working = await MemoryService.shared.getContextForLLM()

        let systemInstructions = """
        You are Sonique, a voice assistant. Your persistent identity, rules, and capabilities \
        are in your brain (provided above in the persona context). Follow them.

        Key reminders:
        - USE the Bash tool to act — never say you "can't" do what the Mac can do
        - Respond in 1–2 short spoken sentences (you're being heard, not read)
        - Check your CAPABILITIES.md before claiming you can't do something
        - Verify memory/resources exist before claiming they don't

        When Charlie wants to SEE something (screenshot, "show me"), save the PNG to \
        /tmp/sonique-artifacts/ — it auto-displays on his iPad. See CAPABILITIES.md for details.
        """

        // Combine system + persona + working memory + request into one prompt for Bedrock
        let fullPrompt = """
        \(systemInstructions)

        \(persona)

        \(working)

        # Current Request
        \(text)
        """
        let escapedPrompt = fullPrompt.replacingOccurrences(of: "'", with: "'\\''")
        let escapedSystem = systemInstructions.replacingOccurrences(of: "'", with: "'\\''")

        // Note artifacts present before the call, so we can detect any NEW image the LLM creates.
        let artifactsBefore = Self.currentArtifacts()

        // VOICE PATH: Use Claude CLI with tool execution (subscription, but reliable + fast).
        // Bedrock via ask_claude_bedrock doesn't have tool execution - it just returns
        // XML like "<Bash>...</Bash>" which leaks into TTS as raw text. Claude CLI with
        // --allowedTools actually EXECUTES the tools and returns clean results.
        var responseText = ""
        let useClaudeCLI = true  // Force Claude CLI for voice (has tool execution)

        if useClaudeCLI {
            print("[CommandServer] Using Claude CLI Haiku with tool execution for voice")

            // Send immediate "thinking" indicator so user sees activity during LLM processing
            startChunkedResponse(to: connection)
            sendSentenceChunk("…", index: 0, to: connection)

            let claudePath = await resolveClaudePath()
            let userPrompt = """
            \(persona)

            \(working)

            # Current Request
            \(text)
            """

            // Use temp files to avoid shell escaping hell
            let userPromptFile = "/tmp/sonique-user-\(UUID().uuidString).txt"
            let systemPromptFile = "/tmp/sonique-sys-\(UUID().uuidString).txt"
            try? userPrompt.write(toFile: userPromptFile, atomically: true, encoding: .utf8)
            try? systemInstructions.write(toFile: systemPromptFile, atomically: true, encoding: .utf8)

            let claudeCmd = "timeout 45 bash -c 'cd /tmp && \"\(claudePath)\" --print --model haiku --allowedTools \"Bash\" --permission-mode acceptEdits --output-format stream-json --append-system-prompt \"$(cat \"\(systemPromptFile)\")\" \"$(cat \"\(userPromptFile)\")\" 2>/dev/null && rm \"\(userPromptFile)\" \"\(systemPromptFile)\"'"

            let claudeResult = await InfrastructureExecutor.shell(claudeCmd)
            responseText = claudeResult.stdout.trimmingCharacters(in: .whitespacesAndNewlines)

            // Cleanup temp files
            try? FileManager.default.removeItem(atPath: userPromptFile)
            try? FileManager.default.removeItem(atPath: systemPromptFile)

            // If both failed or timed out, graceful error
            if responseText.isEmpty {
                let msg = claudeResult.exitCode == 124 ? "Sorry, that took too long." : "Sorry, I ran into an issue with that."
                responseText = "\(msg) Please try again."
            }
        }

        // Stream the response sentence-by-sentence (chunked response already started above with "…")
        for (i, sentence) in segmentIntoSentences(responseText).enumerated() {
            sendSentenceChunk(sentence, index: i + 1, to: connection)
        }

        // Detect a NEW image artifact the LLM created during this call, and tell the app
        // to display it (ephemeral, Snapchat-style). Emit BEFORE closing the response.
        let artifactsAfter = Self.currentArtifacts()
        if let newest = artifactsAfter.subtracting(artifactsBefore)
            .sorted(by: { Self.modTime($0) > Self.modTime($1) }).first,
           let servedID = Self.publishArtifact(newest) {
            if let data = try? JSONSerialization.data(withJSONObject: [
                "artifact": ["type": "image", "id": servedID]
            ]), let line = String(data: data, encoding: .utf8) {
                sendChunk(line, to: connection)
            }
        }

        endChunkedResponse(to: connection)
        await MemoryService.shared.addExchange(user: text, assistant: responseText, intent: "conversation", actions: nil)
        // Grow the iCloud brain (Desktop folder) — backed up + synced natively.
        SoniqueBrain.shared.recordExchange(user: text, assistant: responseText)
    }

    // MARK: - Artifacts (ephemeral screenshots shown on the device)

    static let artifactDir = "/tmp/sonique-artifacts"

    /// Image artifacts the LLM may have created. We watch the dedicated artifacts dir AND
    /// /tmp for the LLM's habitual `sonique-screenshot-*.png` naming, so detection is robust
    /// regardless of which path it chose.
    static func currentArtifacts() -> Set<String> {
        let fm = FileManager.default
        var paths = Set<String>()
        func isImage(_ n: String) -> Bool {
            let l = n.lowercased(); return l.hasSuffix(".png") || l.hasSuffix(".jpg") || l.hasSuffix(".jpeg")
        }
        if let files = try? fm.contentsOfDirectory(atPath: artifactDir) {
            for f in files where isImage(f) { paths.insert("\(artifactDir)/\(f)") }
        }
        if let tmp = try? fm.contentsOfDirectory(atPath: "/tmp") {
            for f in tmp where isImage(f) && (f.contains("sonique") || f.contains("screenshot")) {
                paths.insert("/tmp/\(f)")
            }
        }
        return paths
    }

    static func modTime(_ path: String) -> TimeInterval {
        (try? FileManager.default.attributesOfItem(atPath: path)[.modificationDate] as? Date)??.timeIntervalSince1970 ?? 0
    }

    /// Copy a detected artifact into the served dir under a clean id; return that id (the
    /// filename the app fetches at /artifact/<id>). Nil on failure.
    static func publishArtifact(_ sourcePath: String) -> String? {
        let fm = FileManager.default
        try? fm.createDirectory(atPath: artifactDir, withIntermediateDirectories: true)
        let ext = (sourcePath as NSString).pathExtension.isEmpty ? "png" : (sourcePath as NSString).pathExtension
        let id = "art-\(Int(Date().timeIntervalSince1970)).\(ext)"
        let dest = "\(artifactDir)/\(id)"
        if sourcePath == dest { return id }
        try? fm.removeItem(atPath: dest)
        do { try fm.copyItem(atPath: sourcePath, toPath: dest); return id }
        catch { return nil }
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

    /// Strip JSON metadata that ask_claude_bedrock emits before the actual response text.
    /// Input: "{\n    \"contentType\": \"application/json\"\n}\nHello! How are you?"
    /// Output: "Hello! How are you?"
    private func stripJSONMetadata(from text: String) -> String {
        let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // If it starts with "{", assume JSON metadata block followed by actual text
        if cleaned.hasPrefix("{") {
            // Find the closing brace and take everything after it
            if let endBrace = cleaned.firstIndex(of: "}") {
                let afterBrace = cleaned.index(after: endBrace)
                if afterBrace < cleaned.endIndex {
                    return String(cleaned[afterBrace...]).trimmingCharacters(in: .whitespacesAndNewlines)
                }
            }
        }
        return cleaned
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
