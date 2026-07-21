import Foundation
import os.log

/// Routes voice commands directly to Claude Code CLI with full MCP tool access
class ClaudeCodeBridge {
    private let logger = Logger(subsystem: "com.seayniclabs.soniquebar", category: "ClaudeCodeBridge")

    // Phase 6B: Simple in-memory conversation history (last 5 exchanges)
    private var conversationHistory: [(role: String, content: String)] = []
    private let maxHistoryCount = 10  // 5 exchanges = 10 messages

    func execute(text: String, mcpToolsAvailable: Bool = true) async throws -> String {
        logger.info("[ClaudeCodeBridge] Executing: \(text.prefix(80))")

        // TIER 0: Native Intent Router (instant, no LLM)
        if let nativeResponse = await IntentRouter.shared.route(text) {
            logger.info("[ClaudeCodeBridge] ✓ Native intent handled: \(nativeResponse.prefix(50))")

            // Add to conversation history
            conversationHistory.append((role: "user", content: text))
            conversationHistory.append((role: "assistant", content: nativeResponse))
            if conversationHistory.count > maxHistoryCount {
                conversationHistory.removeFirst(2)  // Remove oldest pair
            }

            return nativeResponse
        }

        // Check if this is a capability query - respond directly from index
        if CapabilityIndex.isCapabilityQuery(text) {
            logger.info("[ClaudeCodeBridge] Capability query detected - using index")
            return CapabilityIndex.generateCapabilitySummary()
        }

        // Add user message to history
        conversationHistory.append((role: "user", content: text))
        if conversationHistory.count > maxHistoryCount {
            conversationHistory.removeFirst()
        }

        // Load FULL memory context from Application Support (not just iCloud personality)
        // This includes: Identity + Rules + Soul + Context (Charlie) + Recent Conversations
        let fullMemory = await MemoryService.shared.loadFullContext()

        // Also load name from iCloud (user-configurable)
        let assistantName = await SoniqueBrain.shared.getAssistantName()

        // Generate capability context
        let capabilityContext = CapabilityIndex.generateCapabilitySummary()

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
            for (role, content) in conversationHistory.dropLast() {  // Exclude current message
                let speaker = role == "user" ? "User" : assistantName
                historyContext += "\(speaker): \(content)\n"
            }
        }

        let prompt = "Your name is \(assistantName).\n\n\(fullMemory)\n\n\(capabilityContext)\(projectContext)\(historyContext)\n\nUser: \(text)"

        // Route through ModelRouter with context
        // IMPORTANT: Pass the ORIGINAL text for tier determination, not the full prompt
        let context = QueryContext(
            mcpToolsAvailable: mcpToolsAvailable,
            conversationLength: conversationHistory.count,
            originalQuery: text  // ← Use raw query for tier classification
        )

        let result: (stdout: String, stderr: String, exitCode: Int32)
        do {
            NSLog("[ClaudeCodeBridge] Calling ModelRouter.route() with prompt length: \(prompt.count)")
            let response = try await ModelRouter.shared.route(prompt: prompt, context: context)
            NSLog("[ClaudeCodeBridge] ✓ ModelRouter success: Provider: \(response.provider), Tier: \(response.tier.rawValue), Latency: \(String(format: "%.2f", response.latency))s")
            logger.info("[ClaudeCodeBridge] Provider: \(response.provider), Tier: \(response.tier.rawValue), Latency: \(String(format: "%.2f", response.latency))s")
            result = (stdout: response.text, stderr: "", exitCode: 0)
        } catch {
            NSLog("[ClaudeCodeBridge] ❌ ModelRouter failed: \(error)")
            NSLog("[ClaudeCodeBridge] ❌ DETAILED ERROR: \(String(describing: error))")
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

                        // Phase 6B: Add web-enhanced response to history
                        conversationHistory.append((role: "assistant", content: searchResponse))
                        if conversationHistory.count > maxHistoryCount {
                            conversationHistory.removeFirst()
                        }

                        logger.info("[ClaudeCodeBridge] Web search fallback successful")
                        return searchResponse
                    }
                } catch {
                    logger.warning("[ClaudeCodeBridge] Web search fallback failed: \(error.localizedDescription)")
                    // Fall through to return original response
                }
            }

            // Phase 6B: Add assistant response to history
            conversationHistory.append((role: "assistant", content: response))
            if conversationHistory.count > maxHistoryCount {
                conversationHistory.removeFirst()
            }

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
}
