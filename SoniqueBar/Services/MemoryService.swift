import Foundation

/// Manages Sonique's memory: conversations, context, and learning
@MainActor
class MemoryService: ObservableObject {
    static let shared = MemoryService()

    @Published var workingMemory: [Exchange] = []
    @Published var memorySizeMB: Double = 0.0

    // iCloud sync directory (shared across Mac and iOS)
    private let iCloudDir = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Mobile Documents/iCloud~com~seayniclabs~sonique/Documents/SoniqueProfiles/Desktop")

    // Local cache directory (fallback if iCloud unavailable)
    private let localDir = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/SoniqueBar/memory")

    private let conversationsFile: URL
    private let identityFile: URL
    private let rulesFile: URL
    private let soulFile: URL
    private let capabilitiesFile: URL
    private let contextFile: URL
    private let configFile: URL

    private var config: MemoryConfig
    private let maxWorkingMemoryExchanges = 50  // Increased from 20 to maintain longer conversation context

    struct Exchange: Codable {
        let timestamp: Date
        let user: String
        let assistant: String
        var intent: String?
        var actionsTaken: [String]?
    }

    struct MemoryConfig: Codable {
        var memory_budget_mb: Int
        var conversation_retention_days: Int
        var auto_clean: Bool
        var prioritize_task_conversations: Bool
        var learning_enabled: Bool
    }

    private init() {
        // Use iCloud for persistent identity/rules/soul (synced across devices)
        identityFile = iCloudDir.appendingPathComponent("IDENTITY.md")
        rulesFile = iCloudDir.appendingPathComponent("RULES.md")
        soulFile = iCloudDir.appendingPathComponent("SOUL.md")
        capabilitiesFile = iCloudDir.appendingPathComponent("CAPABILITIES.md")
        conversationsFile = iCloudDir.appendingPathComponent("conversations.jsonl")

        // Use local for config (device-specific settings)
        contextFile = localDir.appendingPathComponent("context.md")
        configFile = localDir.appendingPathComponent("config.json")

        // Load config
        if let data = try? Data(contentsOf: configFile),
           let loadedConfig = try? JSONDecoder().decode(MemoryConfig.self, from: data) {
            config = loadedConfig
        } else {
            // Default config
            config = MemoryConfig(
                memory_budget_mb: 512,
                conversation_retention_days: 90,
                auto_clean: true,
                prioritize_task_conversations: true,
                learning_enabled: true
            )
        }

        updateMemorySize()
    }

    // MARK: - Working Memory

    func addExchange(user: String, assistant: String, intent: String? = nil, actions: [String]? = nil) {
        let exchange = Exchange(
            timestamp: Date(),
            user: user,
            assistant: assistant,
            intent: intent,
            actionsTaken: actions
        )

        workingMemory.append(exchange)

        // Keep only last 20 exchanges in working memory
        if workingMemory.count > maxWorkingMemoryExchanges {
            workingMemory.removeFirst()
        }

        // Log to JSONL
        logConversation(exchange)
    }

    /// Search conversation history (simple grep-like search)
    func searchConversations(_ query: String, limit: Int = 20) -> [Exchange] {
        guard FileManager.default.fileExists(atPath: conversationsFile.path) else {
            return []
        }

        do {
            let content = try String(contentsOf: conversationsFile, encoding: .utf8)
            let lines = content.components(separatedBy: "\n").filter { !$0.isEmpty }

            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601

            var results: [Exchange] = []
            let lowerQuery = query.lowercased()

            for line in lines.reversed() {  // Search most recent first
                if let data = line.data(using: .utf8),
                   let exchange = try? decoder.decode(Exchange.self, from: data) {
                    if exchange.user.lowercased().contains(lowerQuery) ||
                       exchange.assistant.lowercased().contains(lowerQuery) {
                        results.append(exchange)
                        if results.count >= limit {
                            break
                        }
                    }
                }
            }

            return results
        } catch {
            NSLog("[MemoryService] Failed to search conversations: \(error)")
            return []
        }
    }

