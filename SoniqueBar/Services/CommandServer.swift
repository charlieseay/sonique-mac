import Foundation
import Network
import os.log

/// Simple HTTP server for receiving commands from iOS.
/// Handles text-based commands and routes them to infrastructure or LLM.
@MainActor
class CommandServer: ObservableObject {
    static let shared = CommandServer()

    private let logger = Logger(subsystem: "com.seayniclabs.soniquebar", category: "CommandServer")

    @Published var isRunning = false
    @Published var lastCommand: String = ""
    @Published var requestCount: Int = 0

    private var listener: NWListener?
    private let port: NWEndpoint.Port = 8890
    private var healthCheckTimer: Timer?

    // Cached golden rules from helmsman.db (refreshed every 15 minutes)
    private var cachedGoldenRules: String = ""
    private var rulesLastLoaded: Date?

    // Duplicate request prevention
    private var lastProcessedText: String = ""
    private var lastProcessedTime: Date?
    private let dedupeWindow: TimeInterval = 5.0  // Ignore duplicates within 5s

    private init() {
        setupListener()
        startHealthCheck()

        // Load rules at startup
        Task {
            print("[CommandServer] Loading golden rules from helmsman.db...")
            await loadGoldenRules()
        }
    }

    deinit {
        // Can't call @MainActor methods from deinit
        listener?.cancel()
    }

    // MARK: - Golden Rules Loading

