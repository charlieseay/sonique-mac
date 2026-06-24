import Foundation

/// Connector for GitHub operations via gh CLI
/// Allows Quinn to create issues, check PR status, and view CI results
struct GitHubConnector: ActionConnector {
    let id = UUID()
    let name = "GitHub"
    let version = "1.0.0"
    let description = "Manage GitHub issues, PRs, and CI status"
    let category: ConnectorCategory = .development
    var isEnabled: Bool = true

    var capabilities: [ConnectorCapability] {
        [
            .init(
                name: "create_issue",
                description: "Create a GitHub issue",
                parameters: [
                    .init(name: "repo", type: .string, required: true, description: "Repository (owner/repo)"),
                    .init(name: "title", type: .string, required: true, description: "Issue title"),
                    .init(name: "body", type: .string, required: false, description: "Issue body")
                ],
                requiredAuth: .none, // gh CLI handles auth
                mutates: true
            ),
            .init(
                name: "list_prs",
                description: "List open pull requests",
                parameters: [
                    .init(name: "repo", type: .string, required: true, description: "Repository (owner/repo)")
                ],
                requiredAuth: .none,
                mutates: false
            ),
            .init(
                name: "check_ci",
                description: "Check CI status for a PR",
                parameters: [
                    .init(name: "repo", type: .string, required: true, description: "Repository (owner/repo)"),
                    .init(name: "pr", type: .integer, required: true, description: "PR number")
                ],
                requiredAuth: .none,
                mutates: false
            )
        ]
    }

    // MARK: - Execution

    func execute(_ capability: String, parameters: [String: Any]) async throws -> ConnectorResult {
        switch capability {
        case "create_issue":
            return try await createIssue(parameters)
        case "list_prs":
            return try await listPRs(parameters)
        case "check_ci":
            return try await checkCI(parameters)
        default:
            throw ConnectorError.unknownCapability(capability)
        }
    }

    func healthCheck() async -> Bool {
        // Check if gh CLI is available and authenticated
        let result = await shell("which gh")
        guard result.exitCode == 0 else { return false }

        let authCheck = await shell("gh auth status")
        return authCheck.exitCode == 0
    }

    // MARK: - Private Implementation

    private func createIssue(_ params: [String: Any]) async throws -> ConnectorResult {
        guard let repo = params["repo"] as? String,
              let title = params["title"] as? String else {
            throw ConnectorError.missingParameter("repo or title")
        }

        let body = params["body"] as? String ?? ""

        var command = "gh issue create --repo \(repo) --title \"\(title)\""
        if !body.isEmpty {
            command += " --body \"\(body)\""
        }

        let result = await shell(command)

        guard result.exitCode == 0 else {
            throw ConnectorError.invalidResponse(result.stderr)
        }

        // Extract issue URL from output
        let issueURL = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)

        return .success(
            message: "Created issue",
            data: ["url": issueURL]
        )
    }

    private func listPRs(_ params: [String: Any]) async throws -> ConnectorResult {
        guard let repo = params["repo"] as? String else {
            throw ConnectorError.missingParameter("repo")
        }

        let result = await shell("gh pr list --repo \(repo) --json number,title,author,state --limit 10")

        guard result.exitCode == 0 else {
            throw ConnectorError.invalidResponse(result.stderr)
        }

        guard let data = result.stdout.data(using: .utf8),
              let prs = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw ConnectorError.invalidResponse("Could not parse PR list")
        }

        let count = prs.count
        let message = count == 0 ? "No open PRs" : "Found \(count) open PR(s)"

        return .success(
            message: message,
            data: ["prs": prs]
        )
    }

    private func checkCI(_ params: [String: Any]) async throws -> ConnectorResult {
        guard let repo = params["repo"] as? String,
              let prNumber = params["pr"] as? Int else {
            throw ConnectorError.missingParameter("repo or pr")
        }

        let result = await shell("gh pr checks \(prNumber) --repo \(repo)")

        guard result.exitCode == 0 else {
            throw ConnectorError.invalidResponse(result.stderr)
        }

        let output = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        let lines = output.components(separatedBy: "\n")

        // Parse CI status (format: "✓ check-name\tpass\t...")
        var passing = 0
        var failing = 0

        for line in lines {
            if line.contains("✓") || line.lowercased().contains("pass") {
                passing += 1
            } else if line.contains("✗") || line.lowercased().contains("fail") {
                failing += 1
            }
        }

        let message: String
        if failing > 0 {
            message = "\(failing) check(s) failing, \(passing) passing"
        } else if passing > 0 {
            message = "All \(passing) check(s) passing"
        } else {
            message = "No checks found"
        }

        return .success(
            message: message,
            data: [
                "passing": passing,
                "failing": failing,
                "details": output
            ]
        )
    }

    // MARK: - Helper

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
}
