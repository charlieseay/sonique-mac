import Foundation
import os.log

/// Routes voice commands directly to Claude Code CLI with full MCP tool access
class ClaudeCodeBridge {
    private let logger = Logger(subsystem: "com.seayniclabs.soniquebar", category: "ClaudeCodeBridge")

    func execute(text: String) async throws -> String {
        logger.info("[ClaudeCodeBridge] Executing: \(text.prefix(80))")

        // TEMPORARY: Claude CLI hangs in daemon context (no TTY/auth)
        // Return simple response to test TTS for now
        let lowerText = text.lowercased()

        if lowerText.contains("name") {
            return "I'm Quinn, your voice assistant."
        } else if lowerText.contains("time") {
            let formatter = DateFormatter()
            formatter.timeStyle = .short
            return "It's \(formatter.string(from: Date()))"
        } else if lowerText.contains("afternoon") || lowerText.contains("morning") || lowerText.contains("hello") {
            return "Hello! How can I help you?"
        } else {
            return "I heard you say: \(text)"
        }

        // TODO: Fix Claude CLI auth in daemon context OR use API directly
        /*
        let persona = await SoniqueBrain.shared.loadPersonaContext()
        let systemPrompt = persona.isEmpty ? text : "\(persona)\nUser request: \(text)"

        let result = await executeProcess(
            executable: "/opt/homebrew/bin/claude",
            arguments: [
                "--print",
                "--permission-mode", "bypassPermissions",
                "--model", "haiku",
                systemPrompt
            ],
            timeout: 60.0
        )

        if result.exitCode == 0 {
            logger.info("[ClaudeCodeBridge] Success")
            return result.stdout
        } else {
            logger.error("[ClaudeCodeBridge] Failed: \(result.stderr.prefix(200))")
            throw BridgeError.executionFailed(result.stderr)
        }
        */
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
