import Foundation
import os.log

// MARK: - Query Context and Tiers

/// Context for LLM query routing and tier selection
struct QueryContext {
    var forceTier: QueryTier?
    var mcpToolsAvailable: Bool
    var isRetry: Bool
    var previousTier: QueryTier?
    var conversationLength: Int
    var originalQuery: String?  // ← Raw user query for tier classification

    init(
        forceTier: QueryTier? = nil,
        mcpToolsAvailable: Bool = true,
        isRetry: Bool = false,
        previousTier: QueryTier? = nil,
        conversationLength: Int = 0,
        originalQuery: String? = nil
    ) {
        self.forceTier = forceTier
        self.mcpToolsAvailable = mcpToolsAvailable
        self.isRetry = isRetry
        self.previousTier = previousTier
        self.conversationLength = conversationLength
        self.originalQuery = originalQuery
    }
}

/// Query complexity tiers for automatic escalation
enum QueryTier: String, Codable, CaseIterable {
    case conversational
    case thinking
    case tools

    var displayName: String {
        switch self {
        case .conversational: return "Conversational"
        case .thinking: return "Thinking"
        case .tools: return "Tools & Complex"
        }
    }
}

// MARK: - Model Router

@MainActor
class ModelRouter {
    static let shared = ModelRouter()

    private let logger = Logger(subsystem: "com.seayniclabs.soniquebar", category: "ModelRouter")
    private var config: RouterConfig
    private var providerCache: [String: ProviderHealth] = [:]

    private let thinkingKeywords = [
        "explain", "why", "analyze", "summar", "tell me about", "what.s the difference",
        "compare", "research", "describe", "how does", "what causes"
    ]

    private let toolsKeywords = [
        "create task", "add reminder", "send message", "search vault", "docker",
        "helmsman", "slack", "github", "file search", "check helmsman",
        "list files", "read file", "what files", "show me files"
    ]

    private let uncertaintyPhrases = [
        "I don't have current information",
        "My knowledge cutoff",
        "I'm not sure",
        "I cannot",
        "I don't know"
    ]

    private init() {
        if let loaded = Self.loadConfig() {
            self.config = loaded
            logger.info("[ModelRouter] Loaded config: \(loaded.mode.rawValue)")
        } else {
            // Default: Ollama local
            self.config = RouterConfig(
                mode: .adaptive,
                providers: [:],
                escalation: EscalationConfig(),
                tts: TTSConfig(primary: "system", fallbackChain: ["system"])
            )
            logger.info("[ModelRouter] Using default config")
        }
    }

    /// Main routing entry point with automatic tier escalation
    func route(prompt: String, context: QueryContext? = nil) async throws -> RouterResponse {
        NSLog("[ModelRouter] route() called with prompt length: \(prompt.count)")
        let startTime = Date()
        let tier = determineTier(prompt: prompt, context: context)
        NSLog("[ModelRouter] Determined tier: \(tier.rawValue)")
        logger.info("[Router] Query tier: \(tier.rawValue)")

        let providers = getProvidersForTier(tier)
        NSLog("[ModelRouter] Got \(providers.count) providers for tier \(tier.rawValue)")
        guard !providers.isEmpty else {
            NSLog("[ModelRouter] ❌ ERROR: noProvidersAvailable for tier \(tier.rawValue)")
            throw RouterError.noProvidersAvailable
        }

        var lastError: Error?
        for provider in providers {
            do {
                let response = try await callProvider(provider, prompt: prompt, tier: tier)

                // Check if escalation needed
                if config.escalation.enabled,
                   tier != .tools,
                   shouldEscalate(response.text, currentTier: tier) {
                    logger.info("[Router] Escalating from \(tier.rawValue) to tools tier")
                    let escalatedContext = QueryContext(
                        forceTier: .tools,
                        mcpToolsAvailable: context?.mcpToolsAvailable ?? true,
                        isRetry: true,
                        previousTier: tier,
                        conversationLength: context?.conversationLength ?? 0
                    )
                    return try await route(prompt: prompt, context: escalatedContext)
                }

                let elapsed = Date().timeIntervalSince(startTime)
                logger.info("[Router] ✓ \(provider.name) responded in \(String(format: "%.2f", elapsed))s")

                return RouterResponse(
                    text: response.text,
                    provider: provider.name,
                    tier: tier,
                    latency: elapsed,
                    wasEscalated: context?.isRetry ?? false
                )

            } catch {
                logger.warning("[Router] \(provider.name) failed: \(error.localizedDescription)")
                lastError = error
                updateProviderHealth(provider.name, healthy: false)
                continue
            }
        }

        throw lastError ?? RouterError.allProvidersFailed
    }

