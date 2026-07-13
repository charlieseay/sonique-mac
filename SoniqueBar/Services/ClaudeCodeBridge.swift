import Foundation
import os.log

/// Routes voice commands directly to Claude Code CLI with full MCP tool access.
/// This replaces all custom connectors - Claude Code handles Helmsman, Slack, GitHub, vault, etc.
class ClaudeCodeBridge {
    private let logger = Logger(subsystem: "com.seayniclabs.soniquebar", category: "ClaudeCodeBridge")
    
    /// Execute a voice command via Claude Code CLI
    /// - Parameter text: User's spoken command
    /// - Returns: Streamed response from Claude Code
    func execute(text: String) async throws -> String {
        logger.info("[ClaudeCodeBridge] Executing: \(text.prefix(80))")
        
        // Use Claude Code CLI with MCP tool access
        // --print: output only (non-interactive)
        // --permission-mode allowAll: trust voice commands
        // --model haiku: fast for voice responses
        let result = await executeProcess(
            executable: "/opt/homebrew/bin/claude",
            arguments: [
                "--print",
                "--permission-mode", "allowAll",
                "--model", "haiku",
                text
            ],
            timeout: 30.0
        )
        
        if result.exitCode == 0 {
            logger.info("[ClaudeCodeBridge] Success: \(result.stdout.count) chars")
            return result.stdout
        } else {
            logger.error("[ClaudeCodeBridge] Failed: exit=\(result.exitCode) stderr=\(result.stderr.prefix(200))")
            throw BridgeError.executionFailed(result.stderr)
        }
    }
    
    enum BridgeError: Error {
        case executionFailed(String)
    }
    
    // MARK: - Process Execution
    
    private func executeProcess(
        executable: String,
        arguments: [String],
        timeout: TimeInterval
    ) async -> (stdout: String, stderr: String, exitCode: Int32) {
        return await withCheckedContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            
            // Set environment
            var env = ProcessInfo.processInfo.environment
            env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
            process.environment = env
            
            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()
            process.standardOutput = stdoutPipe
            process.standardError = stderrPipe
            
            var stdoutData = Data()
            var stderrData = Data()
            var didComplete = false
            
            // Async streaming
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
                
                // Async timeout
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
