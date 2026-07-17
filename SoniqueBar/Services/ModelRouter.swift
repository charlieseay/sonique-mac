import Foundation
import os.log

/// Configurable model router for SoniqueBar
/// Supports single or tiered routing with local/subscription models
/// Configured via JSON file, no code changes required
struct ModelRouterConfig: Codable {
    var mode: RoutingMode
    var defaultProvider: ProviderConfig
    var tieredProviders: TieredProviders?

    enum RoutingMode: String, Codable {
        case single      // Use defaultProvider for all queries
        case tiered      // Route by complexity (simple/medium/complex)
    }

    struct TieredProviders: Codable {
        var simple: ProviderConfig
        var medium: ProviderConfig
        var complex: ProviderConfig
    }
}

struct ProviderConfig: Codable {
    var type: ProviderType
    var endpoint: String?      // For API/Ollama
    var model: String?          // Model name
    var apiKey: String?         // For API providers
    var cliCommand: String?     // For CLI providers
    var timeout: Double?        // Request timeout

    enum ProviderType: String, Codable {
        case claudeAPI       // Anthropic API
        case claudeCLI       // claude CLI (subscription)
        case geminiAPI       // Google Gemini API
        case geminiCLI       // gemini CLI (subscription)
        case openaiAPI       // OpenAI API
        case ollama          // Local Ollama
        case bedrock         // AWS Bedrock
    }
}

@MainActor
class ModelRouter {
    static let shared = ModelRouter()

    private let logger = Logger(subsystem: "com.seayniclabs.soniquebar", category: "ModelRouter")
    private var config: ModelRouterConfig

    // Complexity classification patterns
    private let complexPatterns = [
        "why", "explain", "analyze", "summar", "write.*email", "write.*message",
        "draft", "create.*document", "what.s the difference", "compare",
        "advise", "should i", "what should", "how (do|can|would)", "tell me about"
    ]

    private let mediumPatterns = [
        "then", "after (that|you|it)", "before.*(you|it|that)",
        "and also", "as well as", "if.*then", "all (the )?(lights|doors|cameras|devices)"
    ]

    private init() {
        // Load config from file or use defaults
        if let config = Self.loadConfig() {
            self.config = config
            logger.info("[ModelRouter] Loaded config: \(config.mode.rawValue) mode")
        } else {
            // Default: Claude CLI (current behavior)
            self.config = ModelRouterConfig(
                mode: .single,
                defaultProvider: ProviderConfig(
                    type: .claudeCLI,
                    endpoint: nil,
                    model: "sonnet",
                    apiKey: nil,
                    cliCommand: "/opt/homebrew/bin/claude",
                    timeout: 30.0
                ),
                tieredProviders: nil
            )
            logger.info("[ModelRouter] Using default config (Claude CLI)")
        }
    }

    /// Route a prompt to the appropriate provider
    func route(prompt: String) async throws -> String {
        let tier = classifyComplexity(prompt)
        let provider: ProviderConfig

        switch config.mode {
        case .single:
            provider = config.defaultProvider
            logger.info("[ModelRouter] Single mode → \(provider.type.rawValue)")

        case .tiered:
            guard let tiered = config.tieredProviders else {
                throw RouterError.invalidConfig("Tiered mode enabled but no tier config")
            }

            switch tier {
            case .simple:
                provider = tiered.simple
            case .medium:
                provider = tiered.medium
            case .complex:
                provider = tiered.complex
            }

            logger.info("[ModelRouter] Tiered mode → \(tier) → \(provider.type.rawValue)")
        }

        return try await callProvider(provider: provider, prompt: prompt)
    }

    /// Classify prompt complexity
    private func classifyComplexity(_ prompt: String) -> Complexity {
        let lower = prompt.lowercased()

        // Check complex patterns
        for pattern in complexPatterns {
            if lower.range(of: pattern, options: .regularExpression) != nil {
                return .complex
            }
        }

        // Check medium patterns
        for pattern in mediumPatterns {
            if lower.range(of: pattern, options: .regularExpression) != nil {
                return .medium
            }
        }

        return .simple
    }

    /// Call the selected provider
    private func callProvider(provider: ProviderConfig, prompt: String) async throws -> String {
        let timeout = provider.timeout ?? 30.0

        switch provider.type {
        case .claudeCLI, .geminiCLI:
            return try await callCLI(provider: provider, prompt: prompt, timeout: timeout)

        case .ollama:
            return try await callOllama(provider: provider, prompt: prompt, timeout: timeout)

        case .claudeAPI, .geminiAPI, .openaiAPI:
            return try await callAPI(provider: provider, prompt: prompt, timeout: timeout)

        case .bedrock:
            return try await callBedrock(provider: provider, prompt: prompt, timeout: timeout)
        }
    }

