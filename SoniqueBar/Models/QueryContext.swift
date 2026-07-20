import Foundation

/// Context for LLM query routing and tier selection
struct QueryContext {
    /// Force a specific tier (overrides automatic detection)
    var forceTier: QueryTier?

    /// Are MCP tools available for this query?
    var mcpToolsAvailable: Bool

    /// Is this a retry after an unsatisfactory response?
    var isRetry: Bool

    /// Previous tier used (for tracking escalations)
    var previousTier: QueryTier?

    /// Session conversation length (affects context needs)
    var conversationLength: Int

    init(
        forceTier: QueryTier? = nil,
        mcpToolsAvailable: Bool = true,
        isRetry: Bool = false,
        previousTier: QueryTier? = nil,
        conversationLength: Int = 0
    ) {
        self.forceTier = forceTier
        self.mcpToolsAvailable = mcpToolsAvailable
        self.isRetry = isRetry
        self.previousTier = previousTier
        self.conversationLength = conversationLength
    }
}

/// Query complexity tiers for automatic escalation
enum QueryTier: String, Codable, CaseIterable {
    case conversational  // Fast, cheap models (Haiku, Ollama Qwen)
    case thinking        // Medium reasoning (Sonnet, DeepSeek-R1)
    case tools           // Complex with tool use (Opus, Claude with MCP)

    var displayName: String {
        switch self {
        case .conversational: return "Conversational"
        case .thinking: return "Thinking"
        case .tools: return "Tools & Complex"
        }
    }

    /// Can escalate to this tier from current?
    func canEscalateTo(_ target: QueryTier) -> Bool {
        let order: [QueryTier] = [.conversational, .thinking, .tools]
        guard let currentIndex = order.firstIndex(of: self),
              let targetIndex = order.firstIndex(of: target) else {
            return false
        }
        return targetIndex > currentIndex
    }
}
