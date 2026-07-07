import Foundation

// MARK: - MCP Tool Types

/// A single tool definition to inject into an LLM API request (Anthropic tools format).
struct MCPToolDefinition: Codable, Sendable {
    let name: String
    let description: String
    let inputSchema: [String: Any]

    enum CodingKeys: String, CodingKey {
        case name, description
        case inputSchema = "input_schema"
    }

    init(name: String, description: String, inputSchema: [String: Any]) {
        self.name = name
        self.description = description
        self.inputSchema = inputSchema
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(name, forKey: .name)
        try container.encode(description, forKey: .description)
        let schemaData = try JSONSerialization.data(withJSONObject: inputSchema)
        let schemaAny = try JSONDecoder().decode(AnyCodable.self, from: schemaData)
        try container.encode(schemaAny, forKey: .inputSchema)
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        description = try container.decode(String.self, forKey: .description)
        let schemaAny = try container.decode(AnyCodable.self, forKey: .inputSchema)
        inputSchema = (schemaAny.value as? [String: Any]) ?? [:]
    }

    /// Returns JSON-serialisable representation for embedding in API payloads.
    func toJSONObject() -> [String: Any] {
        [
            "name": name,
            "description": description,
            "input_schema": inputSchema
        ]
    }
}

/// Type-erased Codable wrapper for arbitrary JSON values.
struct AnyCodable: Codable {
    let value: Any

    init(_ value: Any) { self.value = value }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let intVal = try? container.decode(Int.self) { value = intVal }
        else if let doubleVal = try? container.decode(Double.self) { value = doubleVal }
        else if let boolVal = try? container.decode(Bool.self) { value = boolVal }
        else if let stringVal = try? container.decode(String.self) { value = stringVal }
        else if let arrayVal = try? container.decode([AnyCodable].self) { value = arrayVal.map { $0.value } }
        else if let dictVal = try? container.decode([String: AnyCodable].self) { value = dictVal.mapValues { $0.value } }
        else { value = NSNull() }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch value {
        case let v as Int: try container.encode(v)
        case let v as Double: try container.encode(v)
        case let v as Bool: try container.encode(v)
        case let v as String: try container.encode(v)
        case let v as [Any]:
            try container.encode(v.map { AnyCodable($0) })
        case let v as [String: Any]:
            try container.encode(v.mapValues { AnyCodable($0) })
        default: try container.encodeNil()
        }
    }
}

/// A tool call returned by the LLM in a tool-use response.
struct LLMToolCall: Sendable {
    let id: String
    let toolName: String
    let input: [String: Any]
}

/// Result of an LLM completion that may include tool calls.
enum LLMCompletionResult: Sendable {
    case text(String)
    case toolCalls([LLMToolCall])
}

// MARK: - Canonical P1 MCP Tool Schemas

/// Hard-coded, validated schemas for the three P1 MCP tools.
/// Using fixed schemas avoids Anthropic API rejections from malformed dynamic schemas.
enum MCPToolSchemas {

    static let slackPostMessage = MCPToolDefinition(
        name: "mcp__Slack__slack_post_message",
        description: "Post a message to a Slack channel. Use for commands like 'send a message to #lab saying X' or 'tell the lab X'.",
        inputSchema: [
            "type": "object",
            "properties": [
                "channel_id": [
                    "type": "string",
                    "description": "Slack channel ID (e.g. C1234567890). Resolve from channel name using slack_list_channels if needed."
                ],
                "text": [
                    "type": "string",
                    "description": "The message text to post."
                ]
            ],
            "required": ["channel_id", "text"]
        ]
    )

    static let vaultSearch = MCPToolDefinition(
        name: "vault_search",
        description: "Search the Obsidian vault (SeaynicNet) for notes matching a query. Use when the user asks to search, find, or read vault notes.",
        inputSchema: [
            "type": "object",
            "properties": [
                "query": [
                    "type": "string",
                    "description": "The search term or topic to find in the vault."
                ]
            ],
            "required": ["query"]
        ]
    )

    static let notebooklmQuery = MCPToolDefinition(
        name: "notebooklm_query",
        description: "Query a NotebookLM notebook. Use when the user asks to query NotebookLM or asks a research question that should be answered from their notebooks.",
        inputSchema: [
            "type": "object",
            "properties": [
                "query": [
                    "type": "string",
                    "description": "The question or topic to query in NotebookLM."
                ]
            ],
            "required": ["query"]
        ]
    )

