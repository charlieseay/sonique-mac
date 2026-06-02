import Foundation

/// Routes user commands to the appropriate handler.
/// Classifies between conversational queries and infrastructure commands.
struct IntentRouter {
    enum Intent {
        case conversation(text: String)
        case infrastructure(command: InfrastructureCommand)
        case unknown(text: String)
    }

    enum InfrastructureCommand {
        case restartContainer(name: String)
        case checkStatus(service: String)
        case helmsmanQuery(query: String)
        case mcpTool(tool: String, query: String)
        case shellCommand(command: String)
        case openURL(url: String)
        case screenshot(region: ScreenshotRegion)
        case slackMessage(channel: String, text: String)
    }

    enum ScreenshotRegion {
        case fullScreen
        case area(x: Int, y: Int, width: Int, height: Int)
    }

    /// Classify the user's text input
    static func classify(_ text: String) -> Intent {
        let lower = text.lowercased()

        // Slack message to #cael (check first - highest priority for delegation)
        if lower.contains("tell the team") || lower.contains("ask the team") {
            let message = text.replacingOccurrences(of: "tell the team", with: "", options: .caseInsensitive)
                             .replacingOccurrences(of: "ask the team", with: "", options: .caseInsensitive)
                             .trimmingCharacters(in: .whitespacesAndNewlines)
            return .infrastructure(command: .slackMessage(channel: "cael", text: message))
        }

        // Docker container operations
        if lower.contains("restart") {
            if let containerName = extractContainerName(from: text) {
                return .infrastructure(command: .restartContainer(name: containerName))
            }
        }

        // Status checks
        if lower.contains("status") || lower.contains("check") {
            if let service = extractServiceName(from: text) {
                return .infrastructure(command: .checkStatus(service: service))
            }
        }

        // Helmsman queries
        if lower.contains("queue") || lower.contains("helmsman") || lower.contains("tasks") {
            return .infrastructure(command: .helmsmanQuery(query: text))
        }

        // Vault queries (MCP)
        if lower.contains("vault") || lower.contains("note") || lower.contains("read") {
            return .infrastructure(command: .mcpTool(tool: "vault", query: text))
        }

        // Shell commands (explicit)
        if lower.starts(with: "run ") || lower.starts(with: "execute ") {
            let cmd = text.replacingOccurrences(of: "run ", with: "")
                          .replacingOccurrences(of: "execute ", with: "")
            return .infrastructure(command: .shellCommand(command: cmd))
        }

        // Open URL in Safari
        if lower.contains("open") && (lower.contains("http") || lower.contains("www.")) {
            if let url = extractURL(from: text) {
                return .infrastructure(command: .openURL(url: url))
            }
        }

        // Screenshot
        if lower.contains("screenshot") || lower.contains("screen shot") {
            return .infrastructure(command: .screenshot(region: .fullScreen))
        }

        // Default: conversational
        return .conversation(text: text)
    }

    private static func extractURL(from text: String) -> String? {
        let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
        let matches = detector?.matches(in: text, range: NSRange(text.startIndex..., in: text))

        if let url = matches?.first?.url?.absoluteString {
            return url
        }

        // Fallback: extract anything starting with http or www
        let words = text.components(separatedBy: .whitespaces)
        for word in words {
            if word.starts(with: "http") || word.starts(with: "www.") {
                return word.starts(with: "www.") ? "https://\(word)" : word
            }
        }

        return nil
    }

    private static func extractContainerName(from text: String) -> String? {
        let lower = text.lowercased()
        let containers = ["n8n", "postgres", "redis", "nginx", "livekit", "kokoro"]

        for container in containers {
            if lower.contains(container) {
                return container
            }
        }

        return nil
    }

    private static func extractServiceName(from text: String) -> String? {
        let lower = text.lowercased()
        let services = ["docker", "n8n", "helmsman", "network", "containers"]

        for service in services {
            if lower.contains(service) {
                return service
            }
        }

        return nil
    }
}

/// Executes infrastructure commands
struct InfrastructureExecutor {
    /// Execute an infrastructure command and return the result
    static func execute(command: IntentRouter.InfrastructureCommand) async -> String {
        switch command {
        case .restartContainer(let name):
            return await restartDockerContainer(name)

        case .checkStatus(let service):
            return await checkServiceStatus(service)

        case .helmsmanQuery(let query):
            return await queryHelmsman(query)

        case .mcpTool(let tool, let query):
            return await invokeMCPTool(tool, query: query)

        case .shellCommand(let cmd):
            return await runShellCommand(cmd)

        case .openURL(let url):
            return await openInSafari(url)

        case .screenshot(let region):
            return await captureScreenshot(region)

        case .slackMessage(let channel, let text):
            return await sendToSlack(channel, text)
        }
    }

    // MARK: - Docker Operations

    private static func restartDockerContainer(_ name: String) async -> String {
        let result = await shell("docker restart \(name)")

        if result.exitCode == 0 {
            return "Container '\(name)' restarted successfully."
        } else {
            return "Failed to restart '\(name)': \(result.stderr)"
        }
    }

    // MARK: - Status Checks

    private static func checkServiceStatus(_ service: String) async -> String {
        switch service.lowercased() {
        case "docker", "containers":
            let result = await shell("docker ps --format 'table {{.Names}}\t{{.Status}}'")
            return result.exitCode == 0 ? result.stdout : "Failed to check Docker status"

        case "n8n":
            let result = await shell("docker ps --filter name=n8n --format '{{.Status}}'")
            return result.exitCode == 0 ? "n8n: \(result.stdout)" : "n8n is not running"

        default:
            return "Unknown service: \(service)"
        }
    }

    // MARK: - Helmsman Integration

