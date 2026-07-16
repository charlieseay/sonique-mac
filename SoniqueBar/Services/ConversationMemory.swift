import Foundation
import SQLite3
import os.log

/// Manages conversation history in SQLite for context continuity
/// Stores user queries and assistant responses to enable "what did I ask earlier?" queries
class ConversationMemory {
    static let shared = ConversationMemory()

    private let logger = Logger(subsystem: "com.seayniclabs.soniquebar", category: "ConversationMemory")
    private var db: OpaquePointer?
    private let currentSessionId: String

    private init() {
        // Generate session ID (unique per app launch)
        self.currentSessionId = UUID().uuidString

        do {
            let dbPath = try Self.databasePath()
            try openDatabase(at: dbPath)
            try createTableIfNeeded()
            logger.info("[ConversationMemory] Initialized with session \(self.currentSessionId)")
        } catch {
            logger.error("[ConversationMemory] Failed to initialize: \(error.localizedDescription)")
        }
    }

    deinit {
        if db != nil {
            sqlite3_close(db)
        }
    }

    // MARK: - Database Setup

    private static func databasePath() throws -> String {
        let supportDir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let appDir = supportDir.appendingPathComponent("SoniqueBar")

        try FileManager.default.createDirectory(at: appDir, withIntermediateDirectories: true)

        return appDir.appendingPathComponent("conversations.db").path
    }

    private func openDatabase(at path: String) throws {
        if sqlite3_open(path, &db) != SQLITE_OK {
            throw NSError(domain: "ConversationMemory", code: 1, userInfo: [NSLocalizedDescriptionKey: "Failed to open database"])
        }
    }

    private func createTableIfNeeded() throws {
        let createTableSQL = """
        CREATE TABLE IF NOT EXISTS conversations (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            session_id TEXT NOT NULL,
            timestamp INTEGER NOT NULL,
            role TEXT NOT NULL,
            content TEXT NOT NULL
        );
        CREATE INDEX IF NOT EXISTS idx_session_timestamp ON conversations(session_id, timestamp DESC);
        """

        if sqlite3_exec(db, createTableSQL, nil, nil, nil) != SQLITE_OK {
            throw NSError(domain: "ConversationMemory", code: 2, userInfo: [NSLocalizedDescriptionKey: "Failed to create table"])
        }

        logger.info("[ConversationMemory] Table ready")
    }

    // MARK: - Public API

    /// Log a user message
    func logUser(_ text: String) {
        log(role: "user", content: text)
    }

    /// Log an assistant response
    func logAssistant(_ text: String) {
        log(role: "assistant", content: text)
    }

    /// Get recent conversation history (last N exchanges)
    func getRecentHistory(count: Int = 5) -> [(role: String, content: String)] {
        guard db != nil else { return [] }

        let querySQL = """
        SELECT role, content FROM conversations
        ORDER BY timestamp DESC
        LIMIT ?
        """

        var statement: OpaquePointer?
        var history: [(String, String)] = []

        if sqlite3_prepare_v2(db, querySQL, -1, &statement, nil) == SQLITE_OK {
            sqlite3_bind_int(statement, 1, Int32(count * 2))  // user + assistant = 2 per exchange

            while sqlite3_step(statement) == SQLITE_ROW {
                let role = String(cString: sqlite3_column_text(statement, 0))
                let content = String(cString: sqlite3_column_text(statement, 1))
                history.append((role, content))
            }
        }

        sqlite3_finalize(statement)
        return history.reversed()  // Oldest first
    }

    /// Format recent history for prompt context
    func formatForPrompt(count: Int = 5) -> String {
        let history = getRecentHistory(count: count)

        if history.isEmpty {
            return ""
        }

        var formatted = "\n\n## Recent Conversation History:\n"
        for (role, content) in history {
            let speaker = role == "user" ? "User" : "Assistant"
            formatted += "\(speaker): \(content)\n"
        }

        return formatted
    }

    /// Clear all conversation history
    func clearAll() {
        guard db != nil else { return }

        if sqlite3_exec(db, "DELETE FROM conversations", nil, nil, nil) == SQLITE_OK {
            logger.info("[ConversationMemory] Cleared all history")
        } else {
            logger.error("[ConversationMemory] Failed to clear history")
        }
    }

    /// Clear history older than N days
    func clearOlderThan(days: Int) {
        guard db != nil else { return }

        let cutoff = Int64(Date().timeIntervalSince1970) - Int64(days * 24 * 60 * 60)
        let deleteSQL = "DELETE FROM conversations WHERE timestamp < ?"

        var statement: OpaquePointer?
        if sqlite3_prepare_v2(db, deleteSQL, -1, &statement, nil) == SQLITE_OK {
            sqlite3_bind_int64(statement, 1, cutoff)
            if sqlite3_step(statement) == SQLITE_DONE {
                logger.info("[ConversationMemory] Cleared history older than \(days) days")
            }
        }
        sqlite3_finalize(statement)
    }

    // MARK: - Private Helpers

    private func log(role: String, content: String) {
        guard db != nil else { return }

        let now = Int64(Date().timeIntervalSince1970)
        let insertSQL = "INSERT INTO conversations (session_id, timestamp, role, content) VALUES (?, ?, ?, ?)"

        var statement: OpaquePointer?
        if sqlite3_prepare_v2(db, insertSQL, -1, &statement, nil) == SQLITE_OK {
            sqlite3_bind_text(statement, 1, (currentSessionId as NSString).utf8String, -1, nil)
            sqlite3_bind_int64(statement, 2, now)
            sqlite3_bind_text(statement, 3, (role as NSString).utf8String, -1, nil)
            sqlite3_bind_text(statement, 4, (content as NSString).utf8String, -1, nil)

            if sqlite3_step(statement) == SQLITE_DONE {
                logger.info("[ConversationMemory] Logged \(role): \(content.prefix(50))...")
            } else {
                logger.error("[ConversationMemory] Failed to log message")
            }
        }

        sqlite3_finalize(statement)
    }
}
