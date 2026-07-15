import Foundation
import os.log

/// Routes voice commands directly to Claude Code CLI with full MCP tool access
class ClaudeCodeBridge {
    private let logger = Logger(subsystem: "com.seayniclabs.soniquebar", category: "ClaudeCodeBridge")

    func execute(text: String) async throws -> String {
        logger.info("[ClaudeCodeBridge] Executing: \(text.prefix(80))")

        // Call Quinn Brain Service (Python service with intelligent model routing)
        let url = URL(string: "http://127.0.0.1:5912/respond")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 30.0

        let payload = ["text": text]
        request.httpBody = try? JSONSerialization.data(withJSONObject: payload)

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                logger.error("[ClaudeCodeBridge] Quinn Brain Service returned \((response as? HTTPURLResponse)?.statusCode ?? -1)")
                throw BridgeError.executionFailed("Service error")
            }

            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let responseText = json["response"] as? String else {
                throw BridgeError.executionFailed("Failed to parse response")
            }

            // Check if this is an async task
            if let status = json["status"] as? String, status == "async",
               let taskId = json["task_id"] as? String {
                logger.info("[ClaudeCodeBridge] Async task started: \(taskId)")

                // Return immediate acknowledgment
                let ack = responseText

                // Poll for completion in background
                Task {
                    await pollTaskCompletion(taskId: taskId)
                }

                return ack
            }

            // Sync response
            if let model = json["model"] as? String {
                logger.info("[ClaudeCodeBridge] Success via \(model)")
            }
            return responseText

        } catch {
            logger.error("[ClaudeCodeBridge] Quinn Brain Service failed: \(error.localizedDescription)")
            // Fallback to simple response
            return "I heard you say: \(text)"
        }
    }

    private func pollTaskCompletion(taskId: String) async {
        logger.info("[ClaudeCodeBridge] Polling task \(taskId)...")

        let maxAttempts = 30  // 30 attempts = 60s max (2s per attempt)
        var attempt = 0

        while attempt < maxAttempts {
            attempt += 1

            // Wait 2 seconds between polls
            try? await Task.sleep(nanoseconds: 2_000_000_000)

            guard let url = URL(string: "http://127.0.0.1:5912/tasks/\(taskId)") else { continue }

            do {
                let (data, _) = try await URLSession.shared.data(from: url)
                guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let status = json["status"] as? String else {
                    continue
                }

                if status == "completed" {
                    if let result = json["result"] as? String {
                        logger.info("[ClaudeCodeBridge] Task \(taskId) completed: \(result.prefix(50))")
                        // TODO: Speak the result to user
                        // For now, just log it - speaking requires TTS integration
                    }
                    return
                } else if status == "failed" {
                    if let error = json["error"] as? String {
                        logger.error("[ClaudeCodeBridge] Task \(taskId) failed: \(error)")
                    }
                    return
                }

                // Still running, continue polling
            } catch {
                logger.error("[ClaudeCodeBridge] Failed to poll task \(taskId): \(error)")
            }
        }

        logger.warning("[ClaudeCodeBridge] Task \(taskId) polling timed out after \(maxAttempts * 2)s")
    }

    enum BridgeError: Error {
        case executionFailed(String)
    }

    private func executeProcess(
        executable: String,
        arguments: [String],
        timeout: TimeInterval
    ) async -> (stdout: String, stderr: String, exitCode: Int32) {
        return await withCheckedContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments

            var env = ProcessInfo.processInfo.environment
            env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
            env["HOME"] = env["HOME"] ?? "/Users/charlieseay"
            process.environment = env

            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()
            process.standardOutput = stdoutPipe
            process.standardError = stderrPipe

            var stdoutData = Data()
            var stderrData = Data()
            var didComplete = false

            stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
                stdoutData.append(handle.availableData)
            }

            stderrPipe.fileHandleForReading.readabilityHandler = { handle in
                stderrData.append(handle.availableData)
            }

            process.terminationHandler = { process in
                guard !didComplete else { return }
                didComplete = true

                let stdout = String(data: stdoutData, encoding: .utf8) ?? ""
                let stderr = String(data: stderrData, encoding: .utf8) ?? ""

                continuation.resume(returning: (
                    stdout.trimmingCharacters(in: .whitespacesAndNewlines),
                    stderr.trimmingCharacters(in: .whitespacesAndNewlines),
                    process.terminationStatus
                ))
            }

            do {
                try process.run()

                Task {
                    try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                    if process.isRunning {
                        process.terminate()
                        if !didComplete {
                            didComplete = true
                            continuation.resume(returning: ("", "Process timed out", 124))
                        }
                    }
                }
            } catch {
                if !didComplete {
                    didComplete = true
                    continuation.resume(returning: ("", error.localizedDescription, -1))
                }
            }
        }
    }
}