    private func determineTier(prompt: String, context: QueryContext?) -> QueryTier {
        if let forced = context?.forceTier {
            return forced
        }

        // Use the original raw query for classification (not the full prompt with memory/context)
        let textToClassify = context?.originalQuery ?? prompt
        let lower = textToClassify.lowercased()

        if toolsKeywords.contains(where: { lower.contains($0) }) {
            return .tools
        }

        if context?.mcpToolsAvailable == true,
           (lower.contains("create") || lower.contains("send") || lower.contains("search")) {
            return .tools
        }

        if thinkingKeywords.contains(where: { lower.contains($0) }) {
            return .thinking
        }

        return .conversational
    }

    private func shouldEscalate(_ response: String, currentTier: QueryTier) -> Bool {
        guard config.escalation.responseUnsatisfactory ?? true else { return false }
        return uncertaintyPhrases.contains(where: { response.contains($0) })
    }

    private func getProvidersForTier(_ tier: QueryTier) -> [ProviderInfo] {
        var providers: [ProviderInfo] = []

        for (name, providerConfig) in config.providers {
            guard providerConfig.enabled else {
                logger.info("[getProvidersForTier] Skipping disabled provider: \(name)")
                continue
            }

            // Try to get model for tier
            let model = providerConfig.models[tier] ?? providerConfig.models[.conversational]
            guard let model else {
                logger.warning("[getProvidersForTier] No model found for \(name) at tier \(tier.rawValue)")
                logger.warning("[getProvidersForTier] Available models for \(name): \(providerConfig.models)")
                continue
            }

            logger.info("[getProvidersForTier] Adding provider \(name) with model \(model) for tier \(tier.rawValue)")
            providers.append(ProviderInfo(
                name: name,
                config: providerConfig,
                model: model,
                tier: tier
            ))
        }

        let sorted = providers.sorted { $0.config.priority < $1.config.priority }
        logger.info("[getProvidersForTier] Returning \(sorted.count) providers for tier \(tier.rawValue)")
        return sorted
    }

    private func callProvider(_ provider: ProviderInfo, prompt: String, tier: QueryTier) async throws -> ProviderResult {
        let timeout = provider.config.timeout

        switch provider.config.type {
        case .ollama:
            return try await callOllama(provider: provider, prompt: prompt, timeout: timeout)
        case .claudeCLI:
            return try await callClaudeCLI(provider: provider, prompt: prompt, timeout: timeout)
        case .geminiCLI:
            return try await callGeminiCLI(provider: provider, prompt: prompt, timeout: timeout)
        case .bedrock:
            return try await callBedrock(provider: provider, prompt: prompt, timeout: timeout)
        case .openaiAPI:
            return try await callOpenAI(provider: provider, prompt: prompt, timeout: timeout)
        case .nvidiaAPI:
            return try await callNVIDIA(provider: provider, prompt: prompt, timeout: timeout)
        case .bash:
            return try await callBash(provider: provider, prompt: prompt, timeout: timeout)
        case .custom:
            return try await callCustom(provider: provider, prompt: prompt, timeout: timeout)
        }
    }

    // MARK: - Provider Implementations

    private func callOllama(provider: ProviderInfo, prompt: String, timeout: Double) async throws -> ProviderResult {
        guard let endpoint = provider.config.endpoint else {
            throw RouterError.missingConfig("Ollama endpoint not specified")
        }

        // Use OpenAI-compatible API for better compatibility
        let url = URL(string: "\(endpoint)/v1/chat/completions")!
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        // Split prompt into system context and user query
        var systemContent = ""
        var userContent = prompt

        if let userIndex = prompt.range(of: "\n\nUser: ", options: .backwards) {
            systemContent = String(prompt[..<userIndex.lowerBound])
            userContent = String(prompt[userIndex.upperBound...])
        }

        var messages: [[String: String]] = []
        if !systemContent.isEmpty {
            messages.append(["role": "system", "content": systemContent])
        }
        messages.append(["role": "user", "content": userContent])

        let body: [String: Any] = [
            "model": provider.model,
            "messages": messages,
            "stream": false
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            throw RouterError.executionFailed("Ollama HTTP \((response as? HTTPURLResponse)?.statusCode ?? -1)")
        }

        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard let choices = json?["choices"] as? [[String: Any]],
              let firstChoice = choices.first,
              let message = firstChoice["message"] as? [String: Any],
              let content = message["content"] as? String else {
            throw RouterError.executionFailed("Invalid Ollama response format")
        }

        updateProviderHealth(provider.name, healthy: true)
        return ProviderResult(text: content)
    }

    private func callClaudeCLI(provider: ProviderInfo, prompt: String, timeout: Double) async throws -> ProviderResult {
        guard let command = provider.config.cliCommand else {
            throw RouterError.missingConfig("Claude CLI command not specified")
        }

        return try await callCLI(
            command: command,
            args: ["--model", provider.model, "-p", prompt],
            timeout: timeout,
            providerName: provider.name
        )
    }

