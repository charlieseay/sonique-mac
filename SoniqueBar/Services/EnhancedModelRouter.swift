import Foundation
import os.log

/// Enhanced model router with adaptive tier escalation and multi-provider support
/// Replaces simple ModelRouter with intelligent routing based on query complexity
@MainActor
class EnhancedModelRouter {
    static let shared = EnhancedModelRouter()

    private let logger = Logger(subsystem: "com.seayniclabs.soniquebar", category: "EnhancedModelRouter")
    private var config: RouterConfig
    private var providerCache: [String: ProviderHealth] = [:]

    // Pattern detection for tier classification
    private let thinkingKeywords = [
        "explain", "why", "analyze", "summar", "tell me about", "what.s the difference",
        "compare", "research", "describe", "how does", "what causes"
    ]

    private let toolsKeywords = [
        "create task", "add reminder", "send message", "search vault", "docker",
        "helmsman", "slack", "github", "file search"
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
            logger.info("[EnhancedModelRouter] Loaded config: \(loaded.mode.rawValue)")
        } else {
            // Default: system voice only (safest fallback)
            self.config = RouterConfig(
                mode: .adaptive,
                providers: [:],
                escalation: EscalationConfig(),
                tts: TTSConfig(primary: "system", fallbackChain: ["system"])
            )
            logger.info("[EnhancedModelRouter] Using default config (system only)")
        }
    }

    /// Main routing entry point with automatic tier escalation
    func route(prompt: String, context: QueryContext? = nil) async throws -> RouterResponse {
        let startTime = Date()

        // 1. Determine tier
        let tier = determineTier(prompt: prompt, context: context)
        logger.info("[Router] Query tier: \(tier.rawValue)")

        // 2. Get providers for tier
        let providers = getProvidersForTier(tier)
        guard !providers.isEmpty else {
            throw RouterError.noProvidersAvailable
        }

        // 3. Try providers in priority order
        var lastError: Error?
        for provider in providers {
            do {
                let response = try await callProvider(provider, prompt: prompt, tier: tier)

                // 4. Check if escalation needed
                if config.escalation.enabled,
                   tier != .tools,  // Already at max
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

                // Success!
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

        // All providers failed
        throw lastError ?? RouterError.allProvidersFailed
    }

    // MARK: - Tier Detection

    private func determineTier(prompt: String, context: QueryContext?) -> QueryTier {
        // 1. Check for forced tier
        if let forced = context?.forceTier {
            return forced
        }

        // 2. Check for tool keywords (highest priority)
        let lower = prompt.lowercased()
        if toolsKeywords.contains(where: { lower.contains($0) }) {
            return .tools
        }

        // 3. Check for MCP tools context
        if context?.mcpToolsAvailable == true,
           (lower.contains("create") || lower.contains("send") || lower.contains("search")) {
            return .tools
        }

        // 4. Check for thinking keywords
        if thinkingKeywords.contains(where: { lower.contains($0) }) {
            return .thinking
        }

        // 5. Default to conversational
        return .conversational
    }

    private func shouldEscalate(_ response: String, currentTier: QueryTier) -> Bool {
        guard config.escalation.responseUnsatisfactory else { return false }

        return uncertaintyPhrases.contains(where: { response.contains($0) })
    }

    // MARK: - Provider Selection

    private func getProvidersForTier(_ tier: QueryTier) -> [ProviderInfo] {
        var providers: [ProviderInfo] = []

        // Filter enabled providers and match to tier
        for (name, providerConfig) in config.providers {
            guard providerConfig.enabled else { continue }

            // Get model for this tier
            let model = providerConfig.models[tier] ?? providerConfig.models[.conversational]
            guard let model else { continue }

            providers.append(ProviderInfo(
                name: name,
                config: providerConfig,
                model: model,
                tier: tier
            ))
        }

        // Sort by priority (lower = higher priority)
        return providers.sorted { $0.config.priority < $1.config.priority }
    }

    // MARK: - Provider Calling

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

        case .custom:
            return try await callCustom(provider: provider, prompt: prompt, timeout: timeout)
        }
    }

    private func callOllama(provider: ProviderInfo, prompt: String, timeout: Double) async throws -> ProviderResult {
        guard let endpoint = provider.config.endpoint else {
            throw RouterError.missingConfig("Ollama endpoint not specified")
        }

        let url = URL(string: "\(endpoint)/api/generate")!
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: Any] = [
            "model": provider.model,
            "prompt": prompt,
            "stream": false
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            throw RouterError.executionFailed("Ollama HTTP \((response as? HTTPURLResponse)?.statusCode ?? -1)")
        }

        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard let responseText = json?["response"] as? String else {
            throw RouterError.executionFailed("Invalid Ollama response format")
        }

        updateProviderHealth(provider.name, healthy: true)
        return ProviderResult(text: responseText)
    }

    private func callClaudeCLI(provider: ProviderInfo, prompt: String, timeout: Double) async throws -> ProviderResult {
        guard let command = provider.config.cliCommand else {
            throw RouterError.missingConfig("Claude CLI command not specified")
        }

        return try await callCLI(
            command: command,
            args: ["-m", provider.model, "-p", prompt],
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
            args: ["-m", provider.model, "-p", prompt],
            timeout: timeout,
            providerName: provider.name
        )
    }

    private func callBedrock(provider: ProviderInfo, prompt: String, timeout: Double) async throws -> ProviderResult {
        // Use ask_claude_bedrock CLI
        return try await callCLI(
            command: "/usr/local/bin/ask_claude_bedrock",
            args: ["-p", prompt],
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
        // Use ask_llm CLI with NVIDIA lane
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

        // Assume OpenAI-compatible API
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

    // MARK: - Helper: CLI Execution

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
            let lock = NSLock()

            let timer = Timer.scheduledTimer(withTimeInterval: timeout, repeats: false) { _ in
                lock.lock()
                guard !didComplete else {
                    lock.unlock()
                    return
                }
                didComplete = true
                lock.unlock()

                process.terminate()
                continuation.resume(throwing: RouterError.timeout("CLI timed out after \(timeout)s"))
            }

            process.terminationHandler = { process in
                lock.lock()
                guard !didComplete else {
                    lock.unlock()
                    return
                }
                didComplete = true
                lock.unlock()

                timer.invalidate()

                let output = String(data: outputPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                let error = String(data: errorPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""

                if process.terminationStatus == 0 {
                    self.updateProviderHealth(providerName, healthy: true)
                    continuation.resume(returning: ProviderResult(text: output.trimmingCharacters(in: .whitespacesAndNewlines)))
                } else {
                    continuation.resume(throwing: RouterError.executionFailed("CLI failed: \(error)"))
                }
            }

            do {
                try process.run()
            } catch {
                lock.lock()
                guard !didComplete else {
                    lock.unlock()
                    return
                }
                didComplete = true
                lock.unlock()

                timer.invalidate()
                continuation.resume(throwing: error)
            }
        }
    }

    // MARK: - Health Tracking

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

    // MARK: - Config Loading

    private static func loadConfig() -> RouterConfig? {
        let path = "/Volumes/data/secrets/sonique_model_router.json"
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let config = try? JSONDecoder().decode(RouterConfig.self, from: data) else {
            return nil
        }
        return config
    }

    enum RouterError: Error {
        case noProvidersAvailable
        case allProvidersFailed
        case missingConfig(String)
        case executionFailed(String)
        case timeout(String)
        case invalidConfig(String)
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
        case single      // One provider for all
        case tiered      // Simple/medium/complex static routing
        case adaptive    // Dynamic tier escalation
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

        // Decode models dictionary
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

        // Encode models dictionary
        var modelsDict: [String: String] = [:]
        for (tier, model) in models {
            modelsDict[tier.rawValue] = model
        }
        try container.encode(modelsDict, forKey: .models)
    }
}

struct EscalationConfig: Codable {
    let enabled: Bool
    let thinkingKeywords: Bool
    let toolUseDetected: Bool
    let responseUnsatisfactory: Bool
    let revertAfterResponse: Bool

    init(
        enabled: Bool = true,
        thinkingKeywords: Bool = true,
        toolUseDetected: Bool = true,
        responseUnsatisfactory: Bool = true,
        revertAfterResponse: Bool = true
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
