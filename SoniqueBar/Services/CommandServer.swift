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
    private var healthCheckTimer: Timer?

    private init() {
        setupListener()
        startHealthCheck()
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
                        // Auto-restart after 5 seconds
                        DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
                            print("[CommandServer] Attempting auto-restart after failure...")
                            self?.setupListener()
                            self?.start()
                        }
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
        } else if method == "GET" && path == "/capabilities" {
            await handleCapabilities(connection)
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

    private func handleCapabilities(_ connection: NWConnection) async {
        // Return capabilities - simplified for now
        let capabilities: [String: Any] = [
            "native_capabilities": [
                "time_and_calendar",
                "system_control",
                "web_search",
                "vision_analysis"
            ],
            "mcp_servers": [],
            "status": "discovery_not_yet_implemented"
        ]

        guard let responseData = try? JSONSerialization.data(withJSONObject: capabilities),
              let responseJSON = String(data: responseData, encoding: .utf8) else {
            sendResponse("HTTP/1.1 500 Internal Server Error\r\n\r\n", to: connection)
            return
        }

        let response = """
        HTTP/1.1 200 OK\r
        Content-Type: application/json\r
        Content-Length: \(responseJSON.utf8.count)\r
        \r
        \(responseJSON)
        """

        sendResponse(response, to: connection)
    }

    private func discoverMCPServers() async -> [[String: Any]]? {
        var servers: [[String: Any]] = []

        // Check if Home Assistant is available
        if await checkHomeAssistant() {
            servers.append([
                "name": "Home Assistant",
                "endpoint": "http://homeassistant.local:8123",
                "capabilities": [
                    "Control lights and switches",
                    "Query device states",
                    "Trigger automations"
                ]
            ])
        }

        // Check MCP proxy (if available)
        // This would query the Claude CLI or MCP gateway for available servers
        // For now, just return what we found

        return servers.isEmpty ? nil : servers
    }

    private func checkHomeAssistant() async -> Bool {
        guard let url = URL(string: "http://homeassistant.local:8123/api/") else { return false }

        var request = URLRequest(url: url)
        request.timeoutInterval = 2.0

        // Try to load HA token
        if let tokenData = try? Data(contentsOf: URL(fileURLWithPath: "/Volumes/data/secrets/ha_token")),
           let token = String(data: tokenData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) {
            request.addValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            return (response as? HTTPURLResponse)?.statusCode == 200
        } catch {
            return false
        }
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

        // Extract device battery info if present
        var deviceBattery: (percent: Int, isCharging: Bool)? = nil
        if let deviceInfo = json["device"] as? [String: Any],
           let batteryPercent = deviceInfo["battery_percent"] as? Int,
           let isCharging = deviceInfo["is_charging"] as? Bool {
            deviceBattery = (batteryPercent, isCharging)
        }

        // Extract identity (name, wake_word, skills) if present
        var identity: [String: Any]? = nil
        if let identityInfo = json["identity"] as? [String: Any] {
            identity = identityInfo
            print("[CommandServer] Identity received: name=\(identityInfo["name"] ?? "unknown"), wake_word=\(identityInfo["wake_word"] ?? "unknown")")
        }

        await MainActor.run {
            self.lastCommand = text
            self.requestCount += 1
        }

        print("[CommandServer] Streaming command: \(text)")

        // Native-first: handle common local facts/actions instantly (time, date, open
        // app, volume) with macOS native tools — no LLM, deterministic and free.
        if let native = await NativeIntents.handle(text, deviceBattery: deviceBattery) {
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

        // Build skills section from identity payload
        var skillsSection = ""
        if let identity = identity,
           let skills = identity["skills"] as? [[String: Any]] {
            skillsSection = "\n\n# Your Capabilities\n\n"
            for categoryGroup in skills {
                if let category = categoryGroup["category"] as? String,
                   let skillList = categoryGroup["skills"] as? [String] {
                    skillsSection += "## \(category)\n"
                    for skill in skillList {
                        skillsSection += "- \(skill)\n"
                    }
                    skillsSection += "\n"
                }
            }
        }

        let systemInstructions = """
        You are Sonique, a voice assistant. Your persistent identity, rules, and capabilities \
        are in your brain (provided above in the persona context). Follow them.

        Key reminders:
        - USE the Bash tool to act — never say you "can't" do what the Mac can do
        - Respond in 1–2 short spoken sentences (you're being heard, not read)
        - Check your CAPABILITIES.md before claiming you can't do something
        - Verify memory/resources exist before claiming they don't
        - NEVER narrate internal metadata (recent_user_turns, persona signals, traits, etc.)
        - NEVER mention your context, memory structure, or thinking process
        - Just answer the question naturally

        When Charlie wants to SEE something (screenshot, "show me"), save the PNG to \
        /tmp/sonique-artifacts/ — it auto-displays on his iPad. See CAPABILITIES.md for details.\(skillsSection)
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

            // Stream Claude CLI output in real-time (token-by-token via stream-json)
            let success = await streamClaudeResponse(
                claudePath: claudePath,
                userPromptFile: userPromptFile,
                systemPromptFile: systemPromptFile,
                connection: connection,
                startIndex: 1  // index 0 was the "…" indicator
            )

            // Cleanup temp files
            try? FileManager.default.removeItem(atPath: userPromptFile)
            try? FileManager.default.removeItem(atPath: systemPromptFile)

            if !success {
                // Error already handled in streamClaudeResponse
                responseText = ""  // Mark as handled
            }
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

    /// Stream Claude CLI output in real-time. Reads --output-format stream-json line-by-line
    /// and sends NDJSON chunks to the client as tokens arrive. Returns true on success.
    private func streamClaudeResponse(
        claudePath: String,
        userPromptFile: String,
        systemPromptFile: String,
        connection: NWConnection,
        startIndex: Int
    ) async -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [
            "-c",
            "cd /tmp && timeout 45 '\(claudePath)' --print --verbose --model haiku --allowedTools 'Bash' --permission-mode acceptEdits --output-format stream-json --append-system-prompt \"$(cat '\(systemPromptFile)')\" \"$(cat '\(userPromptFile)')\" 2>&1"
        ]

        let outputPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = Pipe()

        do {
            try process.run()
        } catch {
            print("[CommandServer] Failed to start Claude CLI: \(error)")
            sendSentenceChunk("Sorry, I ran into an issue.", index: startIndex, to: connection)
            return false
        }

        // Read output line-by-line and parse stream-json events
        var chunkIndex = startIndex
        var accumulatedText = ""
        var sentenceBuffer = ""

        let handle = outputPipe.fileHandleForReading

        // Read in background to avoid blocking
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            Task.detached {
                var lineBuffer = ""

                while true {
                    // Check if process is still running
                    if !process.isRunning {
                        break
                    }

                    // Read available data
                    let data = handle.availableData
                    guard !data.isEmpty else {
                        // No data available, process might have finished
                        try? await Task.sleep(nanoseconds: 10_000_000) // 10ms
                        continue
                    }

                    guard let chunk = String(data: data, encoding: .utf8) else { continue }
                    lineBuffer += chunk

                    // Process complete lines
                    while let newlineRange = lineBuffer.range(of: "\n") {
                        let line = String(lineBuffer[..<newlineRange.lowerBound])
                        lineBuffer = String(lineBuffer[newlineRange.upperBound...])

                        // Parse JSON event (verbose format from Claude CLI)
                        guard let jsonData = line.data(using: .utf8),
                              let event = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] else {
                            continue
                        }

                        // Extract text from assistant messages
                        if event["type"] as? String == "assistant",
                           let message = event["message"] as? [String: Any],
                           let content = message["content"] as? [[String: Any]] {

                            for block in content {
                                // Skip thinking blocks
                                if block["type"] as? String == "thinking" {
                                    continue
                                }

                                // Extract text content
                                if block["type"] as? String == "text",
                                   let text = block["text"] as? String {

                                    await MainActor.run {
                                        accumulatedText += text
                                        sentenceBuffer += text

                                        // Check for sentence boundaries and send complete sentences
                                        let (sentences, remainder) = self.extractCompleteSentences(from: sentenceBuffer)
                                        sentenceBuffer = remainder

                                        for sentence in sentences {
                                            self.sendSentenceChunk(sentence, index: chunkIndex, to: connection)
                                            chunkIndex += 1
                                        }
                                    }
                                }
                            }
                        }
                    }
                }

                // Process any remaining data
                if !lineBuffer.isEmpty {
                    if let jsonData = lineBuffer.data(using: .utf8),
                       let event = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
                       event["type"] as? String == "content_block_delta",
                       let delta = event["delta"] as? [String: Any],
                       delta["type"] as? String == "text_delta",
                       let text = delta["text"] as? String {

                        await MainActor.run {
                            accumulatedText += text
                            sentenceBuffer += text
                        }
                    }
                }

                // Wait for process to complete
                process.waitUntilExit()

                // Send any remaining partial sentence
                await MainActor.run {
                    let remaining = sentenceBuffer.trimmingCharacters(in: .whitespaces)
                    if !remaining.isEmpty {
                        self.sendSentenceChunk(remaining, index: chunkIndex, to: connection)
                    }
                }

                continuation.resume()
            }
        }

        process.waitUntilExit()
        let exitCode = process.terminationStatus

        if exitCode != 0 {
            print("[CommandServer] Claude CLI failed with exit code \(exitCode)")
            if accumulatedText.isEmpty {
                let msg = exitCode == 124 ? "Sorry, that took too long." : "Sorry, I ran into an issue."
                await MainActor.run {
                    sendSentenceChunk(msg, index: chunkIndex, to: connection)
                }
            }
            return false
        }

        return true
    }

    private func extractCompleteSentences(from text: String) -> ([String], String) {
        var sentences: [String] = []
        var remainder = text
        let terminators = CharacterSet(charactersIn: ".!?…")

        while let range = remainder.rangeOfCharacter(from: terminators) {
            let after = remainder.index(after: range.lowerBound)
            if after == remainder.endIndex || remainder[after] == " " || remainder[after] == "\n" {
                let sentence = String(remainder[...range.lowerBound]).trimmingCharacters(in: .whitespaces)
                if !sentence.isEmpty { sentences.append(sentence) }
                remainder = after < remainder.endIndex
                    ? String(remainder[after...]).trimmingCharacters(in: .init(charactersIn: " \n"))
                    : ""
            } else { break }
        }

        return (sentences, remainder)
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

    // MARK: - Health Check & Auto-Recovery

    private func startHealthCheck() {
        // Check every 30 seconds if the server is still responsive
        healthCheckTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self = self else { return }

                // If we think we're running but listener is dead, restart
                if self.isRunning {
                    let state = self.listener?.state
                    if case .failed = state {
                        print("[CommandServer] Health check detected failed listener - restarting")
                        self.setupListener()
                        self.start()
                    }
                } else {
                    // If we're not running, try to start
                    print("[CommandServer] Health check detected stopped server - starting")
                    self.setupListener()
                    self.start()
                }
            }
        }
    }
}