    private func callGeminiCLI(provider: ProviderInfo, prompt: String, timeout: Double) async throws -> ProviderResult {
        guard let command = provider.config.cliCommand else {
            throw RouterError.missingConfig("Gemini CLI command not specified")
        }

        return try await callCLI(
            command: command,
            args: ["--model", provider.model, "-p", prompt],
            timeout: timeout,
            providerName: provider.name
        )
    }

    private func callBedrock(provider: ProviderInfo, prompt: String, timeout: Double) async throws -> ProviderResult {
        return try await callCLI(
            command: "/usr/local/bin/ask_claude_bedrock",
            args: ["-p", prompt],
            timeout: timeout,
            providerName: provider.name
        )
    }

    private func callBash(provider: ProviderInfo, prompt: String, timeout: Double) async throws -> ProviderResult {
        guard let command = provider.config.cliCommand else {
            throw RouterError.missingConfig("Bash command not specified")
        }

        // Bash tools don't use the full prompt - they expect specific commands
        // This is a simplified execution - the actual tool dispatch happens in IntentRouter
        return try await callCLI(
            command: command,
            args: [prompt],
            timeout: timeout,
            providerName: provider.name
        )
    }

    private func callOpenAI(provider: ProviderInfo, prompt: String, timeout: Double) async throws -> ProviderResult {
        guard let endpoint = provider.config.endpoint,
              let apiKey = provider.config.apiKey else {
            throw RouterError.missingConfig("OpenAI endpoint or API key missing")
        }

        let url = URL(string: "\(endpoint)/v1/chat/completions")!
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        let body: [String: Any] = [
            "model": provider.model,
            "messages": [["role": "user", "content": prompt]]
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            throw RouterError.executionFailed("OpenAI HTTP \((response as? HTTPURLResponse)?.statusCode ?? -1)")
        }

        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard let choices = json?["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              let content = message["content"] as? String else {
            throw RouterError.executionFailed("Invalid OpenAI response format")
        }

        updateProviderHealth(provider.name, healthy: true)
        return ProviderResult(text: content)
    }

    private func callNVIDIA(provider: ProviderInfo, prompt: String, timeout: Double) async throws -> ProviderResult {
        return try await callCLI(
            command: "/usr/local/bin/ask_llm",
            args: ["--lane", provider.model, "-p", prompt],
            timeout: timeout,
            providerName: provider.name
        )
    }

    private func callCustom(provider: ProviderInfo, prompt: String, timeout: Double) async throws -> ProviderResult {
        guard let endpoint = provider.config.endpoint else {
            throw RouterError.missingConfig("Custom endpoint not specified")
        }

        let url = URL(string: "\(endpoint)/v1/chat/completions")!
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        if let apiKey = provider.config.apiKey {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }

        let body: [String: Any] = [
            "model": provider.model,
            "messages": [["role": "user", "content": prompt]]
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            throw RouterError.executionFailed("Custom API HTTP \((response as? HTTPURLResponse)?.statusCode ?? -1)")
        }

        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard let choices = json?["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              let content = message["content"] as? String else {
            throw RouterError.executionFailed("Invalid custom API response format")
        }

        updateProviderHealth(provider.name, healthy: true)
        return ProviderResult(text: content)
    }

    private func callCLI(command: String, args: [String], timeout: Double, providerName: String) async throws -> ProviderResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: command)
        process.arguments = args

        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
        process.environment = env

        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        return try await withCheckedThrowingContinuation { continuation in
            var didComplete = false

            let timer = Timer.scheduledTimer(withTimeInterval: timeout, repeats: false) { _ in
                guard !didComplete else { return }
                didComplete = true
                process.terminate()
                continuation.resume(throwing: RouterError.timeout("CLI timed out after \(timeout)s"))
            }

            process.terminationHandler = { process in
                guard !didComplete else { return }
                didComplete = true
                timer.invalidate()

                let output = String(data: outputPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                let error = String(data: errorPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""

                if process.terminationStatus == 0 {
                    continuation.resume(returning: ProviderResult(text: output.trimmingCharacters(in: .whitespacesAndNewlines)))
                } else {
                    continuation.resume(throwing: RouterError.executionFailed("CLI failed: \(error)"))
                }
            }

            do {
                try process.run()
            } catch {
                guard !didComplete else { return }
                didComplete = true
                timer.invalidate()
                continuation.resume(throwing: error)
            }
        }
    }

    private func updateProviderHealth(_ name: String, healthy: Bool) {
        let existing = providerCache[name] ?? ProviderHealth(name: name)
        var updated = existing

        if healthy {
            updated.consecutiveFailures = 0
            updated.lastSuccess = Date()
        } else {
            updated.consecutiveFailures += 1
            updated.lastFailure = Date()
        }

        providerCache[name] = updated
    }

    private static func loadConfig() -> RouterConfig? {
        let path = "/Volumes/data/secrets/sonique_model_router.json"
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else {
            NSLog("[ModelRouter] ❌ Failed to read config at \(path)")
            return nil
        }

        do {
            let config = try JSONDecoder().decode(RouterConfig.self, from: data)
            NSLog("[ModelRouter] ✓ Config loaded: \(config.providers.count) providers")
            for (name, provider) in config.providers {
                NSLog("[ModelRouter]   - \(name): enabled=\(provider.enabled), models=\(provider.models)")
            }
            return config
        } catch {
            NSLog("[ModelRouter] ❌ Failed to decode config: \(error)")
            return nil
        }
    }

    enum RouterError: Error {
        case noProvidersAvailable
        case allProvidersFailed
        case missingConfig(String)
        case executionFailed(String)
        case timeout(String)
    }
}

