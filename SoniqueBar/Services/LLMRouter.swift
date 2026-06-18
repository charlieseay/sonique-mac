import Foundation

/// Routes LLM requests to best available provider: system Ollama > bundled model > network API
@MainActor
class LLMRouter: ObservableObject {
    static let shared = LLMRouter()

    @Published var currentProvider: Provider = .detecting
    @Published var isReady = false

    private var bundledModelPath: String?

    enum Provider: String {
        case detecting = "Detecting..."
        case systemOllama = "System Ollama"
        case bundledModel = "Bundled Phi-3"
        case networkAPI = "Network API"
    }

    private init() {
        Task {
            await detectProvider()
        }
    }

    /// Detect best available LLM provider on launch
    func detectProvider() async {
        // 1. Check system Ollama first (best performance if user has it)
        if await checkSystemOllama() {
            currentProvider = .systemOllama
            isReady = true
            print("[LLMRouter] Using system Ollama at localhost:11434")
            return
        }

        // 2. Check bundled model (guaranteed to work, no network)
        if let modelPath = locateBundledModel() {
            bundledModelPath = modelPath
            currentProvider = .bundledModel
            isReady = true
            print("[LLMRouter] Using bundled Phi-3 model at \(modelPath)")
            return
        }

        // 3. Fallback to network API
        currentProvider = .networkAPI
        isReady = true
        print("[LLMRouter] Using network API (ask_llm nvidia-fast)")
    }

    /// Check if Ollama is running on localhost:11434
    private func checkSystemOllama() async -> Bool {
        guard let url = URL(string: "http://localhost:11434/api/tags") else { return false }

        do {
            let (_, response) = try await URLSession.shared.data(from: url)
            return (response as? HTTPURLResponse)?.statusCode == 200
        } catch {
            return false
        }
    }

    /// Locate bundled Phi-3 model in app Resources
    private func locateBundledModel() -> String? {
        // Look for bundled .gguf model in Resources
        if let path = Bundle.main.path(forResource: "phi-3-mini-4k-instruct.Q4_K_M", ofType: "gguf") {
            // Verify file exists and is readable
            if FileManager.default.isReadableFile(atPath: path) {
                return path
            }
        }
        return nil
    }

    /// Generate response using detected provider
    func generate(prompt: String, system: String? = nil) async throws -> String {
        switch currentProvider {
        case .systemOllama:
            return try await generateWithOllama(prompt: prompt, system: system)

        case .bundledModel:
            return try await generateWithBundledModel(prompt: prompt, system: system)

        case .networkAPI:
            return try await generateWithNetworkAPI(prompt: prompt, system: system)

        case .detecting:
            throw LLMError.notReady
        }
    }

    // MARK: - Provider Implementations

    private func generateWithOllama(prompt: String, system: String?) async throws -> String {
        // Call local Ollama API
        guard let url = URL(string: "http://localhost:11434/api/generate") else {
            throw LLMError.invalidEndpoint
        }

        var payload: [String: Any] = [
            "model": "llama3.2:3b",  // Use fastest available model
            "prompt": prompt,
            "stream": false
        ]

        if let system = system {
            payload["system"] = system
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let (data, response) = try await URLSession.shared.data(for: request)

        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw LLMError.requestFailed
        }

        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard let responseText = json?["response"] as? String else {
            throw LLMError.invalidResponse
        }

        return responseText
    }

    private func generateWithBundledModel(prompt: String, system: String?) async throws -> String {
        // TODO: Implement llama.cpp integration when model is bundled
        // For now, fallback to network API
        print("[LLMRouter] Bundled model not yet implemented, falling back to network")
        return try await generateWithNetworkAPI(prompt: prompt, system: system)
    }

    private func generateWithNetworkAPI(prompt: String, system: String?) async throws -> String {
        // Call ask_llm with nvidia-fast lane
        let fullPrompt = system != nil ? "\(system!)\n\n\(prompt)" : prompt

        let result = await InfrastructureExecutor.shell(
            "ask_llm --lane nvidia-fast --prompt \(fullPrompt.shellEscaped)"
        )

        guard result.exitCode == 0 else {
            throw LLMError.requestFailed
        }

        return result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    enum LLMError: Error, LocalizedError {
        case notReady
        case invalidEndpoint
        case requestFailed
        case invalidResponse

        var errorDescription: String? {
            switch self {
            case .notReady: return "LLM provider not ready"
            case .invalidEndpoint: return "Invalid LLM endpoint"
            case .requestFailed: return "LLM request failed"
            case .invalidResponse: return "Invalid LLM response"
            }
        }
    }
}

// MARK: - String Extension for Shell Escaping
extension String {
    var shellEscaped: String {
        // Escape for shell command
        return "'\(self.replacingOccurrences(of: "'", with: "'\\''"))'"
    }
}
