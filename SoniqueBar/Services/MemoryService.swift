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
            logger.warning("[MemoryService] context.md not found - continuing with identity only")
            // Return empty string instead of crashing - graceful degradation
            return ""
        }

        return "# Context\n\n" + contextContent + "\n\n"
    }

    // MARK: - Layer 3: Conversations (Recent History)

    private func loadRecentConversations(count: Int) -> String {
        let conversationsFile = memoryDir.appendingPathComponent("conversations.jsonl")

        // PERF OPT #3: Stream last N lines using tail-like approach instead of loading entire file
        // This avoids memory spike for large conversation logs
        guard let fileHandle = try? FileHandle(forReadingFrom: conversationsFile) else {
            return ""
        }

        defer { try? fileHandle.close() }

        // Seek to end and read backwards to get last N lines efficiently
        let fileSizeRaw = fileHandle.seekToEndOfFile()
        var tailBuffer = Data()
        let bufferSize: Int = 8192  // 8KB chunks for efficient reading

        // Read file backwards in chunks to extract last N lines
        var offset: UInt64 = fileSizeRaw
        while tailBuffer.count < 100_000 && offset > 0 {  // Max 100KB scan
            let chunkSize = min(bufferSize, Int(offset))
            offset -= UInt64(chunkSize)
            fileHandle.seek(toFileOffset: offset)

            let chunk = fileHandle.readData(ofLength: chunkSize)
            if chunk.count > 0 {
                tailBuffer.insert(contentsOf: chunk, at: 0)
            }
        }

        guard let content = String(data: tailBuffer, encoding: .utf8) else {
            return ""
        }

        // Parse JSONL (one JSON object per line)
        // Security: Validate JSONL format and skip malformed entries
        let lines = content.components(separatedBy: .newlines).filter { !$0.isEmpty }
        let recentLines = Array(lines.suffix(count))

        var conversationContext = "# Recent Conversations\n\n"
        var skippedCount = 0

        for line in recentLines {
            // Trim whitespace
            let trimmedLine = line.trimmingCharacters(in: .whitespaces)
            if trimmedLine.isEmpty {
                continue
            }

            guard let jsonData = trimmedLine.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
                  let user = json["user"] as? String,
                  let assistant = json["assistant"] as? String else {
                skippedCount += 1
                logger.warning("[MemoryService] Skipped malformed JSONL entry")
                continue
            }

            conversationContext += "User: \(user)\n"
            conversationContext += "Assistant: \(assistant)\n\n"
        }

        if skippedCount > 0 {
            logger.info("[MemoryService] Loaded \(recentLines.count - skippedCount) conversations, skipped \(skippedCount) malformed entries")
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
