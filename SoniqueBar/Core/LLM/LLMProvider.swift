import Foundation

/// Protocol for LLM providers
/// Allows Quinn to switch between Claude, OpenAI, Gemini, etc.
protocol LLMProvider: Sendable {
    var name: String { get }
    var availableModels: [String] { get }
    var supportsStreaming: Bool { get }

    /// Generate a completion
    func complete(prompt: String, model: String?) async throws -> String

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
