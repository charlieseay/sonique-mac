import Foundation
import os.log

/// Executes MCP tools via subprocess stdio JSON-RPC or via the Claude CLI.
///
/// Strategy:
///   - **vault_search**: Direct grep over the Obsidian vault (fast, no subprocess MCP needed).
///   - **mcp__Slack__***: Delegated to the Claude CLI via --allowedTools so the already-authenticated
///     Slack MCP session (mcp.slack.com) is reused without re-implementing OAuth.
///   - **notebooklm_query**: Delegated to the Claude CLI with a targeted prompt; NotebookLM
///     doesn't expose a public MCP endpoint, so we query it via Claude's browsing capability.
///
/// When the Claude CLI MCP session is unavailable, we log a detailed NHR diagnosis to stderr.
struct MCPToolExecutor {

    private static let logger = Logger(subsystem: "com.seayniclabs.soniquebar", category: "MCPToolExecutor")

    // MARK: - Public entry point

    /// Execute a named MCP tool with the given input parameters.
    /// Returns the tool result as a plain string suitable for embedding in an LLM response.
    static func execute(tool: String, input: [String: Any]) async -> String {
        logger.info("[MCPToolExecutor] Executing tool: \(tool)")
        print("[MCPToolExecutor] Executing tool: \(tool) input=\(input)")

        switch tool {
        case "vault_search":
            let query = input["query"] as? String ?? ""
            return await executeVaultSearch(query: query)

        case "mcp__Slack__slack_post_message", "slack_post_message":
            let channelID = input["channel_id"] as? String ?? ""
            let text = input["text"] as? String ?? ""
            return await executeSlackPostMessage(channelID: channelID, text: text)

        case "notebooklm_query":
            let query = input["query"] as? String ?? ""
            return await executeNotebookLMQuery(query: query)

        default:
            // Attempt generic Claude CLI MCP delegation as fallback
            return await delegateToClaudeCLI(tool: tool, input: input)
        }
    }

    // MARK: - Vault Search

    private static func executeVaultSearch(query: String) async -> String {
        guard !query.isEmpty else { return "No search query provided." }

        let vaultPath = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Mobile Documents/iCloud~md~obsidian/Documents/SeaynicNet")
            .path

        // Use the vault-mcp proxy if available (preferred — returns structured results)
        if await MCPProxyClient.isAvailable() {
            if let result = await MCPProxyClient.executeTool(name: "search_notes", params: ["query": query]) {
                if let content = result["content"] as? String, !content.isEmpty {
                    return content
                }
            }
        }

        // Fallback: direct grep
        let safeQuery = query.replacingOccurrences(of: "'", with: "\\'")
        let cmd = "grep -ri '\(safeQuery)' '\(vaultPath)' --include='*.md' -l | head -5"
        let result = await shell(cmd)

        if result.exitCode == 0 && !result.stdout.isEmpty {
            let files = result.stdout
                .components(separatedBy: "\n")
                .filter { !$0.isEmpty }
                .prefix(5)
                .map { ($0 as NSString).lastPathComponent.replacingOccurrences(of: ".md", with: "") }

            return "Found notes: \(files.joined(separator: ", "))"
        }

        return "No vault notes found for '\(query)'."
    }

    // MARK: - Slack Post Message

