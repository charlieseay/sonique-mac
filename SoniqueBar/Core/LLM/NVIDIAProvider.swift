import Foundation

/// NVIDIA NIM provider using ask_llm with NVIDIA lanes
struct NVIDIAProvider: LLMProvider {
    let name = "NVIDIA"
    let availableModels = ["fast", "balanced", "quality"]
    let supportsStreaming = false

    func complete(prompt: String, model: String?) async throws -> String {
        let lane = model ?? "fast"

        guard availableModels.contains(lane) else {
            throw LLMError.invalidModel(lane)
        }

        // Escape prompt for shell
        let escapedPrompt = prompt.replacingOccurrences(of: "'", with: "'\\''")

        // Use ask_llm with --lane flag
        let command = "ask_llm --lane \(lane) '\(escapedPrompt)'"

        let result = await shell(command, timeout: 30)

        guard result.exitCode == 0 else {
            if result.stderr.contains("rate limit") {
                throw LLMError.rateLimitExceeded
            } else {
                throw LLMError.networkError(result.stderr)
            }
        }

        let output = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !output.isEmpty else {
            throw LLMError.invalidResponse("Empty response from NVIDIA")
        }

        return output
    }

    func completeStreaming(prompt: String, model: String?) async throws -> AsyncThrowingStream<String, Error> {
        throw LLMError.notAvailable // Streaming not supported via ask_llm
    }

    func healthCheck() async -> Bool {
        // Check if ask_llm is available
        let whichResult = await shell("which ask_llm", timeout: 2)
        guard whichResult.exitCode == 0 else { return false }

        // Check health
        let healthResult = await shell("ask_llm --health", timeout: 5)
        return healthResult.exitCode == 0
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
