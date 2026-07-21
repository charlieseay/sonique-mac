import Foundation
import os.log

/// Loads and manages the 4-tier memory architecture from Application Support
/// Layer 1: Identity (permanent) - IDENTITY.md, RULES.md, SOUL.md, CAPABILITIES.md
/// Layer 2: Context (semi-permanent) - context.md (Charlie, projects, team, environment)
/// Layer 3: Conversations (rolling 90-day JSONL)
/// Layer 4: Working Memory (session-only, handled by ClaudeCodeBridge)
final class MemoryService {
    static let shared = MemoryService()

    private let logger = Logger(subsystem: "com.seayniclabs.soniquebar", category: "MemoryService")
    private let fm = FileManager.default

    // Memory directory in Application Support (NOT iCloud - this is local intelligence)
    private var memoryDir: URL {
        let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return appSupport.appendingPathComponent("SoniqueBar/memory")
    }

    // Cache to avoid re-reading files every request
    private var cachedContext: String?
    private var lastContextLoad: Date?
    private let contextCacheDuration: TimeInterval = 60.0  // Refresh every 60 seconds

    private init() {
        ensureMemoryStructure()
    }

    private func ensureMemoryStructure() {
        try? fm.createDirectory(at: memoryDir, withIntermediateDirectories: true)
    }

    // MARK: - Full Context Loading (All Layers)

    /// Load complete context for LLM: Identity + Context + Recent Conversations
    /// This is what gets passed to the model on every request
    func loadFullContext() -> String {
        // Check cache first
        if let cached = cachedContext,
           let lastLoad = lastContextLoad,
           Date().timeIntervalSince(lastLoad) < contextCacheDuration {
            return cached
        }

        var fullContext = ""

        // Layer 1: Identity (permanent)
        fullContext += loadIdentity()

        // Layer 2: Context (semi-permanent - who Charlie is, projects, environment)
        fullContext += loadContext()

        // Layer 3: Recent conversations (last 10 exchanges from JSONL)
        fullContext += loadRecentConversations(count: 10)

        // Cache it
        cachedContext = fullContext
        lastContextLoad = Date()

        logger.info("[MemoryService] Loaded full context: \(fullContext.count) bytes")
        return fullContext
    }

    // MARK: - Layer 1: Identity (Permanent)

    private func loadIdentity() -> String {
        var identity = ""

        // IDENTITY.md - Who Quinn is
        if let identityContent = readFile("IDENTITY.md") {
            identity += identityContent + "\n\n"
        }

        // RULES.md - Core behavioral rules
        if let rulesContent = readFile("RULES.md") {
            identity += rulesContent + "\n\n"
        }

        // SOUL.md - Evolving personality traits
        if let soulContent = readFile("SOUL.md") {
            identity += "# Evolving Traits\n" + soulContent + "\n\n"
        }

        // CAPABILITIES.md - What Quinn can do
        if let capsContent = readFile("CAPABILITIES.md") {
            identity += capsContent + "\n\n"
        }

        return identity
    }

    // MARK: - Layer 2: Context (Semi-Permanent)

    private func loadContext() -> String {
        guard let contextContent = readFile("context.md") else {
            logger.warning("[MemoryService] context.md not found - Quinn doesn't know who Charlie is!")
            return ""
        }

        return "# Context\n\n" + contextContent + "\n\n"
    }

    // MARK: - Layer 3: Conversations (Recent History)

    private func loadRecentConversations(count: Int) -> String {
        let conversationsFile = memoryDir.appendingPathComponent("conversations.jsonl")

        guard let data = try? Data(contentsOf: conversationsFile),
              let content = String(data: data, encoding: .utf8) else {
            return ""
        }

        // Parse JSONL (one JSON object per line)
        let lines = content.components(separatedBy: .newlines).filter { !$0.isEmpty }
        let recentLines = lines.suffix(count)

        var conversationContext = "# Recent Conversations\n\n"

        for line in recentLines {
            guard let jsonData = line.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
                  let user = json["user"] as? String,
                  let assistant = json["assistant"] as? String else {
                continue
            }

            conversationContext += "User: \(user)\n"
            conversationContext += "Assistant: \(assistant)\n\n"
        }

        return conversationContext
    }

    // MARK: - Conversation Persistence

    /// Save a conversation exchange to conversations.jsonl
    func recordExchange(user: String, assistant: String) {
        let conversationsFile = memoryDir.appendingPathComponent("conversations.jsonl")

        let entry: [String: Any] = [
            "timestamp": ISO8601DateFormatter().string(from: Date()),
            "user": user,
            "assistant": assistant
        ]

        guard let jsonData = try? JSONSerialization.data(withJSONObject: entry),
              var jsonString = String(data: jsonData, encoding: .utf8) else {
            logger.error("[MemoryService] Failed to serialize conversation entry")
            return
        }

        jsonString += "\n"

        // Append to JSONL file
        if let data = jsonString.data(using: .utf8) {
            if fm.fileExists(atPath: conversationsFile.path) {
                // Append to existing file
                if let fileHandle = try? FileHandle(forWritingTo: conversationsFile) {
                    fileHandle.seekToEndOfFile()
                    fileHandle.write(data)
                    try? fileHandle.close()
                }
            } else {
                // Create new file
                try? data.write(to: conversationsFile)
            }

            logger.info("[MemoryService] Recorded conversation exchange")
        }
    }

    // MARK: - Helper: Read File

    private func readFile(_ filename: String) -> String? {
        let url = memoryDir.appendingPathComponent(filename)
        guard let content = try? String(contentsOf: url, encoding: .utf8) else {
            return nil
        }
        return content
    }

    // MARK: - Cache Invalidation

    /// Force reload of context on next request (call after memory files change)
    func invalidateCache() {
        cachedContext = nil
        lastContextLoad = nil
        logger.info("[MemoryService] Cache invalidated - will reload on next request")
    }
}
