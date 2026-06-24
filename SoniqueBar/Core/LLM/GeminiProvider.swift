import Foundation

/// Gemini provider using ask_gemini subscription
struct GeminiProvider: LLMProvider {
    let name = "Gemini"
    let availableModels = ["gemini-pro", "gemini-flash"]
    let supportsStreaming = false

    func complete(prompt: String, model: String?) async throws -> String {
        let selectedModel = model ?? "gemini-pro"

        // Escape prompt for shell
        let escapedPrompt = prompt.replacingOccurrences(of: "'", with: "'\\''")

        // Use ask_gemini
        let command = "ask_gemini '\(escapedPrompt)'"

        let result = await shell(command, timeout: 30)

        guard result.exitCode == 0 else {
            if result.stderr.contains("rate limit") || result.stderr.contains("quota") {
                throw LLMError.rateLimitExceeded
            } else if result.stderr.contains("auth") || result.stderr.contains("unauthorized") {
                throw LLMError.authenticationFailed
            } else {
                throw LLMError.networkError(result.stderr)
            }
        }

        let output = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !output.isEmpty else {
            throw LLMError.invalidResponse("Empty response from Gemini")
        }

        return output
    }

    func completeStreaming(prompt: String, model: String?) async throws -> AsyncThrowingStream<String, Error> {
        throw LLMError.notAvailable // Streaming not supported via ask_gemini
    }

    func healthCheck() async -> Bool {
        // Check if ask_gemini is available
        let whichResult = await shell("which ask_gemini", timeout: 2)
        guard whichResult.exitCode == 0 else { return false }

        // Test with simple prompt
        let testResult = await shell("ask_gemini 'test'", timeout: 5)
        return testResult.exitCode == 0
    }

    // MARK: - Helper

    private func shell(_ command: String, timeout: Int = 30) async -> (stdout: String, stderr: String, exitCode: Int32) {
        let task = Process()
        task.launchPath = "/bin/zsh"
        task.arguments = ["-c", command]

        let outPipe = Pipe()
        let errPipe = Pipe()
        task.standardOutput = outPipe
        task.standardError = errPipe

        do {
            try task.run()

            // Wait with timeout
            let deadline = Date().addingTimeInterval(TimeInterval(timeout))
            while task.isRunning && Date() < deadline {
                try await Task.sleep(nanoseconds: 100_000_000) // 100ms
            }

            if task.isRunning {
                task.terminate()
                return ("", "Timeout", -1)
            }

            let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
            let errData = errPipe.fileHandleForReading.readDataToEndOfFile()

            let stdout = String(data: outData, encoding: .utf8) ?? ""
            let stderr = String(data: errData, encoding: .utf8) ?? ""

            return (stdout, stderr, task.terminationStatus)
        } catch {
            return ("", error.localizedDescription, -1)
        }
    }
}