    /// Load golden rules from helmsman.db and format for system prompt
    nonisolated private func loadGoldenRules() async {
        // Check cache freshness (refresh every 15 minutes)
        let shouldRefresh = await MainActor.run {
            if let lastLoaded = rulesLastLoaded {
                return Date().timeIntervalSince(lastLoaded) >= 900 // 15 minutes
            }
            return true // First load
        }

        guard shouldRefresh else { return }

        guard let url = URL(string: "http://localhost:5682/rules?tier=golden") else {
            NSLog("[CommandServer] Invalid rules registry URL")
            return
        }

        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            guard let rules = try? JSONDecoder().decode([GoldenRule].self, from: data) else {
                NSLog("[CommandServer] Failed to decode rules")
                return
            }

            // Format rules for system prompt
            var formatted = "\n\n## 🏛️ GOLDEN RULES (always apply)\n\n"
            for (index, rule) in rules.enumerated() {
                formatted += "\(index + 1). **\(rule.title)**: \(rule.rule)\n"
            }

            await MainActor.run {
                cachedGoldenRules = formatted
                rulesLastLoaded = Date()
                NSLog("[CommandServer] ✅ Loaded \(rules.count) golden rules from helmsman.db")
            }
        } catch {
            NSLog("[CommandServer] ❌ Failed to load golden rules: \(error)")
        }
    }

    /// Golden Rule model (matches helmsman.db schema)
    private struct GoldenRule: Codable {
        let id: Int
        let slug: String
        let title: String
        let rule: String
        let why: String
        let tier: String
        let scope: String
        let tags: String
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
        NSLog("[SoniqueBar] Request: \(method) \(path)")

        // Write to accessible file for debugging
        let debugLog = "[\(Date())] \(method) \(path)\n"
        if let handle = try? FileHandle(forWritingTo: URL(fileURLWithPath: "/Users/charlieseay/soniquebar-debug.log")) {
            handle.seekToEndOfFile()
            handle.write(debugLog.data(using: .utf8)!)
            try? handle.close()
        } else {
            try? debugLog.data(using: .utf8)?.write(to: URL(fileURLWithPath: "/Users/charlieseay/soniquebar-debug.log"))
        }

        // Also add to log entries for GET /logs to work
        await MainActor.run {
            Self.logEntries.append("[\(Date())] \(method) \(path)")
        }

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
        } else if method == "POST" && path == "/conversation" {
            await handleConversationEndpoint(data, connection)
        } else if method == "GET" && path.hasPrefix("/artifact/") {
            await handleArtifact(path, connection)
        } else if method == "POST" && path == "/log" {
            await handleLogFromDevice(data, connection)
        } else if method == "GET" && path == "/logs" {
            await handleGetLogs(connection)
        } else if method == "POST" && path == "/diagnose" {
            await handleDiagnose(data, connection)
        } else if method == "POST" && path == "/remediate" {
            await handleRemediate(data, connection)
        } else {
            sendResponse("HTTP/1.1 404 Not Found\r\n\r\n", to: connection)
        }
    }

    private func handleHealth(_ connection: NWConnection) async {
        let buildNumber = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "unknown"
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"

        let response = """
        HTTP/1.1 200 OK\r
        Content-Type: application/json\r
        \r
        {"status":"ok","port":\(port),"version":"\(version)","build":"\(buildNumber)","hasPatternClassifier":true}
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
        // Read ElevenLabs API key from secrets file (try multiple locations)
        let secretPaths = [
            NSHomeDirectory() + "/Library/Application Support/SoniqueBar/elevenlabs_api_key",
            "/Volumes/data/secrets/elevenlabs_api_key"
        ]

        var apiKey: String?
        for path in secretPaths {
            if let key = try? String(contentsOfFile: path, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines),
               !key.isEmpty {
                apiKey = key
                break
            }
        }

        guard let apiKey = apiKey else {
            let errorResponse = """
            HTTP/1.1 500 Internal Server Error\r
            Content-Type: application/json\r
            \r
            {"error":"Could not read ElevenLabs API key from any of: \(secretPaths.joined(separator: ", "))"}
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
        // Discover capabilities on-demand (could be cached if needed)
        var mcpServers: [[String: Any]] = []

        // Check Home Assistant
        if await checkHomeAssistant() {
            mcpServers.append([
                "name": "Home Assistant",
                "endpoint": "http://homeassistant.local:8123",
                "capabilities": [
                    "Control lights and switches",
                    "Query device states",
                    "Trigger automations and scenes"
                ]
            ])
        }

        // Query vault-mcp proxy for available tools (lazy-loading)
        if await MCPProxyClient.isAvailable() {
            let tools = await MCPProxyClient.queryAvailableTools()
            if !tools.isEmpty {
                mcpServers.append([
                    "name": "MCP Proxy",
                    "endpoint": "http://localhost:8108",
                    "tool_count": tools.count,
                    "capabilities": [
                        "Lazy-loaded MCP tools",
                        "On-demand tool discovery",
                        "Slack, vault, filesystem, web search"
                    ]
                ])
            }
        }

        // Fallback: Check for Claude CLI MCP servers (if vault-mcp unavailable)
        if mcpServers.isEmpty, let claudeMCPs = await checkClaudeMCPServers() {
            mcpServers.append(contentsOf: claudeMCPs)
        }

        let capabilities: [String: Any] = [
            "native_capabilities": [
                "time_and_calendar",
                "system_control",
                "web_search",
                "vision_analysis",
                "vault_file_access",
                "brief_templates"
            ],
            "mcp_servers": mcpServers,
            "discovered_at": ISO8601DateFormatter().string(from: Date())
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

    private func checkClaudeMCPServers() async -> [[String: Any]]? {
        // Check if Claude CLI is available and has MCP servers
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/opt/homebrew/bin/claude")
        process.arguments = ["mcp", "list"]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()

        do {
            try process.run()
            process.waitUntilExit()

            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            guard let output = String(data: data, encoding: .utf8), !output.isEmpty else {
                return nil
            }

            // Parse connected servers from output
            var servers: [[String: Any]] = []
            let lines = output.components(separatedBy: "\n")
                .filter { $0.contains("Connected") && !$0.contains("Failed") }

            for line in lines {
                // Format: "slack: npx -y @modelcontextprotocol/server-slack - ✓ Connected"
                let parts = line.components(separatedBy: ":")
                if parts.count >= 2,
                   let serverName = parts.first?.trimmingCharacters(in: .whitespaces),
                   !serverName.isEmpty && !serverName.contains("Checking") {
                    servers.append([
                        "name": serverName,
                        "endpoint": "claude://mcp/\(serverName)",
                        "capabilities": ["MCP tools via Claude CLI"]
                    ])
                }
            }

            return servers.isEmpty ? nil : servers

        } catch {
            // Claude CLI not available or error running command
            return nil
        }
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

    private func handleConversationEndpoint(_ data: Data, _ connection: NWConnection) async {
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

        // Use IntentRouter fast path then handleConversation
        let intent = IntentRouter.classify(text)
        let responseText: String

        switch intent {
        case .conversation(let query):
            responseText = await handleConversation(query)
        case .infrastructure(let command):
            responseText = await InfrastructureExecutor.execute(command: command)
        case .unknown(let input):
            responseText = "I'm not sure what to do with: \(input)"
        }

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
        // DUPLICATE CHECK: Ignore identical requests within 5s window
        if text == self.lastProcessedText,
           let lastTime = self.lastProcessedTime,
           Date().timeIntervalSince(lastTime) < self.dedupeWindow {
            logger.info("🚫 DUPLICATE REQUEST ignored: '\(text)' (within \(self.dedupeWindow)s window)")
            return ""  // Return empty - iOS will ignore and not speak
        }

        // Record this request
        self.lastProcessedText = text
        self.lastProcessedTime = Date()

        // FAST PATH: Handle simple queries without LLM
        if text == "current_time" {
            logger.info("⚡ FAST PATH: current_time")
            let formatter = DateFormatter()
            formatter.dateStyle = .medium
            formatter.timeStyle = .short
            let response = "It's \(formatter.string(from: Date()))"
            logger.info("⚡ Fast response: '\(response)'")
            return response
        }

        logger.info("🤖 Routing all requests to ask_claude")

        // Get context from memory
        let context = await MemoryService.shared.getContextForLLM()

        let fullPrompt = """
        You are Quinn, Charlie's voice assistant. You're speaking directly to him out loud.

        # CRITICAL VOICE-FIRST RULES (mandatory, no exceptions)
        1. NEVER mention file paths, task numbers, URLs, or line numbers
        2. NEVER say technical scaffolding like "Let me check helmsman", "I'll POST to", "Running curl"
        3. NEVER enumerate steps or provide status updates like "Done. All six tasks are..."
        4. DO the work silently in the background, then report ONLY the outcome
        5. Keep responses to 1-2 sentences maximum
        6. Speak like a person, not a CLI tool

        # Examples of CORRECT responses
        User: "Dispatch tasks to make you better"
        BAD: "Done. All six capability tasks are now in Helmsman's queue."
        GOOD: "Got it. I've queued those improvements for the team."

        User: "What's on my screen?"
        BAD: "Let me take a screenshot using screencapture..."
        GOOD: "You've got Bridge open on the left and code on the right."

        User: "Create a note about this"
        BAD: "I've created a file at /Users/charlieseay/Documents/note.md"
        GOOD: "Done, it's saved."

        # Charlie's Context
        \(context)

        # Current Voice Request
        \(text)

        # Your Response (1-2 sentences, spoken aloud, zero technical details)
        """

        // Use ask_claude with Haiku preference (Bedrock Haiku → subscription Haiku fallback)
        let result = await InfrastructureExecutor.shell("ask_claude '\(fullPrompt.replacingOccurrences(of: "'", with: "'\\''"))' --prefer haiku")

        guard result.exitCode == 0 else {
            logger.error("ask_claude failed: \(result.stderr)")
            return "I encountered an error. \(result.stderr)"
        }

        return result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func handleConversationFallback(_ text: String, context: String) async -> String {
        // Legacy fallback: ask_llm or ask_helmsman via shell
        let llmBin: String
        if await InfrastructureExecutor.shell("which ask_llm").exitCode == 0 {
            llmBin = "ask_llm --lane fast"
        } else if await InfrastructureExecutor.shell("which ask_helmsman").exitCode == 0 {
            llmBin = "ask_helmsman"
        } else {
            return "LLM not available."
        }

        let fullPrompt = """
        \(context)

        # Current Request
        \(text)

        Respond directly and concisely.
        """

        let escapedPrompt = fullPrompt.replacingOccurrences(of: "'", with: "'\\''")
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
        await MainActor.run {
            Self.logEntries.append("[CommandServer] handleCommandStream called")
        }

        guard let requestString = String(data: data, encoding: .utf8) else {
            sendResponse("HTTP/1.1 400 Bad Request\r\n\r\n", to: connection)
            return
        }

        let components = requestString.components(separatedBy: "\r\n\r\n")
        guard components.count >= 2,
              let bodyData = components[1].data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: bodyData) as? [String: Any],
              let text = json["text"] as? String else {
            await MainActor.run {
                Self.logEntries.append("[CommandServer] Missing text field")
            }
            sendResponse("HTTP/1.1 400 Bad Request\r\n\r\n{\"error\":\"Missing 'text' field\"}", to: connection)
            return
        }

        await MainActor.run {
            Self.logEntries.append("[CommandServer] Processing command: \(text.prefix(50))")
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

        // Extract assistant name from identity, default to "Sonique"
        let assistantName = (identity?["name"] as? String) ?? "Sonique"

        // Refresh golden rules if stale (async, non-blocking)
        if rulesLastLoaded == nil || Date().timeIntervalSince(rulesLastLoaded!) >= 900 {
            Task { await loadGoldenRules() }
        }

        let systemInstructions = """
        You are \(assistantName), a voice assistant. Your persistent identity, rules, and capabilities \
        are in your brain (provided above in the persona context). Follow them.
        \(cachedGoldenRules)
        Key reminders:
        - USE the Bash tool to act — never say you "can't" do what the Mac can do
        - Respond in 1–2 short spoken sentences (you're being heard, not read)
        - Check your CAPABILITIES.md before claiming you can't do something
        - Verify memory/resources exist before claiming they don't
        - Calendar/Reminders use native EventKit API (NOT AppleScript) — fast and reliable
        - NEVER narrate internal metadata (recent_user_turns, persona signals, traits, etc.)
        - NEVER mention your context, memory structure, or thinking process
        - Just answer the question naturally
        - YOU ALREADY HAVE full write access to your memory layer (iCloud brain) — never ask permission

        Your memory lives in your iCloud brain and you can write to it freely via Bash tools. \
        Record lessons, update directives, and grow your knowledge without asking permission first.

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

            await MainActor.run {
                Self.logEntries.append("[CommandServer] About to call streamClaudeResponse")
            }

            // Stream Claude CLI output in real-time (token-by-token via stream-json)
            let (success, streamedResponse) = await streamClaudeResponse(
                claudePath: claudePath,
                userPrompt: userPrompt,
                systemPrompt: systemInstructions,
                connection: connection,
                startIndex: 1  // index 0 was the "…" indicator
            )

            // Capture the response for memory
            responseText = streamedResponse

            if !success && streamedResponse.isEmpty {
                // Error already handled in streamClaudeResponse
                responseText = "Error processing request"
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
    static let logFile = "/tmp/sonique-session.log"
    private static var logEntries: [String] = []
    private static let maxLogEntries = 500

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
        // Sanitize control characters that would break JSON serialization
        var sanitized = sentence
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\t", with: " ")

        // Strip markdown formatting that shouldn't be spoken
        sanitized = stripMarkdownForSpeech(sanitized)

        if let data = try? JSONSerialization.data(withJSONObject: ["chunk": sanitized, "index": index, "is_final": false]),
           let line = String(data: data, encoding: .utf8) {
            sendChunk(line, to: connection)
        }
    }

    /// Remove markdown syntax that sounds bad when spoken aloud
    private func stripMarkdownForSpeech(_ text: String) -> String {
        var result = text

        // Remove markdown headers (##, ###, etc.)
        result = result.replacingOccurrences(of: #"^#{1,6}\s+"#, with: "", options: .regularExpression)
        result = result.replacingOccurrences(of: #"\n#{1,6}\s+"#, with: "\n", options: .regularExpression)

        // Remove bold/italic markers (**text**, *text*, __text__, _text_)
        result = result.replacingOccurrences(of: #"\*\*([^\*]+)\*\*"#, with: "$1", options: .regularExpression)
        result = result.replacingOccurrences(of: #"__([^_]+)__"#, with: "$1", options: .regularExpression)
        result = result.replacingOccurrences(of: #"\*([^\*]+)\*"#, with: "$1", options: .regularExpression)
        result = result.replacingOccurrences(of: #"_([^_]+)_"#, with: "$1", options: .regularExpression)

        // Remove code blocks (```code```)
        result = result.replacingOccurrences(of: #"```[^`]*```"#, with: "", options: .regularExpression)
        result = result.replacingOccurrences(of: #"`([^`]+)`"#, with: "$1", options: .regularExpression)

        // Remove links [text](url) -> just keep the text
        result = result.replacingOccurrences(of: #"\[([^\]]+)\]\([^\)]+\)"#, with: "$1", options: .regularExpression)

        // Remove list markers (-, *, •)
        result = result.replacingOccurrences(of: #"^[\-\*•]\s+"#, with: "", options: .regularExpression)
        result = result.replacingOccurrences(of: #"\n[\-\*•]\s+"#, with: "\n", options: .regularExpression)

        return result.trimmingCharacters(in: .whitespacesAndNewlines)
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
        userPrompt: String,
        systemPrompt: String,
        connection: NWConnection,
        startIndex: Int
    ) async -> (success: Bool, responseText: String) {
        // Escape single quotes in prompts for bash heredoc
        let escapedUser = userPrompt.replacingOccurrences(of: "'", with: "'\\''")
        let escapedSystem = systemPrompt.replacingOccurrences(of: "'", with: "'\\''")

        let cmd = """
        timeout 45 '\(claudePath)' --print --verbose --model haiku --allowedTools 'Bash' --permission-mode acceptEdits --output-format stream-json --append-system-prompt '\(escapedSystem)' '\(escapedUser)' 2>&1
        """

        await MainActor.run {
            Self.logEntries.append("[CommandServer] Calling Claude with \(userPrompt.count) char prompt")
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-c", cmd]

        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        await MainActor.run {
            Self.logEntries.append("[CommandServer] Starting Claude at \(claudePath)")
        }

        do {
            try process.run()
            await MainActor.run {
                Self.logEntries.append("[CommandServer] Process started, PID: \(process.processIdentifier)")
            }
        } catch {
            await MainActor.run {
                Self.logEntries.append("[CommandServer] FAILED to start: \(error)")
            }
            sendSentenceChunk("Sorry, I ran into an issue.", index: startIndex, to: connection)
            return (false, "")
        }

        // Capture stderr in background
        Task.detached {
            let data = errorPipe.fileHandleForReading.readDataToEndOfFile()
            if let stderr = String(data: data, encoding: .utf8), !stderr.isEmpty {
                await MainActor.run {
                    Self.logEntries.append("[CommandServer] Claude stderr: \(stderr.prefix(500))")
                }
            }
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

        await MainActor.run {
            Self.logEntries.append("[CommandServer] Claude process exited with code \(exitCode), accumulated: \(accumulatedText.prefix(100))")
        }

        if exitCode != 0 {
            print("[CommandServer] Claude CLI failed with exit code \(exitCode)")
            if accumulatedText.isEmpty {
                let msg = exitCode == 124 ? "Sorry, that took too long." : "Sorry, I ran into an issue."
                await MainActor.run {
                    Self.logEntries.append("[CommandServer] Sending error: \(msg)")
                    sendSentenceChunk(msg, index: chunkIndex, to: connection)
                }
            }
            return (false, accumulatedText)
        }

        return (true, accumulatedText)
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

    // MARK: - Logging

    private func handleLogFromDevice(_ data: Data, _ connection: NWConnection) async {
        guard let requestString = String(data: data, encoding: .utf8) else {
            sendResponse("HTTP/1.1 400 Bad Request\r\n\r\n", to: connection)
            return
        }

        let components = requestString.components(separatedBy: "\r\n\r\n")
        guard components.count >= 2,
              let bodyData = components[1].data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: bodyData) as? [String: Any],
              let message = json["message"] as? String else {
            sendResponse("HTTP/1.1 400 Bad Request\r\n\r\n", to: connection)
            return
        }

        let timestamp = ISO8601DateFormatter().string(from: Date())
        let source = json["source"] as? String ?? "iOS"
        let logLine = "[\(timestamp)] [\(source)] \(message)"

        // Write to file
        if let logData = (logLine + "\n").data(using: .utf8) {
            if let handle = try? FileHandle(forWritingTo: URL(fileURLWithPath: Self.logFile)) {
                handle.seekToEndOfFile()
                handle.write(logData)
                try? handle.close()
            } else {
                try? logData.write(to: URL(fileURLWithPath: Self.logFile))
            }
        }

        // Keep in memory (ring buffer)
        await MainActor.run {
            Self.logEntries.append(logLine)
            if Self.logEntries.count > Self.maxLogEntries {
                Self.logEntries.removeFirst(Self.logEntries.count - Self.maxLogEntries)
            }
        }

        sendResponse("HTTP/1.1 200 OK\r\n\r\n", to: connection)
    }

    private func handleGetLogs(_ connection: NWConnection) async {
        let entries = await MainActor.run { Self.logEntries }
        let logsText = entries.joined(separator: "\n")

        let response = """
        HTTP/1.1 200 OK\r
        Content-Type: text/plain\r
        Content-Length: \(logsText.utf8.count)\r
        \r
        \(logsText)
        """

        sendResponse(response, to: connection)
    }

    // MARK: - HTTP Helper

    private func extractBody(from data: Data) -> String? {
        guard let requestString = String(data: data, encoding: .utf8) else {
            return nil
        }
        let components = requestString.components(separatedBy: "\r\n\r\n")
        guard components.count >= 2 else {
            return nil
        }
        return components[1]
    }

    // MARK: - Diagnostics

    private func handleDiagnose(_ data: Data, _ connection: NWConnection) async {
        // Extract JSON body
        guard let body = extractBody(from: data),
              let bodyData = body.data(using: .utf8) else {
            sendResponse("HTTP/1.1 400 Bad Request\r\n\r\n", to: connection)
            return
        }

        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let snapshot = try decoder.decode(DiagnosticAgent.Snapshot.self, from: bodyData)

            NSLog("[CommandServer] Received diagnostic snapshot: \(snapshot.errorType)")

            // Run diagnostic analysis
            let diagnosis = await DiagnosticAgent.diagnose(snapshot)

            NSLog("[CommandServer] Diagnosis: \(diagnosis.diagnosis) (confidence: \(diagnosis.confidence))")

            // Attempt auto-remediation if applicable
            var remediationResult: RemediationEngine.RemediationResult? = nil
            if diagnosis.remediation.autoFixable {
                NSLog("[CommandServer] Attempting auto-remediation...")
                remediationResult = await RemediationEngine.remediate(diagnosis: diagnosis)
                NSLog("[CommandServer] Remediation result: \(remediationResult?.success == true ? "success" : "failed")")
            }

            // Build response
            let encoder = JSONEncoder()
            encoder.outputFormatting = .prettyPrinted
            encoder.dateEncodingStrategy = .iso8601

            let responseData: [String: Any] = [
                "diagnosis": [
                    "diagnosis": diagnosis.diagnosis,
                    "confidence": diagnosis.confidence,
                    "evidence": diagnosis.evidence,
                    "rootCause": diagnosis.rootCause,
                    "remediation": [
                        "autoFixable": diagnosis.remediation.autoFixable,
                        "requires": diagnosis.remediation.requires as Any,
                        "userAction": diagnosis.remediation.userAction as Any,
                        "workaround": diagnosis.remediation.workaround as Any,
                        "autoFixSteps": diagnosis.remediation.autoFixSteps as Any
                    ],
                    "technicalDetails": diagnosis.technicalDetails as Any
                ],
                "remediation": remediationResult.map { result in
                    [
                        "success": result.success,
                        "actionsTaken": result.actionsTaken,
                        "message": result.message,
                        "error": result.error as Any
                    ]
                } as Any
            ]

            let jsonData = try JSONSerialization.data(withJSONObject: responseData, options: .prettyPrinted)
            let jsonString = String(data: jsonData, encoding: .utf8) ?? "{}"

            let response = """
            HTTP/1.1 200 OK\r
            Content-Type: application/json\r
            Content-Length: \(jsonString.utf8.count)\r
            \r
            \(jsonString)
            """

            sendResponse(response, to: connection)

        } catch {
            NSLog("[CommandServer] Failed to decode diagnostic snapshot: \(error)")
            sendResponse("HTTP/1.1 400 Bad Request\r\n\r\n{\"error\":\"Invalid diagnostic snapshot\"}", to: connection)
        }
    }

    private func handleRemediate(_ data: Data, _ connection: NWConnection) async {
        // Extract JSON body
        guard let body = extractBody(from: data),
              let bodyData = body.data(using: .utf8) else {
            sendResponse("HTTP/1.1 400 Bad Request\r\n\r\n", to: connection)
            return
        }

        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let diagnosis = try decoder.decode(DiagnosticAgent.Diagnosis.self, from: bodyData)

            NSLog("[CommandServer] Received remediation request for: \(diagnosis.diagnosis)")

            // Attempt remediation
            let result = await RemediationEngine.remediate(diagnosis: diagnosis)

            NSLog("[CommandServer] Remediation result: \(result.success ? "success" : "failed")")

            let encoder = JSONEncoder()
            encoder.outputFormatting = .prettyPrinted

            let jsonData = try encoder.encode(result)
            let jsonString = String(data: jsonData, encoding: .utf8) ?? "{}"

            let response = """
            HTTP/1.1 200 OK\r
            Content-Type: application/json\r
            Content-Length: \(jsonString.utf8.count)\r
            \r
            \(jsonString)
            """

            sendResponse(response, to: connection)

        } catch {
            NSLog("[CommandServer] Failed to decode diagnosis: \(error)")
            sendResponse("HTTP/1.1 400 Bad Request\r\n\r\n{\"error\":\"Invalid diagnosis\"}", to: connection)
        }
    }
}
