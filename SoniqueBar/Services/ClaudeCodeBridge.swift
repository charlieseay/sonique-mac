import Foundation
import os.log

/// Memory persistence mode
enum MemoryMode {
    case persistent      // Remember across sessions (7-day window)
    case sessionOnly     // Only remember within current session
}

/// Routes voice commands directly to Claude Code CLI with full MCP tool access
class ClaudeCodeBridge {
    private let logger = Logger(subsystem: "com.seayniclabs.soniquebar", category: "ClaudeCodeBridge")

    // PERF OPT #7: Time-based conversation history instead of fixed count
    // Keep messages from last 7 days (sliding window) to maintain context across gaps in usage
    // Example: Friday noon → Monday morning should retain Friday's context
    private var conversationHistory: [(role: String, content: String, timestamp: Date)] = []
    private let maxHistoryDuration: TimeInterval = 7 * 24 * 60 * 60  // 7 days

    // Memory mode control
    private var memoryMode: MemoryMode = .persistent  // Default: remember across sessions

    func execute(text: String, imageBase64: String? = nil, mcpToolsAvailable: Bool = true, conversationHistoryFromDevice: [[String: String]]? = nil) async throws -> String {
        logger.info("[ClaudeCodeBridge] Executing: \(text.prefix(80))\(imageBase64 != nil ? " [with image]" : "")")

        // SYNC: Load conversation history from iOS device if provided
        if let deviceHistory = conversationHistoryFromDevice, !deviceHistory.isEmpty {
            self.conversationHistory.removeAll()  // Clear session history
            let now = Date()
            for exchange in deviceHistory {
                if let user = exchange["user"], let assistant = exchange["assistant"] {
                    self.conversationHistory.append((role: "user", content: user, timestamp: now))
                    self.conversationHistory.append((role: "assistant", content: assistant, timestamp: now))
                }
            }
            logger.info("[ClaudeCodeBridge] Loaded \(self.conversationHistory.count/2) exchanges from device history")
        }

        // VISION: If image provided, route directly to Claude API (requires vision model)
        if let imageData = imageBase64 {
            logger.info("[ClaudeCodeBridge] Vision request - calling Claude API directly")
            return try await handleVisionRequest(text: text, imageBase64: imageData)
        }

        // TIER 0: Native Intent Router (instant, no LLM)
        if let nativeResponse = await IntentRouter.shared.route(text) {
            logger.info("[ClaudeCodeBridge] ✓ Native intent handled: \(nativeResponse.prefix(50))")

            // PERF OPT #7: Add to conversation history with timestamp
            let now = Date()
            conversationHistory.append((role: "user", content: text, timestamp: now))
            conversationHistory.append((role: "assistant", content: nativeResponse, timestamp: now))

            // Persist to SQLite for offline fallback
            ConversationMemory.shared.logUser(text)
            ConversationMemory.shared.logAssistant(nativeResponse)

            // Trim history to maxHistoryDuration window
            trimHistoryToTimeWindow()

            return nativeResponse
        }

        // Check if this is a capability query - respond directly from index
        if CapabilityIndex.isCapabilityQuery(text) {
            logger.info("[ClaudeCodeBridge] Capability query detected - using index")
            return CapabilityIndex.generateCapabilitySummary()
        }

        // Add user message to history with timestamp
        let now = Date()
        conversationHistory.append((role: "user", content: text, timestamp: now))

        // Persist to SQLite for offline fallback
        ConversationMemory.shared.logUser(text)

        // PERF OPT #7: Trim history to time window instead of fixed count
        trimHistoryToTimeWindow()

        // Load FULL memory context from Application Support (not just iCloud personality)
        // This includes: Identity + Rules + Soul + Context (Charlie) + Recent Conversations
        let fullMemory = await MemoryService.shared.loadFullContext()

        // TEMPORARY: Hardcode name to test if iCloud is the blocker
        let assistantName = "Quinn"
        // TODO: Restore this after testing
        // let assistantName = await SoniqueBrain.shared.getAssistantName()

        // Generate capability context
        // NOTE: Disabled for Quinn - the capability index lists MCP/Lab tools that confuse the voice assistant
        // Quinn's actual capabilities are defined in IDENTITY.md instead
        let capabilityContext = ""  // CapabilityIndex.generateCapabilitySummary()

        // Detect project mentions and add vault path context
        var projectContext = ""
        if let project = CapabilityIndex.detectProject(in: text) {
            if let vaultPath = CapabilityIndex.vaultPath(for: project) {
                projectContext = "\n\n## Project Context:\nQuery mentions **\(project)** → vault path: `~/Library/Mobile Documents/iCloud~md~obsidian/Documents/SeaynicNet/\(vaultPath)`\n"
                logger.info("[ClaudeCodeBridge] Project detected: \(project) → \(vaultPath)")
            }
        }

        // Build conversation context
        var historyContext = ""
        if conversationHistory.count > 1 {  // More than just current message
            historyContext = "\n\n## Current Session:\n"
            for (role, content, _) in conversationHistory.dropLast() {  // Exclude current message, ignore timestamp
                let speaker = role == "user" ? "User" : assistantName
                historyContext += "\(speaker): \(content)\n"
            }
        }

        // CRITICAL: Strong capability constraint at the TOP to prevent hallucination
        let capabilityConstraint = """
        CRITICAL CONSTRAINT: You are a VOICE ASSISTANT with NO access to:
        - Screen capture or visual access
        - File system or documents
        - Terminal commands or code execution
        - System services (Docker, infrastructure, etc.)
        - Live web browsing

        If asked about ANY of these, respond ONLY: "I can't [action] - I'm a voice assistant without that capability."
        DO NOT make up responses. DO NOT pretend to check things you cannot access.

        """

        let prompt = capabilityConstraint + "Your name is \(assistantName).\n\n\(fullMemory)\n\n\(capabilityContext)\(projectContext)\(historyContext)\n\nUser: \(text)"

        // Route through ModelRouter with context
        // IMPORTANT: Pass the ORIGINAL text for tier determination, not the full prompt
        let context = QueryContext(
            mcpToolsAvailable: mcpToolsAvailable,
            conversationLength: conversationHistory.count,
            originalQuery: text  // ← Use raw query for tier classification
        )

        let result: (stdout: String, stderr: String, exitCode: Int32)
        do {
            let response = try await ModelRouter.shared.route(prompt: prompt, context: context)
            logger.info("[ClaudeCodeBridge] Provider: \(response.provider), Tier: \(response.tier.rawValue), Latency: \(String(format: "%.2f", response.latency))s")
            result = (stdout: response.text, stderr: "", exitCode: 0)
        } catch {
            logger.error("[ClaudeCodeBridge] ModelRouter failed: \(error.localizedDescription)")
            // Propagate the actual error instead of wrapping it
            throw BridgeError.executionFailed("ModelRouter error: \(error.localizedDescription)")
        }

        if result.exitCode == 0 && !result.stdout.isEmpty {
            let response = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)

            if response.isEmpty {
                logger.error("[ClaudeCodeBridge] Empty response from Claude CLI")
                throw BridgeError.executionFailed("Empty response")
            }

            // Phase 6C: Check if web search fallback needed
            if Self.needsWebSearch(response) {
                logger.info("[ClaudeCodeBridge] Response indicates need for web search, attempting fallback...")

                do {
                    let searchResults = try await Self.performWebSearch(query: text)
                    let searchPrompt = "Your name is \(assistantName).\n\n\(fullMemory)\n\nUser asked: \(text)\n\nWeb search results:\n\(searchResults)\n\nBased on these search results, please answer the user's question."

                    let searchResult: (stdout: String, stderr: String, exitCode: Int32)
                    do {
                        let searchResponse = try await ModelRouter.shared.route(prompt: searchPrompt)
                        searchResult = (stdout: searchResponse.text, stderr: "", exitCode: 0)
                    } catch {
                        searchResult = (stdout: "", stderr: error.localizedDescription, exitCode: 1)
                    }

                    if searchResult.exitCode == 0 && !searchResult.stdout.isEmpty {
                        let searchResponse = searchResult.stdout.trimmingCharacters(in: .whitespacesAndNewlines)

                        // Add web-enhanced response to history with timestamp
                        conversationHistory.append((role: "assistant", content: searchResponse, timestamp: Date()))
                        trimHistoryToTimeWindow()  // PERF OPT #7: Use time window

                        logger.info("[ClaudeCodeBridge] Web search fallback successful")
                        return searchResponse
                    }
                } catch {
                    logger.warning("[ClaudeCodeBridge] Web search fallback failed: \(error.localizedDescription)")
                    // Fall through to return original response
                }
            }

            // Add assistant response to history with timestamp
            conversationHistory.append((role: "assistant", content: response, timestamp: Date()))
            trimHistoryToTimeWindow()  // PERF OPT #7: Use time window

            // Persist to SQLite for offline fallback
            ConversationMemory.shared.logAssistant(response)

            // Persist to conversations.jsonl for long-term memory
            await MemoryService.shared.recordExchange(user: text, assistant: response)

            logger.info("[ClaudeCodeBridge] Success via Claude CLI (MCP-enabled + history): \(response.prefix(50))")
            return response
        } else {
            logger.error("[ClaudeCodeBridge] Claude CLI failed: \(result.stderr)")
            throw BridgeError.executionFailed("Assistant unavailable")
        }
    }


    enum BridgeError: Error {
        case executionFailed(String)
    }

    private func executeProcess(
        executable: String,
        arguments: [String],
        timeout: TimeInterval
    ) async -> (stdout: String, stderr: String, exitCode: Int32) {
        return await withCheckedContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments

            var env = ProcessInfo.processInfo.environment
            env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
            env["HOME"] = env["HOME"] ?? "/Users/charlieseay"
            process.environment = env

            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()
            process.standardOutput = stdoutPipe
            process.standardError = stderrPipe

            // Use NSLock to synchronize access to shared state
            let lock = NSLock()
            var stdoutData = Data()
            var stderrData = Data()
            var didComplete = false

            stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
                lock.lock()
                defer { lock.unlock() }
                stdoutData.append(handle.availableData)
            }

            stderrPipe.fileHandleForReading.readabilityHandler = { handle in
                lock.lock()
                defer { lock.unlock() }
                stderrData.append(handle.availableData)
            }

            process.terminationHandler = { process in
                lock.lock()
                guard !didComplete else {
                    lock.unlock()
                    return
                }
                didComplete = true
                // Copy data inside lock to avoid data races
                let stdoutCopy = stdoutData
                let stderrCopy = stderrData
                lock.unlock()

                let stdout = String(data: stdoutCopy, encoding: .utf8) ?? ""
                let stderr = String(data: stderrCopy, encoding: .utf8) ?? ""

                continuation.resume(returning: (
                    stdout.trimmingCharacters(in: .whitespacesAndNewlines),
                    stderr.trimmingCharacters(in: .whitespacesAndNewlines),
                    process.terminationStatus
                ))
            }

            do {
                try process.run()

                Task {
                    try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                    if process.isRunning {
                        process.terminate()
                        lock.lock()
                        if !didComplete {
                            didComplete = true
                            lock.unlock()
                            continuation.resume(returning: ("", "Process timed out", 124))
                        } else {
                            lock.unlock()
                        }
                    }
                }
            } catch {
                lock.lock()
                if !didComplete {
                    didComplete = true
                    lock.unlock()
                    continuation.resume(returning: ("", error.localizedDescription, -1))
                } else {
                    lock.unlock()
                }
            }
        }
    }

    // MARK: - Phase 6C: Web Search Helpers

    private static func needsWebSearch(_ response: String) -> Bool {
        let patterns = [
            "I don't have current information",
            "My knowledge cutoff",
            "I cannot access real-time",
            "As of my last update",
            "I don't have access to current"
        ]

        let lowercased = response.lowercased()
        return patterns.contains { lowercased.contains($0.lowercased()) }
    }

    private static func performWebSearch(query: String) async throws -> String {
        // DuckDuckGo Instant Answer API
        guard var components = URLComponents(string: "https://api.duckduckgo.com/") else {
            throw BridgeError.executionFailed("Invalid search URL")
        }

        components.queryItems = [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "format", value: "json"),
            URLQueryItem(name: "no_html", value: "1"),
            URLQueryItem(name: "skip_disambig", value: "1")
        ]

        guard let url = components.url else {
            throw BridgeError.executionFailed("Invalid search URL")
        }

        let (data, response) = try await URLSession.shared.data(from: url)

        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            throw BridgeError.executionFailed("Search request failed")
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw BridgeError.executionFailed("Invalid search response")
        }

        var results: [String] = []

        if let abstract = json["Abstract"] as? String, !abstract.isEmpty {
            results.append("Summary: \(abstract)")
        }

        if let abstractURL = json["AbstractURL"] as? String, !abstractURL.isEmpty {
            results.append("Source: \(abstractURL)")
        }

        if let relatedTopics = json["RelatedTopics"] as? [[String: Any]] {
            for (index, topic) in relatedTopics.prefix(3).enumerated() {
                if let text = topic["Text"] as? String, !text.isEmpty {
                    results.append("Related (\(index + 1)): \(text)")
                }
            }
        }

        if results.isEmpty {
            throw BridgeError.executionFailed("No search results found")
        }

        return results.joined(separator: "\n\n")
    }

    // PERF OPT #7: Trim conversation history to time window
    private func trimHistoryToTimeWindow() {
        let now = Date()
        conversationHistory.removeAll { (_, _, timestamp) in
            now.timeIntervalSince(timestamp) > maxHistoryDuration
        }
    }

    // MARK: - Memory Control (Feature #2: Memory Boundaries UI)

    /// Set memory persistence mode
    func setMemoryMode(_ mode: MemoryMode) {
        memoryMode = mode
        logger.info("[ClaudeCodeBridge] Memory mode set to: \(mode == .persistent ? "persistent" : "sessionOnly")")
    }

    /// Get current memory mode
    func getMemoryMode() -> MemoryMode {
        return memoryMode
    }

    /// Get summary of what's currently in memory
    func getMemorySummary() async -> String {
        var summary = "**Memory Mode**: \(memoryMode == .persistent ? "Persistent (7-day window)" : "Session-only")\n\n"

        if conversationHistory.isEmpty {
            summary += "No conversation history yet."
            return summary
        }

        summary += "**Conversation History**: \(conversationHistory.count) messages\n"
        summary += "**Oldest message**: \(conversationHistory.first?.timestamp.formatted() ?? "unknown")\n"
        summary += "**Most recent**: \(conversationHistory.last?.timestamp.formatted() ?? "unknown")\n\n"

        // Show last 5 exchanges
        let recentHistory = conversationHistory.suffix(10)  // Last 5 exchanges (10 messages)
        summary += "**Recent conversation** (last 5 exchanges):\n"
        for (role, content, timestamp) in recentHistory {
            let speaker = role == "user" ? "You" : "Quinn"
            let preview = content.prefix(60)
            summary += "- [\(timestamp.formatted(date: .omitted, time: .shortened))] \(speaker): \(preview)...\n"
        }

        return summary
    }

    /// Clear conversation history
    func clearMemory() async {
        conversationHistory.removeAll()
        logger.info("[ClaudeCodeBridge] Memory cleared")
    }

    // MARK: - Vision Support

    private func handleVisionRequest(text: String, imageBase64: String) async throws -> String {
        logger.info("[ClaudeCodeBridge] Processing vision request")

        // Load API key
        let keyPath = "/Volumes/data/secrets/anthropic_api_key"
        guard let apiKey = try? String(contentsOfFile: keyPath, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines),
              !apiKey.isEmpty else {
            throw BridgeError.executionFailed("Anthropic API key not found")
        }

        // Construct Claude API request with vision
        let url = URL(string: "https://api.anthropic.com/v1/messages")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let payload: [String: Any] = [
            "model": "claude-sonnet-4-20250514",
            "max_tokens": 2048,
            "messages": [
                [
                    "role": "user",
                    "content": [
                        [
                            "type": "image",
                            "source": [
                                "type": "base64",
                                "media_type": "image/jpeg",
                                "data": imageBase64
                            ]
                        ],
                        [
                            "type": "text",
                            "text": text
                        ]
                    ]
                ]
            ]
        ]

        request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        request.timeoutInterval = 60

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
            logger.error("[ClaudeCodeBridge] Vision API error: \(statusCode)")
            throw BridgeError.executionFailed("Vision API error: \(statusCode)")
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let content = json["content"] as? [[String: Any]],
              let firstBlock = content.first,
              let responseText = firstBlock["text"] as? String else {
            logger.error("[ClaudeCodeBridge] Failed to parse vision response")
            throw BridgeError.executionFailed("Failed to parse vision response")
        }

        logger.info("[ClaudeCodeBridge] Vision response: \(responseText.prefix(50))")
        return responseText
    }
}