    /// All three P1 tools as an array for API injection.
    static let all: [MCPToolDefinition] = [slackPostMessage, vaultSearch, notebooklmQuery]

    /// Returns all tools as JSON-serialisable objects ready for Anthropic API `tools` array.
    static func allAsJSONObjects() -> [[String: Any]] {
        all.map { $0.toJSONObject() }
    }
}

// MARK: - LLMProvider Protocol

/// Protocol for LLM providers.
/// Allows Quinn to switch between Claude, OpenAI, Gemini, etc.
protocol LLMProvider: Sendable {
    var name: String { get }
    var availableModels: [String] { get }
    var supportsStreaming: Bool { get }

    /// Generate a completion
    func complete(prompt: String, model: String?) async throws -> String

    /// Generate a completion with tool-use support.
    /// Returns either a text response or a list of tool calls the LLM wants to execute.
    func completeWithTools(
        prompt: String,
        systemPrompt: String?,
        tools: [MCPToolDefinition],
        model: String?
    ) async throws -> LLMCompletionResult

    /// Generate a streaming completion
    func completeStreaming(prompt: String, model: String?) async throws -> AsyncThrowingStream<String, Error>

    /// Check if provider is available and authenticated
    func healthCheck() async -> Bool
}

/// Result from LLM completion
struct LLMResult {
    let text: String
    let model: String
    let tokenCount: Int?
    let latencyMs: Int
}

/// LLM Provider errors
enum LLMError: Error, LocalizedError {
    case notAvailable
    case authenticationFailed
    case invalidModel(String)
    case timeout
    case rateLimitExceeded
    case networkError(String)
    case invalidResponse(String)

    var errorDescription: String? {
        switch self {
        case .notAvailable:
            return "LLM provider not available"
        case .authenticationFailed:
            return "Authentication failed"
        case .invalidModel(let model):
            return "Invalid model: \(model)"
        case .timeout:
            return "Request timed out"
        case .rateLimitExceeded:
            return "Rate limit exceeded"
        case .networkError(let message):
            return "Network error: \(message)"
        case .invalidResponse(let message):
            return "Invalid response: \(message)"
        }
    }
}

// MARK: - Default implementations

extension LLMProvider {
    /// Default: fall back to plain text completion (tools ignored).
    func completeWithTools(
        prompt: String,
        systemPrompt: String?,
        tools: [MCPToolDefinition],
        model: String?
    ) async throws -> LLMCompletionResult {
        let combined = systemPrompt.map { "\($0)\n\n\(prompt)" } ?? prompt
        return .text(try await complete(prompt: combined, model: model))
    }
}

/// Router for selecting the best LLM provider
@MainActor
class LLMRouter: ObservableObject {
    static let shared = LLMRouter()

    @Published private(set) var providers: [any LLMProvider] = []
    @Published var defaultProvider: String = "claude"
    @Published var defaultModel: [String: String] = [
        "claude": "haiku",
        "openai": "gpt-4",
        "gemini": "gemini-pro"
    ]

    private init() {
        registerProviders()
    }

    private func registerProviders() {
        providers = [
            ClaudeProvider(),
            GeminiProvider(),
            OpenAIProvider(),
            NVIDIAProvider()
        ]
    }

    /// Get provider by name
    func getProvider(_ name: String) -> (any LLMProvider)? {
        providers.first { $0.name.lowercased() == name.lowercased() }
    }

    /// Complete with default provider
    func complete(prompt: String, preferredModel: String? = nil) async throws -> String {
        guard let provider = getProvider(defaultProvider) else {
            throw LLMError.notAvailable
        }

        let model = preferredModel ?? defaultModel[defaultProvider]
        return try await provider.complete(prompt: prompt, model: model)
    }

    /// Complete with specific provider
    func complete(prompt: String, provider providerName: String, model: String? = nil) async throws -> String {
        guard let provider = getProvider(providerName) else {
            throw LLMError.notAvailable
        }

        let selectedModel = model ?? defaultModel[providerName]
        return try await provider.complete(prompt: prompt, model: selectedModel)
    }

    /// Health check all providers
    func healthCheckAll() async -> [String: Bool] {
        var results: [String: Bool] = [:]

        for provider in providers {
            let healthy = await provider.healthCheck()
            results[provider.name] = healthy
        }

        return results
    }
}