    /// Posts via the Claude CLI Slack MCP session (reuses the existing authenticated connection).
    private static func executeSlackPostMessage(channelID: String, text: String) async -> String {
        guard !channelID.isEmpty, !text.isEmpty else {
            return "Missing channel_id or text for Slack message."
        }

        // Prefer curl to the Slack API using the secret token (avoids Claude CLI round-trip latency)
        let secretPath = "/Volumes/data/secrets/slack_bot_token"
        if FileManager.default.fileExists(atPath: secretPath),
           let tokenData = try? Data(contentsOf: URL(fileURLWithPath: secretPath)),
           let token = String(data: tokenData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
           !token.isEmpty {
            return await postSlackDirect(channelID: channelID, text: text, token: token)
        }

        // Fallback: delegate to Claude CLI which has the Slack MCP session
        let safeText = text.replacingOccurrences(of: "'", with: "\\'")
        let prompt = "Use the slack_post_message tool to post this exact message to channel \(channelID): \(safeText). Only call the tool, do not add any commentary."
        let result = await runClaudeCLI(
            prompt: prompt,
            allowedTools: "mcp__Slack__slack_post_message"
        )

        if result.exitCode == 0 && !result.stdout.isEmpty {
            return "Message posted to Slack."
        }

        logger.error("[MCPToolExecutor] NHR: Slack post failed. stderr=\(result.stderr)")
        return "Slack post failed. Check logs for NHR diagnosis."
    }

    private static func postSlackDirect(channelID: String, text: String, token: String) async -> String {
        let message = "Charlie (via Sonique): \(text)".replacingOccurrences(of: "\"", with: "\\\"")
        let cmd = """
        curl -sf -X POST https://slack.com/api/chat.postMessage \
          -H 'Authorization: Bearer \(token)' \
          -H 'Content-Type: application/json' \
          -d '{"channel":"\(channelID)","text":"\(message)"}'
        """
        let result = await shell(cmd)
        if result.exitCode == 0 && result.stdout.contains("\"ok\":true") {
            return "Posted to Slack channel \(channelID)."
        }
        logger.error("[MCPToolExecutor] NHR: Direct Slack post failed. stdout=\(result.stdout) stderr=\(result.stderr)")
        return "Slack post failed (direct): \(result.stdout.prefix(200))"
    }

    // MARK: - NotebookLM Query

    /// Queries NotebookLM via the Claude CLI. NotebookLM doesn't expose a standard MCP endpoint,
    /// so we rely on Claude's browser tool to navigate and query it, or fall back to a vault search.
    private static func executeNotebookLMQuery(query: String) async -> String {
        guard !query.isEmpty else { return "No query provided for NotebookLM." }

        let safeQuery = query.replacingOccurrences(of: "'", with: "\\'")
        let prompt = "The user wants to query their NotebookLM notebooks. Query: \(safeQuery). Use your available tools to answer this from their notebooks or research materials. Summarise in 2-3 sentences."

        let result = await runClaudeCLI(
            prompt: prompt,
            allowedTools: "Bash WebFetch"
        )

        if result.exitCode == 0 && !result.stdout.isEmpty {
            return result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        // Fallback: vault search for same query
        logger.warning("[MCPToolExecutor] NotebookLM CLI query failed, falling back to vault search")
        return await executeVaultSearch(query: query)
    }

    // MARK: - Generic Claude CLI Delegation

    private static func delegateToClaudeCLI(tool: String, input: [String: Any]) async -> String {
        guard let inputData = try? JSONSerialization.data(withJSONObject: input),
              let inputJSON = String(data: inputData, encoding: .utf8) else {
            return "Failed to serialize input for tool \(tool)."
        }

        let safeTool = tool.replacingOccurrences(of: "'", with: "\\'")
        let safeInput = inputJSON.replacingOccurrences(of: "'", with: "\\'")
        let prompt = "Call the tool '\(safeTool)' with these parameters: \(safeInput). Return only the tool result."

        let result = await runClaudeCLI(prompt: prompt, allowedTools: tool)

        if result.exitCode == 0 && !result.stdout.isEmpty {
            return result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        logger.error("[MCPToolExecutor] NHR: Generic delegation failed for tool '\(tool)'. stderr=\(result.stderr.prefix(400))")
        return "Tool '\(tool)' execution failed. stderr: \(result.stderr.prefix(200))"
    }

    // MARK: - Claude CLI Runner

    private static func runClaudeCLI(
        prompt: String,
        allowedTools: String,
        timeout: Int = 30
    ) async -> (stdout: String, stderr: String, exitCode: Int32) {
        let claudePath = FileManager.default.fileExists(atPath: "/opt/homebrew/bin/claude")
            ? "/opt/homebrew/bin/claude"
            : "claude"

        let safePrompt = prompt.replacingOccurrences(of: "'", with: "'\\''")
        let cmd = """
        timeout \(timeout) '\(claudePath)' --print --model haiku \
          --allowedTools '\(allowedTools)' \
          --permission-mode acceptEdits \
          '\(safePrompt)' 2>&1
        """

        return await shell(cmd)
    }

    // MARK: - Shell Helper

    static func shell(_ command: String) async -> (stdout: String, stderr: String, exitCode: Int32) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-c", command]

        let homeDir = FileManager.default.homeDirectoryForCurrentUser.path
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "\(homeDir)/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        if let dockerHost = env["DOCKER_HOST"], dockerHost.contains("podman") {
            env.removeValue(forKey: "DOCKER_HOST")
        }
        process.environment = env

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        do {
            try process.run()
            process.waitUntilExit()

            let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
            let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()

            return (
                String(data: stdoutData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
                String(data: stderrData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
                process.terminationStatus
            )
        } catch {
            return ("", error.localizedDescription, -1)
        }
    }
}
