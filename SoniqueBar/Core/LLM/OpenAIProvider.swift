import Foundation

/// OpenAI provider using direct API
struct OpenAIProvider: LLMProvider {
    let name = "OpenAI"
    let availableModels = ["gpt-4", "gpt-4-turbo", "gpt-3.5-turbo"]
    let supportsStreaming = true

    private func getAPIKey() -> String? {
        // Try AppStorage first
        if let key = UserDefaults.standard.string(forKey: "openai_api_key"), !key.isEmpty {
            return key
        }

        // Try environment variable
        if let key = ProcessInfo.processInfo.environment["OPENAI_API_KEY"], !key.isEmpty {
            return key
        }

        return nil
    }

    func complete(prompt: String, model: String?) async throws -> String {
        guard let apiKey = getAPIKey() else {
            throw LLMError.authenticationFailed
        }

        let selectedModel = model ?? "gpt-4"

        guard availableModels.contains(selectedModel) else {
            throw LLMError.invalidModel(selectedModel)
        }

        let url = URL(string: "https://api.openai.com/v1/chat/completions")!

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let payload: [String: Any] = [
            "model": selectedModel,
            "messages": [
                ["role": "user", "content": prompt]
            ],
            "max_tokens": 2000
        ]

        request.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw LLMError.networkError("Invalid response")
        }

        guard httpResponse.statusCode == 200 else {
            if httpResponse.statusCode == 429 {
                throw LLMError.rateLimitExceeded
            } else if httpResponse.statusCode == 401 {
                throw LLMError.authenticationFailed
            } else {
                let errorMessage = String(data: data, encoding: .utf8) ?? "Unknown error"
                throw LLMError.networkError("HTTP \(httpResponse.statusCode): \(errorMessage)")
            }
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let firstChoice = choices.first,
              let message = firstChoice["message"] as? [String: Any],
              let content = message["content"] as? String else {
            throw LLMError.invalidResponse("Could not parse OpenAI response")
        }

        return content.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func completeStreaming(prompt: String, model: String?) async throws -> AsyncThrowingStream<String, Error> {
        // Streaming implementation would go here
        throw LLMError.notAvailable
    }

    func healthCheck() async -> Bool {
        guard let apiKey = getAPIKey(), !apiKey.isEmpty else {
            return false
        }

        // Simple API test
        do {
            _ = try await complete(prompt: "test", model: "gpt-3.5-turbo")
            return true
        } catch {
            return false
        }
    }
}
