import Foundation

/// Handles POST /intent/* routes from iOS App Intents.
/// Delegates to existing connectors and REST/CLI backends with safe parameter handling.
enum IntentHandlers {

    struct Response: Codable {
        let success: Bool
        let message: String
        let error: String?
        let data: [String: String]?

        static func ok(_ message: String, data: [String: String]? = nil) -> Response {
            Response(success: true, message: message, error: nil, data: data)
        }

        static func fail(_ code: String, message: String) -> Response {
            Response(success: false, message: message, error: code, data: nil)
        }
    }

    // MARK: - Slack

    static func handleSlack(_ params: [String: Any]) async -> Response {
        guard let message = params["message"] as? String,
              !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .fail("missing_message", message: "Message is required.")
        }

        let channel = sanitizeChannel(params["channel"] as? String ?? "sonique")
        let connector = SlackConnector()

        do {
            let result = try await connector.execute("post_message", parameters: [
                "channel": channel,
                "text": message,
                "priority": "normal"
            ])
            if result.success {
                return .ok(result.message, data: stringData(result.data))
            }
            return .fail("slack_failed", message: result.error ?? "Failed to post to Slack.")
        } catch {
            if getSlackToken().isEmpty {
                return .fail("slack_token_missing", message: "Slack token missing. Check Settings on the Mac.")
            }
            return .fail("slack_error", message: "Couldn't post to Slack.")
        }
    }

    // MARK: - Linear

    static func handleLinear(_ params: [String: Any]) async -> Response {
        guard let title = params["title"] as? String,
              !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .fail("missing_title", message: "Task title is required.")
        }

        let description = params["description"] as? String ?? ""

        // Prefer linear CLI if installed
        if await cliAvailable("linear") {
            return await createLinearViaCLI(title: title, description: description)
        }

        return await createLinearViaAPI(title: title, description: description)
    }

    // MARK: - GitHub

    static func handleGitHub(_ params: [String: Any]) async -> Response {
        let action = params["action"] as? String ?? "search"

        if action == "create_issue" {
            return await createGitHubIssue(params)
        }
        return await searchGitHubPRs(params)
    }

    // MARK: - Notion

    static func handleNotion(_ params: [String: Any]) async -> Response {
        guard let title = params["title"] as? String,
              !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .fail("missing_title", message: "Page title is required.")
        }

        let body = params["body"] as? String ?? ""
        let apiKey = readSecret("notion_api_key")
        guard !apiKey.isEmpty else {
            return .fail("notion_key_missing", message: "Notion API key not configured on the Mac.")
        }

        let databaseId = params["database_id"] as? String
            ?? readSecret("notion_database_id")
        guard !databaseId.isEmpty else {
            return .fail("notion_db_missing", message: "Notion database ID not configured.")
        }

        return await createNotionPage(apiKey: apiKey, databaseId: databaseId, title: title, body: body)
    }

    // MARK: - Docker

    static func handleDocker(_ params: [String: Any]) async -> Response {
        let showAll = (params["all"] as? String) == "true"
        let connector = DockerConnector()

        do {
            let result = try await connector.execute("list_containers", parameters: ["all": showAll])
            if result.success {
                return .ok(result.message, data: stringData(result.data))
            }
            return .fail("docker_failed", message: result.error ?? "Couldn't list containers.")
        } catch {
            return .fail("docker_error", message: "Docker isn't available right now.")
        }
    }

    // MARK: - Private: Slack helpers

    private static func getSlackToken() -> String {
        readSecret("slack_bot_token")
    }

    private static func sanitizeChannel(_ channel: String) -> String {
        let stripped = channel.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        return String(stripped.unicodeScalars.filter { allowed.contains($0) })
    }

    // MARK: - Private: Linear

    private static func createLinearViaCLI(title: String, description: String) async -> Response {
        var args = ["issue", "create", "--title", title]
        if !description.isEmpty {
            args += ["--description", description]
        }

        let result = await runProcess(executable: "/usr/bin/env", arguments: ["linear"] + args)
        if result.exitCode == 0 {
            let out = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            return .ok("Task created.", data: out.isEmpty ? nil : ["url": out])
        }
        return .fail("linear_cli_failed", message: "Linear CLI failed. Use the web app.")
    }

    private static func createLinearViaAPI(title: String, description: String) async -> Response {
        let apiKey = readSecret("linear_api_key")
        if apiKey.isEmpty {
            return .fail("linear_key_missing", message: "Linear CLI not found. Add linear_api_key to secrets.")
        }

        let teamId = readSecret("linear_team_id")
        let mutation = """
        mutation($title: String!, $description: String, $teamId: String!) {
          issueCreate(input: { title: $title, description: $description, teamId: $teamId }) {
            success
            issue { id identifier url }
          }
        }
        """
        let variables: [String: Any] = [
            "title": title,
            "description": description.isEmpty ? NSNull() : description,
            "teamId": teamId.isEmpty ? NSNull() : teamId
        ]

        guard let url = URL(string: "https://api.linear.app/graphql") else {
            return .fail("linear_error", message: "Linear API unavailable.")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: [
            "query": mutation,
            "variables": variables
        ])

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let dataObj = json["data"] as? [String: Any],
                  let create = dataObj["issueCreate"] as? [String: Any],
                  create["success"] as? Bool == true,
                  let issue = create["issue"] as? [String: Any],
                  let identifier = issue["identifier"] as? String else {
                return .fail("linear_api_failed", message: "Linear API rejected the request.")
            }
            return .ok("Task \(identifier) created.", data: ["identifier": identifier])
        } catch {
            return .fail("linear_api_down", message: "Linear API is down. Try again later.")
        }
    }

    // MARK: - Private: GitHub

    private static func searchGitHubPRs(_ params: [String: Any]) async -> Response {
        guard await cliAvailable("gh") else {
            return .fail("gh_missing", message: "GitHub CLI not installed on the Mac.")
        }

        let query = params["query"] as? String ?? ""
        let label = params["label"] as? String ?? query
        let repo = sanitizeRepo(params["repo"] as? String ?? "charlieseay/sonique-ios")

        var args = ["pr", "list", "--repo", repo, "--state", "open", "--json", "number,title,labels", "--limit", "20"]
        if !label.isEmpty {
            args += ["--label", label]
        }

        let result = await runProcess(executable: "/opt/homebrew/bin/gh", arguments: args, fallbackPath: "/usr/local/bin/gh")
        if result.exitCode != 0 {
            // Retry with /usr/bin/env gh
            let fallback = await runProcess(executable: "/usr/bin/env", arguments: ["gh"] + args)
            if fallback.exitCode != 0 {
                return .fail("github_search_failed", message: "Couldn't search pull requests.")
            }
            return parsePRSearchResult(fallback.stdout, label: label)
        }
        return parsePRSearchResult(result.stdout, label: label)
    }

    private static func parsePRSearchResult(_ stdout: String, label: String) -> Response {
        guard let data = stdout.data(using: .utf8),
              let prs = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return .fail("github_parse_failed", message: "Couldn't parse GitHub results.")
        }

        let count = prs.count
        if count == 0 {
            let msg = label.isEmpty ? "No open pull requests found." : "No open pull requests labeled \(label)."
            return .ok(msg, data: ["count": "0"])
        }

        let titles = prs.prefix(3).compactMap { pr -> String? in
            guard let num = pr["number"] as? Int, let title = pr["title"] as? String else { return nil }
            return "#\(num): \(title)"
        }.joined(separator: "; ")

        let msg = "Found \(count) open pull request\(count == 1 ? "" : "s"). \(titles)"
        return .ok(msg, data: ["count": "\(count)"])
    }

    private static func createGitHubIssue(_ params: [String: Any]) async -> Response {
        guard let title = params["title"] as? String, !title.isEmpty else {
            return .fail("missing_title", message: "Issue title is required.")
        }

        let repo = sanitizeRepo(params["repo"] as? String ?? "charlieseay/sonique-ios")
        let body = params["body"] as? String ?? ""
        let connector = GitHubConnector()

        do {
            var issueParams: [String: Any] = ["repo": repo, "title": title]
            if !body.isEmpty { issueParams["body"] = body }
            let result = try await connector.execute("create_issue", parameters: issueParams)
            if result.success {
                return .ok("GitHub issue created.", data: stringData(result.data))
            }
            return .fail("github_failed", message: result.error ?? "Couldn't create issue.")
        } catch {
            return .fail("github_error", message: "GitHub CLI failed. Check authentication.")
        }
    }

    // MARK: - Private: Notion

    private static func createNotionPage(apiKey: String, databaseId: String, title: String, body: String) async -> Response {
        guard let url = URL(string: "https://api.notion.com/v1/pages") else {
            return .fail("notion_error", message: "Notion API unavailable.")
        }

        var properties: [String: Any] = [
            "Name": ["title": [["text": ["content": title]]]]
        ]

        var children: [[String: Any]] = []
        if !body.isEmpty {
            children.append([
                "object": "block",
                "type": "paragraph",
                "paragraph": ["rich_text": [["text": ["content": body]]]]
            ])
        }

        var payload: [String: Any] = [
            "parent": ["database_id": databaseId],
            "properties": properties
        ]
        if !children.isEmpty {
            payload["children"] = children
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("2022-06-28", forHTTPHeaderField: "Notion-Version")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: payload)

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                return .fail("notion_error", message: "Notion request failed.")
            }
            if http.statusCode == 429 {
                return .fail("notion_rate_limit", message: "Creating note — Notion is busy. I'll tell you when it's done.")
            }
            guard http.statusCode == 200,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let pageId = json["id"] as? String else {
                return .fail("notion_failed", message: "Notion rejected the page. Check database schema.")
            }
            return .ok("Notion page created.", data: ["page_id": pageId])
        } catch {
            return .fail("notion_error", message: "Notion API is slow right now. Try again.")
        }
    }

    // MARK: - Utilities

    private static func readSecret(_ name: String) -> String {
        let path = "/Volumes/data/secrets/\(name)"
        return (try? String(contentsOfFile: path, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    private static func sanitizeRepo(_ repo: String) -> String {
        let trimmed = repo.trimmingCharacters(in: .whitespacesAndNewlines)
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_/"))
        return String(trimmed.unicodeScalars.filter { allowed.contains($0) })
    }

    private static func stringData(_ data: [String: Any]?) -> [String: String]? {
        guard let data else { return nil }
        var out: [String: String] = [:]
        for (key, value) in data {
            out[key] = "\(value)"
        }
        return out.isEmpty ? nil : out
    }

    private static func cliAvailable(_ name: String) async -> Bool {
        let result = await runProcess(executable: "/usr/bin/which", arguments: [name])
        return result.exitCode == 0 && !result.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private static func runProcess(
        executable: String,
        arguments: [String],
        fallbackPath: String? = nil
    ) async -> (stdout: String, stderr: String, exitCode: Int32) {
        let paths = [executable, fallbackPath].compactMap { $0 }
        for path in paths {
            let result = await runProcessOnce(executable: path, arguments: arguments)
            if result.exitCode == 0 || path == paths.last {
                return result
            }
        }
        return ("", "executable not found", -1)
    }

    private static func runProcessOnce(executable: String, arguments: [String]) async -> (stdout: String, stderr: String, exitCode: Int32) {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let task = Process()
                task.executableURL = URL(fileURLWithPath: executable)
                task.arguments = arguments

                let outPipe = Pipe()
                let errPipe = Pipe()
                task.standardOutput = outPipe
                task.standardError = errPipe

                do {
                    try task.run()
                    task.waitUntilExit()
                    let stdout = String(data: outPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                    let stderr = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                    continuation.resume(returning: (stdout, stderr, task.terminationStatus))
                } catch {
                    continuation.resume(returning: ("", error.localizedDescription, -1))
                }
            }
        }
    }
}