    /// Call CLI-based provider (claude, gemini, etc.)
    private func callCLI(provider: ProviderConfig, prompt: String, timeout: Double) async throws -> String {
        guard let command = provider.cliCommand else {
            throw RouterError.missingConfig("CLI command not specified")
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: command)
        process.arguments = ["-p", prompt]

        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        return try await withCheckedThrowingContinuation { continuation in
            let timer = Timer.scheduledTimer(withTimeInterval: timeout, repeats: false) { _ in
                process.terminate()
                continuation.resume(throwing: RouterError.timeout("CLI call timed out"))
            }

            process.terminationHandler = { process in
                timer.invalidate()

                let output = String(data: outputPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                let error = String(data: errorPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""

                if process.terminationStatus == 0 {
                    continuation.resume(returning: output.trimmingCharacters(in: .whitespacesAndNewlines))
                } else {
                    continuation.resume(throwing: RouterError.executionFailed("CLI failed: \(error)"))
                }
            }

            do {
                try process.run()
            } catch {
                timer.invalidate()
                continuation.resume(throwing: error)
            }
        }
    }

    /// Call Ollama endpoint
    private func callOllama(provider: ProviderConfig, prompt: String, timeout: Double) async throws -> String {
        guard let endpoint = provider.endpoint else {
            throw RouterError.missingConfig("Ollama endpoint not specified")
        }
        guard let model = provider.model else {
            throw RouterError.missingConfig("Ollama model not specified")
        }

        let url = URL(string: "\(endpoint)/api/generate")!
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: Any] = [
            "model": model,
            "prompt": prompt,
            "stream": false
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            throw RouterError.executionFailed("Ollama request failed")
        }

        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard let responseText = json?["response"] as? String else {
            throw RouterError.executionFailed("Invalid Ollama response")
        }

        return responseText
    }

    /// Call API-based provider (OpenAI-compatible)
    private func callAPI(provider: ProviderConfig, prompt: String, timeout: Double) async throws -> String {
        guard let endpoint = provider.endpoint else {
            throw RouterError.missingConfig("API endpoint not specified")
        }
        guard let apiKey = provider.apiKey else {
            throw RouterError.missingConfig("API key not specified")
        }
        guard let model = provider.model else {
            throw RouterError.missingConfig("Model not specified")
        }

        let url = URL(string: "\(endpoint)/v1/chat/completions")!
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        let body: [String: Any] = [
            "model": model,
            "messages": [
                ["role": "user", "content": prompt]
            ]
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            throw RouterError.executionFailed("API request failed")
        }

        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard let choices = json?["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              let content = message["content"] as? String else {
            throw RouterError.executionFailed("Invalid API response")
        }

        return content
    }

    /// Call AWS Bedrock
    private func callBedrock(provider: ProviderConfig, prompt: String, timeout: Double) async throws -> String {
        // Delegate to ask_claude_bedrock CLI
        return try await callCLI(
            provider: ProviderConfig(
                type: .claudeCLI,
                endpoint: nil,
                model: nil,
                apiKey: nil,
                cliCommand: "/usr/local/bin/ask_claude_bedrock",
                timeout: timeout
            ),
            prompt: prompt,
            timeout: timeout
        )
    }

    // MARK: - Config Management

    private static func loadConfig() -> ModelRouterConfig? {
        let configPath = "/Volumes/data/secrets/sonique_model_router.json"

        guard let data = try? Data(contentsOf: URL(fileURLWithPath: configPath)) else {
            return nil
        }

        return try? JSONDecoder().decode(ModelRouterConfig.self, from: data)
    }

    static func saveConfig(_ config: ModelRouterConfig) throws {
        let configPath = "/Volumes/data/secrets/sonique_model_router.json"
        let data = try JSONEncoder().encode(config)
        try data.write(to: URL(fileURLWithPath: configPath))
    }

    enum Complexity {
        case simple, medium, complex
    }

    enum RouterError: LocalizedError {
        case invalidConfig(String)
        case missingConfig(String)
        case executionFailed(String)
        case timeout(String)

        var errorDescription: String? {
            switch self {
            case .invalidConfig(let msg), .missingConfig(let msg),
                 .executionFailed(let msg), .timeout(let msg):
                return msg
            }
        }
    }
}
