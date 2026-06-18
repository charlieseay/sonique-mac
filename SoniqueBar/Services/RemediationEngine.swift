import Foundation

/// Auto-remediation engine that attempts to fix issues when possible
struct RemediationEngine {

    struct RemediationResult: Codable {
        let success: Bool
        let actionsTaken: [String]
        let message: String
        let error: String?
    }

    /// Attempt auto-remediation based on diagnosis
    static func remediate(diagnosis: DiagnosticAgent.Diagnosis) async -> RemediationResult {
        guard diagnosis.remediation.autoFixable,
              let steps = diagnosis.remediation.autoFixSteps else {
            return RemediationResult(
                success: false,
                actionsTaken: [],
                message: "No automatic fix available",
                error: nil
            )
        }

        NSLog("[remediation] Attempting auto-fix for: \(diagnosis.diagnosis)")

        var actionsTaken: [String] = []

        // Execute remediation steps based on diagnosis
        if diagnosis.diagnosis.contains("Ollama") {
            let result = await restartOllama()
            actionsTaken.append(contentsOf: result.actionsTaken)
            if result.success {
                return RemediationResult(
                    success: true,
                    actionsTaken: actionsTaken,
                    message: "Ollama service restarted successfully",
                    error: nil
                )
            } else {
                return RemediationResult(
                    success: false,
                    actionsTaken: actionsTaken,
                    message: "Failed to restart Ollama",
                    error: result.error
                )
            }
        }

        // Add more remediation handlers here as needed

        return RemediationResult(
            success: false,
            actionsTaken: actionsTaken,
            message: "No remediation handler implemented for this issue",
            error: nil
        )
    }

    /// Restart Ollama service
    private static func restartOllama() async -> RemediationResult {
        var actionsTaken: [String] = []

        // Check if Ollama is running
        actionsTaken.append("Checking Ollama status")
        let checkProcess = Process()
        checkProcess.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        checkProcess.arguments = ["-x", "ollama"]

        do {
            try checkProcess.run()
            checkProcess.waitUntilExit()

            if checkProcess.terminationStatus == 0 {
                // Ollama is running - try to restart via launchctl
                actionsTaken.append("Ollama running - attempting restart")

                let stopProcess = Process()
                stopProcess.executableURL = URL(fileURLWithPath: "/bin/launchctl")
                stopProcess.arguments = ["stop", "com.ollama.ollama"]

                try stopProcess.run()
                stopProcess.waitUntilExit()

                // Wait a moment before starting
                try await Task.sleep(nanoseconds: 1_000_000_000)  // 1 second

                let startProcess = Process()
                startProcess.executableURL = URL(fileURLWithPath: "/bin/launchctl")
                startProcess.arguments = ["start", "com.ollama.ollama"]

                try startProcess.run()
                startProcess.waitUntilExit()

                actionsTaken.append("Ollama restarted via launchctl")

                // Verify restart
                try await Task.sleep(nanoseconds: 2_000_000_000)  // 2 seconds
                if await isOllamaHealthy() {
                    actionsTaken.append("Ollama health check passed")
                    return RemediationResult(
                        success: true,
                        actionsTaken: actionsTaken,
                        message: "Ollama restarted successfully",
                        error: nil
                    )
                } else {
                    actionsTaken.append("Ollama health check failed after restart")
                    return RemediationResult(
                        success: false,
                        actionsTaken: actionsTaken,
                        message: "Ollama restarted but health check failed",
                        error: "Service not responding after restart"
                    )
                }
            } else {
                // Ollama not running - try to start it
                actionsTaken.append("Ollama not running - attempting start")

                let startProcess = Process()
                startProcess.executableURL = URL(fileURLWithPath: "/bin/launchctl")
                startProcess.arguments = ["start", "com.ollama.ollama"]

                try startProcess.run()
                startProcess.waitUntilExit()

                actionsTaken.append("Ollama start command sent")

                // Verify start
                try await Task.sleep(nanoseconds: 2_000_000_000)  // 2 seconds
                if await isOllamaHealthy() {
                    actionsTaken.append("Ollama started successfully")
                    return RemediationResult(
                        success: true,
                        actionsTaken: actionsTaken,
                        message: "Ollama service started",
                        error: nil
                    )
                } else {
                    actionsTaken.append("Ollama failed to start")
                    return RemediationResult(
                        success: false,
                        actionsTaken: actionsTaken,
                        message: "Failed to start Ollama",
                        error: "Service not responding after start"
                    )
                }
            }
        } catch {
            actionsTaken.append("Process execution failed: \(error.localizedDescription)")
            return RemediationResult(
                success: false,
                actionsTaken: actionsTaken,
                message: "Failed to execute remediation",
                error: error.localizedDescription
            )
        }
    }

    /// Check if Ollama is healthy
    private static func isOllamaHealthy() async -> Bool {
        guard let url = URL(string: "http://localhost:11434/api/version") else {
            return false
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 3

        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            if let httpResponse = response as? HTTPURLResponse {
                return httpResponse.statusCode == 200
            }
            return false
        } catch {
            return false
        }
    }
}
