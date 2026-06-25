import Foundation

class OllamaService {
    static let shared = OllamaService()

    private let ollamaURL = URL(string: "http://localhost:11434/api/generate")!
    private var isAvailable: Bool?
    private let checkInterval: TimeInterval = 60  // Re-check availability every 60s
    private var lastCheck: Date?

    private init() {}

    /// Check if Ollama is available (with caching)
    func checkAvailable() async -> Bool {
        let now = Date()
        if let lastCheck = lastCheck, now.timeIntervalSince(lastCheck) < checkInterval,
           let cached = isAvailable {
            return cached
        }

        var request = URLRequest(url: ollamaURL)
        request.timeoutInterval = 1.0

        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            let available = (response as? HTTPURLResponse)?.statusCode != nil
            self.isAvailable = available
            self.lastCheck = now
            return available
        } catch {
            self.isAvailable = false
            self.lastCheck = now
            return false
        }
    }

    /// Generate a response using Ollama (simple, fast queries only)
    func generate(_ prompt: String, model: String = "phi") async -> String? {
        guard await checkAvailable() else { return nil }

        let payload: [String: Any] = [
            "model": model,
            "prompt": prompt,
            "stream": false,
            "temperature": 0.7,
            "num_ctx": 512  // Small context for speed
        ]

        guard let bodyData = try? JSONSerialization.data(withJSONObject: payload) else {
            return nil
        }

        var request = URLRequest(url: ollamaURL)
        request.httpMethod = "POST"
        request.httpBody = bodyData
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 8.0  // 8s timeout for quick local inference

        do {
            let (data, _) = try await URLSession.shared.data(for: request)

            if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
               let response = json["response"] as? String {
                return response.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        } catch {
            return nil
        }

        return nil
    }

    /// Fast path for conversational queries (returns immediately or timeout)
    func generateFast(_ prompt: String) async -> String? {
        guard await checkAvailable() else { return nil }

        // Use a very small context for speed
        let payload: [String: Any] = [
            "model": "phi",
            "prompt": prompt,
            "stream": false,
            "temperature": 0.7,
            "num_predict": 100,  // Max 100 tokens
            "num_ctx": 256  // Tiny context
        ]

        guard let bodyData = try? JSONSerialization.data(withJSONObject: payload) else {
            return nil
        }

        var request = URLRequest(url: ollamaURL)
        request.httpMethod = "POST"
        request.httpBody = bodyData
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 5.0  // Very tight timeout

        do {
            let (data, _) = try await URLSession.shared.data(for: request)

            if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
               let response = json["response"] as? String {
                let cleaned = response.trimmingCharacters(in: .whitespacesAndNewlines)
                // Only return if response is reasonable length (< 500 chars)
                return cleaned.count < 500 ? cleaned : nil
            }
        } catch {
            return nil
        }

        return nil
    }
}
