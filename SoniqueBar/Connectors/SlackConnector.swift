import Foundation

/// Connector for Slack messaging
/// Allows Quinn to post messages to Slack channels
struct SlackConnector: ActionConnector {
    let id = UUID()
    let name = "Slack"
    let version = "1.0.0"
    let description = "Send messages to Slack channels"
    let category: ConnectorCategory = .communication
    var isEnabled: Bool

    private let defaultChannel: String
    private let botTokenPath: String

    /// Initialize with config (preferred)
    init(config: SlackConfig, enabled: Bool = true) {
        self.defaultChannel = config.defaultChannel
        self.botTokenPath = config.botTokenPath
        self.isEnabled = enabled
    }

    /// Initialize with legacy hardcoded values (fallback)
    init() {
        self.defaultChannel = "#cael"
        self.botTokenPath = "/Volumes/data/secrets/slack_bot_token"
        self.isEnabled = true
    }

    var capabilities: [ConnectorCapability] {
        [
            .init(
                name: "post_message",
                description: "Post a message to a Slack channel",
                parameters: [
                    .init(name: "channel", type: .string, required: true, description: "Channel name (without #)"),
                    .init(name: "text", type: .string, required: true, description: "Message text"),
                    .init(name: "priority", type: .enumeration(["low", "normal", "high"]), required: false, defaultValue: "normal", description: "Message priority")
                ],
                requiredAuth: .apiKey(key: getSlackToken(), headerName: "Authorization"),
                mutates: true
            ),
            .init(
                name: "list_channels",
                description: "List available Slack channels",
                parameters: [],
                requiredAuth: .apiKey(key: getSlackToken(), headerName: "Authorization"),
                mutates: false
            )
        ]
    }

    // MARK: - Execution

    func execute(_ capability: String, parameters: [String: Any]) async throws -> ConnectorResult {
        switch capability {
        case "post_message":
            return try await postMessage(parameters)
        case "list_channels":
            return try await listChannels()
        default:
            throw ConnectorError.unknownCapability(capability)
        }
    }

    func healthCheck() async -> Bool {
        guard let url = URL(string: "https://slack.com/api/auth.test") else { return false }
        var request = ConnectorErrorHandler.request(url: url)
        request.setValue("Bearer \(getSlackToken())", forHTTPHeaderField: "Authorization")
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            return (response as? HTTPURLResponse)?.statusCode == 200
        } catch {
            return false
        }
    }

    // MARK: - Private Implementation

    private func postMessage(_ params: [String: Any]) async throws -> ConnectorResult {
        guard let channel = params["channel"] as? String,
              let text = params["text"] as? String else {
            throw ConnectorError.missingParameter("channel or text")
        }

        let priority = params["priority"] as? String ?? "normal"

        // Use slack-post-filtered if available for priority routing
        let result = await shell("slack-post-filtered \(channel) \"\(text)\" --priority=\(priority)")

        guard result.exitCode == 0 else {
            // Fallback to direct Slack API
            return try await postMessageDirect(channel: channel, text: text)
        }

        return .success(message: "Posted to #\(channel)")
    }

    private func postMessageDirect(channel: String, text: String) async throws -> ConnectorResult {
        guard let url = URL(string: "https://slack.com/api/chat.postMessage") else {
            throw ConnectorError.connectionFailed
        }

        let payload: [String: Any] = ["channel": channel, "text": text]

        var request = ConnectorErrorHandler.request(url: url, method: "POST")
        request.setValue("Bearer \(getSlackToken())", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let (data, response) = try await ConnectorErrorHandler.withRetry(connectorName: name) {
            try await URLSession.shared.data(for: request)
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw ConnectorError.connectionFailed
        }

        switch httpResponse.statusCode {
        case 200:
            break
        case 401, 403:
            throw ConnectorError.authenticationFailed
        case 429:
            throw ConnectorError.rateLimitExceeded
        default:
            throw ConnectorError.invalidResponse("HTTP \(httpResponse.statusCode)")
        }

        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let ok = json["ok"] as? Bool, ok {
            return .success(message: "Posted to #\(channel)")
        }

        // Slack returns 200 even for API errors; check the error field without logging token or body
        throw ConnectorError.invalidResponse("Slack API returned ok=false")
    }

    private func listChannels() async throws -> ConnectorResult {
        guard let url = URL(string: "https://slack.com/api/conversations.list") else {
            throw ConnectorError.connectionFailed
        }

        var request = ConnectorErrorHandler.request(url: url)
        request.setValue("Bearer \(getSlackToken())", forHTTPHeaderField: "Authorization")

        let (data, response) = try await ConnectorErrorHandler.withRetry(connectorName: name) {
            try await URLSession.shared.data(for: request)
        }

        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            throw ConnectorError.connectionFailed
        }

        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let channels = json["channels"] as? [[String: Any]] {
            let channelNames = channels.compactMap { $0["name"] as? String }
            return .success(
                message: "Found \(channelNames.count) channels",
                data: ["channels": channelNames]
            )
        }

        throw ConnectorError.invalidResponse("Could not parse channel list")
    }

    // MARK: - Helper

    /// Execute shell command (reuses InfrastructureExecutor pattern)
    private func shell(_ command: String) async -> (stdout: String, stderr: String, exitCode: Int32) {
        let task = Process()
        task.launchPath = "/bin/zsh"
        task.arguments = ["-c", command]

        let outPipe = Pipe()
        let errPipe = Pipe()
        task.standardOutput = outPipe
        task.standardError = errPipe

        do {
            try task.run()
            task.waitUntilExit()

            let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
            let errData = errPipe.fileHandleForReading.readDataToEndOfFile()

            let stdout = String(data: outData, encoding: .utf8) ?? ""
            let stderr = String(data: errData, encoding: .utf8) ?? ""

            return (stdout, stderr, task.terminationStatus)
        } catch {
            return ("", error.localizedDescription, -1)
        }
    }

    /// Read Slack token from secure location
    private func getSlackToken() -> String {
        if let token = try? String(contentsOfFile: botTokenPath, encoding: .utf8) {
            return token.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        print("[SlackConnector] WARNING: Could not read Slack token from \(botTokenPath)")
        return ""
    }
}