    private static func queryHelmsman(_ query: String) async -> String {
        // Query Helmsman's queue via REST API directly
        if query.lowercased().contains("queue") {
            let result = await shell("curl -s 'http://localhost:5682/tasks?status=pending'")

            if result.exitCode == 0, let data = result.stdout.data(using: .utf8) {
                do {
                    let json = try JSONSerialization.jsonObject(with: data) as? [[String: Any]]
                    let count = json?.count ?? 0

                    if count == 0 {
                        return "Helmsman's queue is empty."
                    } else {
                        let taskList = json?.prefix(5).map { task in
                            let num = task["num"] as? Int ?? 0
                            let title = task["task"] as? String ?? "Unknown"
                            return "#\(num): \(title)"
                        }.joined(separator: "\n") ?? ""

                        return "Helmsman has \(count) pending tasks:\n\(taskList)"
                    }
                } catch {
                    return "Failed to parse queue response: \(error.localizedDescription)"
                }
            } else {
                return "Failed to reach Helmsman REST API (exit code: \(result.exitCode))"
            }
        }

        // For non-queue queries, use ask_helmsman if available
        let which = await shell("which ask_helmsman")
        guard which.exitCode == 0 else {
            return "ask_helmsman not available for this query"
        }

        let result = await shell("ask_helmsman '\(query)'")
        return result.exitCode == 0 ? result.stdout : "Helmsman query failed"
    }

    // MARK: - MCP Tool Integration

    private static func invokeMCPTool(_ tool: String, query: String) async -> String {
        // MCP proxy runs on localhost:3700
        // For vault queries, extract the note name and read it
        if tool == "vault" {
            // Extract note name from query
            let noteName = extractNoteName(from: query)

            // Call vault MCP via curl
            let payload = """
            {
              "method": "tools/call",
              "params": {
                "name": "read_note",
                "arguments": {
                  "title": "\(noteName)"
                }
              }
            }
            """

            let command = """
            curl -s -X POST http://localhost:3700/vault \
              -H 'Content-Type: application/json' \
              -d '\(payload)'
            """

            let result = await shell(command)

            if result.exitCode == 0 {
                // Parse MCP response
                if let data = result.stdout.data(using: .utf8),
                   let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let resultObj = json["result"] as? [String: Any],
                   let content = resultObj["content"] as? [[String: Any]],
                   let text = content.first?["text"] as? String {
                    // Return first 500 chars
                    let preview = String(text.prefix(500))
                    return preview + (text.count > 500 ? "..." : "")
                }
            }

            return "Could not read note '\(noteName)' from vault"
        }

        return "MCP tool '\(tool)' not yet implemented"
    }

    private static func extractNoteName(from query: String) -> String {
        // Extract note name from queries like "read note X" or "vault note X"
        let words = query.components(separatedBy: .whitespaces)

        // Find "note" keyword and take the next word(s)
        if let noteIndex = words.firstIndex(where: { $0.lowercased() == "note" }) {
            let remainingWords = words.dropFirst(noteIndex + 1)
            return remainingWords.joined(separator: " ")
        }

        // Fallback: return the whole query
        return query
    }

    // MARK: - Shell Execution

    private static func runShellCommand(_ command: String) async -> String {
        let result = await shell(command)

        if result.exitCode == 0 {
            return result.stdout.isEmpty ? "Command executed successfully" : result.stdout
        } else {
            return "Command failed: \(result.stderr)"
        }
    }

    // MARK: - Safari Automation

    private static func openInSafari(_ url: String) async -> String {
        let result = await shell("open -a Safari '\(url)'")

        if result.exitCode == 0 {
            return "Opened \(url) in Safari"
        } else {
            return "Failed to open Safari: \(result.stderr)"
        }
    }

    // MARK: - Screenshot Capture

    private static func captureScreenshot(_ region: IntentRouter.ScreenshotRegion) async -> String {
        // Use screencapture to save screenshot to temp location
        let timestamp = Int(Date().timeIntervalSince1970)
        let path = "/tmp/sonique-screenshot-\(timestamp).png"

        let command: String
        switch region {
        case .fullScreen:
            command = "screencapture -x '\(path)'"
        case .area(let x, let y, let width, let height):
            command = "screencapture -x -R\(x),\(y),\(width),\(height) '\(path)'"
        }

        let result = await shell(command)

        if result.exitCode == 0 {
            // TODO: Send screenshot to iOS app via HTTP POST
            return "Screenshot saved to \(path)"
        } else {
            return "Screenshot failed: \(result.stderr)"
        }
    }

    // MARK: - Slack Integration

    private static func sendToSlack(_ channel: String, _ text: String) async -> String {
        // Post to #cael channel as if Charlie asked
        let message = "Charlie (via Sonique): \(text)".replacingOccurrences(of: "\"", with: "\\\"")
        let command = """
        curl -s -X POST https://slack.com/api/chat.postMessage \
          -H 'Authorization: Bearer '$(cat /Volumes/data/secrets/slack_bot_token) \
          -H 'Content-Type: application/json' \
          -d '{"channel":"\(channel)","text":"\(message)"}'
        """

        let result = await shell(command)

        if result.exitCode == 0, result.stdout.contains("\"ok\":true") {
            return "Posted to #\(channel)"
        } else {
            return "Slack post failed: \(result.stdout)"
        }
    }

    // MARK: - Shell Helper

    static func shell(_ command: String) async -> (stdout: String, stderr: String, exitCode: Int32) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-c", command]

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        do {
            try process.run()
            process.waitUntilExit()

            let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
            let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()

            let stdout = String(data: stdoutData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let stderr = String(data: stderrData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

            return (stdout, stderr, process.terminationStatus)
        } catch {
            return ("", error.localizedDescription, -1)
        }
    }
}