// MARK: - Supporting Types

struct RouterResponse {
    let text: String
    let provider: String
    let tier: QueryTier
    let latency: TimeInterval
    let wasEscalated: Bool
}

struct ProviderResult {
    let text: String
}

struct ProviderInfo {
    let name: String
    let config: ProviderConfiguration
    let model: String
    let tier: QueryTier
}

struct ProviderHealth {
    let name: String
    var consecutiveFailures: Int = 0
    var lastSuccess: Date?
    var lastFailure: Date?
}

// MARK: - Configuration Models

struct RouterConfig: Codable {
    let mode: RoutingMode
    let providers: [String: ProviderConfiguration]
    let escalation: EscalationConfig
    let tts: TTSConfig

    enum RoutingMode: String, Codable {
        case single
        case tiered
        case adaptive
    }
}

struct ProviderConfiguration: Codable {
    let enabled: Bool
    let type: ProviderType
    let endpoint: String?
    let models: [QueryTier: String]
    let cliCommand: String?
    let apiKey: String?
    let timeout: Double
    let priority: Int

    enum ProviderType: String, Codable {
        case ollama
        case claudeCLI
        case geminiCLI
        case bedrock
        case openaiAPI
        case nvidiaAPI
        case bash
        case custom
    }

    private enum CodingKeys: String, CodingKey {
        case enabled, type, endpoint, models, cliCommand, apiKey, timeout, priority
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try container.decode(Bool.self, forKey: .enabled)
        type = try container.decode(ProviderType.self, forKey: .type)
        endpoint = try container.decodeIfPresent(String.self, forKey: .endpoint)
        cliCommand = try container.decodeIfPresent(String.self, forKey: .cliCommand)
        apiKey = try container.decodeIfPresent(String.self, forKey: .apiKey)
        timeout = try container.decode(Double.self, forKey: .timeout)
        priority = try container.decode(Int.self, forKey: .priority)

        let modelsDict = try container.decode([String: String].self, forKey: .models)
        var parsedModels: [QueryTier: String] = [:]
        for (key, value) in modelsDict {
            if let tier = QueryTier(rawValue: key) {
                parsedModels[tier] = value
            }
        }
        models = parsedModels
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(enabled, forKey: .enabled)
        try container.encode(type, forKey: .type)
        try container.encodeIfPresent(endpoint, forKey: .endpoint)
        try container.encodeIfPresent(cliCommand, forKey: .cliCommand)
        try container.encodeIfPresent(apiKey, forKey: .apiKey)
        try container.encode(timeout, forKey: .timeout)
        try container.encode(priority, forKey: .priority)

        var modelsDict: [String: String] = [:]
        for (tier, model) in models {
            modelsDict[tier.rawValue] = model
        }
        try container.encode(modelsDict, forKey: .models)
    }
}

struct EscalationConfig: Codable {
    let enabled: Bool
    let thinkingKeywords: Bool?
    let toolUseDetected: Bool?
    let responseUnsatisfactory: Bool?
    let revertAfterResponse: Bool?

    init(
        enabled: Bool = true,
        thinkingKeywords: Bool? = true,
        toolUseDetected: Bool? = true,
        responseUnsatisfactory: Bool? = true,
        revertAfterResponse: Bool? = true
    ) {
        self.enabled = enabled
        self.thinkingKeywords = thinkingKeywords
        self.toolUseDetected = toolUseDetected
        self.responseUnsatisfactory = responseUnsatisfactory
        self.revertAfterResponse = revertAfterResponse
    }
}

struct TTSConfig: Codable {
    let primary: String
    let fallbackChain: [String]
}