    /// Get conversation statistics
    func getStats() -> (total: Int, last24Hours: Int) {
        guard FileManager.default.fileExists(atPath: conversationsFile.path) else {
            return (0, 0)
        }

        do {
            let content = try String(contentsOf: conversationsFile, encoding: .utf8)
            let lines = content.components(separatedBy: "\n").filter { !$0.isEmpty }
            let total = lines.count

            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601

            let yesterday = Date().addingTimeInterval(-24 * 3600)
            var last24Hours = 0

            for line in lines.reversed() {
                if let data = line.data(using: .utf8),
                   let exchange = try? decoder.decode(Exchange.self, from: data) {
                    if exchange.timestamp >= yesterday {
                        last24Hours += 1
                    } else {
                        break  // Older than 24h, stop counting
                    }
                }
            }

            return (total, last24Hours)
        } catch {
            NSLog("[MemoryService] Failed to get stats: \(error)")
            return (0, 0)
        }
    }

    func getContextForLLM() -> String {
        // Read identity, rules, soul from iCloud (persistent across devices)
        let identity = (try? String(contentsOf: identityFile)) ?? "Quinn - Charlie's voice assistant"
        let rules = (try? String(contentsOf: rulesFile)) ?? ""
        let soul = (try? String(contentsOf: soulFile)) ?? ""

        // Read context from local cache
        let context = (try? String(contentsOf: contextFile)) ?? ""

        // Format working memory
        let conversationHistory = workingMemory.map { exchange in
            "User: \(exchange.user)\nAssistant: \(exchange.assistant)"
        }.joined(separator: "\n\n")

        return """
        # Who I Am
        \(identity)

        # Operating Rules
        \(rules)

        # My Purpose
        \(soul)

        # Context About Charlie and Projects
        \(context)

        # Recent Conversation
        \(conversationHistory)
        """
    }

    func clearWorkingMemory() {
        workingMemory.removeAll()
    }

    // MARK: - Persistent Memory

    private func logConversation(_ exchange: Exchange) {
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(exchange)

            if let jsonString = String(data: data, encoding: .utf8) {
                let line = jsonString + "\n"

                if FileManager.default.fileExists(atPath: conversationsFile.path) {
                    let fileHandle = try FileHandle(forWritingTo: conversationsFile)
                    fileHandle.seekToEndOfFile()
                    fileHandle.write(line.data(using: .utf8)!)
                    fileHandle.closeFile()
                } else {
                    try line.write(to: conversationsFile, atomically: true, encoding: .utf8)
                }
            }

            updateMemorySize()
            checkAndCleanIfNeeded()
        } catch {
            print("[Memory] Failed to log conversation: \(error)")
        }
    }

    // MARK: - Memory Management

    func updateMemorySize() {
        do {
            let conversationsSize = try conversationsFile.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            memorySizeMB = Double(conversationsSize) / 1_000_000.0
        } catch {
            memorySizeMB = 0.0
        }
    }

    private func checkAndCleanIfNeeded() {
        guard config.auto_clean else { return }

        let budgetMB = Double(config.memory_budget_mb)

        if memorySizeMB > budgetMB * 0.9 {
            Task {
                await cleanMemory()
            }
        }
    }

    func cleanMemory() async {
        print("[Memory] Cleaning memory (current: \(String(format: "%.1f", memorySizeMB))MB, budget: \(config.memory_budget_mb)MB)")

        // Read all conversations
        guard let fileContents = try? String(contentsOf: conversationsFile) else { return }

        let lines = fileContents.components(separatedBy: "\n").filter { !$0.isEmpty }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        var exchanges: [Exchange] = []
        for line in lines {
            if let data = line.data(using: .utf8),
               let exchange = try? decoder.decode(Exchange.self, from: data) {
                exchanges.append(exchange)
            }
        }

        // Keep only exchanges from last N days
        let cutoffDate = Date().addingTimeInterval(-Double(config.conversation_retention_days) * 86400)
        let filtered = exchanges.filter { $0.timestamp > cutoffDate }

        // Rewrite file
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601

            var newContent = ""
            for exchange in filtered {
                if let data = try? encoder.encode(exchange),
                   let jsonString = String(data: data, encoding: .utf8) {
                    newContent += jsonString + "\n"
                }
            }

            try newContent.write(to: conversationsFile, atomically: true, encoding: .utf8)

            updateMemorySize()
            print("[Memory] Cleaned: removed \(lines.count - filtered.count) old conversations, now \(String(format: "%.1f", memorySizeMB))MB")
        } catch {
            print("[Memory] Failed to clean: \(error)")
        }
    }

    // MARK: - Configuration

    func updateConfig(_ newConfig: MemoryConfig) {
        config = newConfig

        do {
            let data = try JSONEncoder().encode(config)
            try data.write(to: configFile)
        } catch {
            print("[Memory] Failed to save config: \(error)")
        }
    }

    func getConfig() -> MemoryConfig {
        return config
    }
}
