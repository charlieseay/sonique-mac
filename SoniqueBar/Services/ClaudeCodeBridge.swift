import Foundation
import os.log

/// Routes voice commands directly to Claude Code CLI with full MCP tool access
class ClaudeCodeBridge {
    private let logger = Logger(subsystem: "com.seayniclabs.soniquebar", category: "ClaudeCodeBridge")

    func execute(text: String) async throws -> String {
        logger.info("[ClaudeCodeBridge] Executing: \(text.prefix(80))")

        // Load personality from SoniqueBrain (iCloud-synced)
        let personality = await SoniqueBrain.shared.loadPersonaContext()

        let prompt = "\(personality)\n\nUser: \(text)"

        let result = await executeProcess(
            executable: "/Users/charlieseay/.local/bin/ask_claude_bedrock",
            arguments: [prompt],
            timeout: 15.0
        )

        if result.exitCode == 0 && !result.stdout.isEmpty {
            var response = result.stdout

            // Strip JSON header block that Bedrock script outputs
            // Format: {\n    "contentType": "application/json"\n}\nActual response
            if let closeBrace = response.range(of: "}\n") {
                response = String(response[closeBrace.upperBound...])
            }

            response = response.trimmingCharacters(in: .whitespacesAndNewlines)

            if response.isEmpty {
                logger.error("[ClaudeCodeBridge] Empty response after cleanup")
                throw BridgeError.executionFailed("Empty response")
            }

            logger.info("[ClaudeCodeBridge] Success via Bedrock: \(response.prefix(50))")
            return response
        } else {
            logger.error("[ClaudeCodeBridge] Bedrock failed: \(result.stderr)")
            throw BridgeError.executionFailed("Assistant unavailable")
        }
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
