import Foundation

/// Claude provider using ask_claude subscription
struct ClaudeProvider: LLMProvider {
    let name = "Claude"
    let availableModels = ["haiku", "sonnet", "opus"]
    let supportsStreaming = false

    func complete(prompt: String, model: String?) async throws -> String {
        let selectedModel = model ?? "haiku"

        guard availableModels.contains(selectedModel) else {
            throw LLMError.invalidModel(selectedModel)
        }

        // Escape prompt for shell
        let escapedPrompt = prompt.replacingOccurrences(of: "'", with: "'\\''")

        // Use ask_claude with --prefer flag
        let command = "ask_claude '\(escapedPrompt)' --prefer \(selectedModel)"

        let result = await shell(command, timeout: 30)

        guard result.exitCode == 0 else {
            if result.stderr.contains("rate limit") {
                throw LLMError.rateLimitExceeded
            } else if result.stderr.contains("auth") || result.stderr.contains("unauthorized") {
                throw LLMError.authenticationFailed
            } else {
                throw LLMError.networkError(result.stderr)
            }
        }

        let output = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !output.isEmpty else {
            throw LLMError.invalidResponse("Empty response from Claude")
        }

        return output
    }

    func completeStreaming(prompt: String, model: String?) async throws -> AsyncThrowingStream<String, Error> {
        throw LLMError.notAvailable // Streaming not supported via ask_claude
    }

    func healthCheck() async -> Bool {
        // Check if ask_claude is available
        let whichResult = await shell("which ask_claude", timeout: 2)
        guard whichResult.exitCode == 0 else { return false }

        // Test with simple prompt
        let testResult = await shell("ask_claude 'test' --prefer haiku", timeout: 5)
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
