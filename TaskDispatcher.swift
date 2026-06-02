import Foundation

/// Handles task creation and dispatch to Helmsman
struct TaskDispatcher {

    struct TaskMetadata {
        let project: String?
        let type: String  // feature, bug, chore
        let effort: String  // S, M, L, XL
        let description: String
        let owner: String?
    }

    enum DispatchError: Error {
        case invalidResponse
        case networkError(String)
        case missingSecret
    }

    // MARK: - Entity Extraction

    static func extractTaskMetadata(from text: String) async -> TaskMetadata? {
        let prompt = """
        Extract structured task metadata from this request:
        "\(text)"

        Return ONLY valid JSON (no markdown, no explanation):
        {
          "project": "StoryChat" or "Bridge" or "Helmsman" or null,
          "type": "feature" or "bug" or "chore",
          "effort": "S" or "M" or "L" or "XL",
          "description": "one-line summary",
          "owner": "AIDER-GEM" or "nvidia-agent" or "CLAUDE" or null
        }

        Guidelines:
        - project: Match to known projects (StoryChat, Bridge, Helmsman, Hone, Sonique). If unclear, use null.
        - type: feature = new capability, bug = fix broken, chore = maintenance
        - effort: S = <1h, M = 1-4h, L = 1-2d, XL = >2d
        - description: Brief, actionable summary
        - owner: AIDER-GEM for code/UI, nvidia-agent for analysis, CLAUDE for design/specs. If unclear, use null.
        """

        let result = await InfrastructureExecutor.shell("ask_helmsman '\(prompt.replacingOccurrences(of: "'", with: "'\\''"))'")

        guard result.exitCode == 0,
              let data = result.stdout.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            print("[TaskDispatcher] Failed to extract metadata: \(result.stderr)")
            return nil
        }

        guard let type = json["type"] as? String,
              let effort = json["effort"] as? String,
              let description = json["description"] as? String else {
            print("[TaskDispatcher] Missing required fields in metadata")
            return nil
        }

        return TaskMetadata(
            project: json["project"] as? String,
            type: type,
            effort: effort,
            description: description,
            owner: json["owner"] as? String
        )
    }

    // MARK: - Brief Generation

    static func generateBrief(from metadata: TaskMetadata, context: String) -> String {
        let project = metadata.project ?? "[OPERATOR TO SUPPLY]"
        let owner = metadata.owner ?? "[OPERATOR TO SUPPLY]"

        return """
        ## Goal
        \(metadata.description)

        ## Context
        Project: \(project)
        Type: \(metadata.type)
        Source: Voice command from Charlie
        \(context.isEmpty ? "" : "\nAdditional context: \(context)")

        ## Steps
        [OPERATOR TO SUPPLY - or agent to determine based on goal]

        ## Dependencies
        - Project repo must be accessible
        - Required tools/frameworks installed
        [Add specific dependencies as needed]

        ## Potential Issues
        [OPERATOR TO SUPPLY - or agent to identify during investigation]

        ## Research Questions
        [OPERATOR TO SUPPLY - or agent to determine what needs investigation first]

        ## Expected Output
        \(metadata.description) - fully implemented and tested

        ## Success
        - Feature/fix works as described
        - Tests pass
        - Code committed to repo

        ## Verification
        [OPERATOR TO SUPPLY - specific commands to verify the work]

        ## Security Review
        - No credentials in code
        - Input validation where applicable
        - No SQL injection or XSS vulnerabilities

        ## Functional Test
        [OPERATOR TO SUPPLY - manual test steps to verify end-to-end]

        ## Recovery
        If blocked: mark as needs_human_review with diagnosis
        If tools missing: install or escalate

        ## QA Checklist
        - [ ] Code compiles/builds
        - [ ] Tests pass
        - [ ] No console errors
        - [ ] Matches requirements

        ## Validation Markers
        [OPERATOR TO SUPPLY - production signals that prove it works]

        ## Rollback
        Git revert if needed
        [Add specific rollback steps if touching production config]

        ## Scope Boundary
        OUT OF SCOPE:
        - Related features not explicitly requested
        - Refactoring beyond what's needed for this change
        - Documentation updates (unless critical)

        ## Assumptions
        - Standard project setup and tooling in place
        - No breaking changes to existing functionality required

        ## Handoff Notes
        This task was created via voice command. If requirements unclear, ask Charlie for clarification in #cael.
        """
    }

    // MARK: - Dispatch

    static func dispatch(task: String, owner: String, project: String, effort: String, brief: String) async throws -> Int {
        // Read dispatch secret
        let secretPath = "/Volumes/data/secrets/dispatch_webhook_secret"
        guard let secret = try? String(contentsOfFile: secretPath).trimmingCharacters(in: .whitespacesAndNewlines) else {
            throw DispatchError.missingSecret
        }

        // Escape brief for JSON
        let escapedBrief = brief
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")

        let payload = """
        {
          "task": "\(task.replacingOccurrences(of: "\"", with: "\\\""))",
          "owner": "\(owner)",
          "project": "\(project)",
          "effort": "\(effort)",
          "brief_text": "\(escapedBrief)"
        }
        """

        // Write payload to temp file to avoid shell escaping issues
        let tempFile = "/tmp/sonique-dispatch-\(UUID().uuidString).json"
        try payload.write(toFile: tempFile, atomically: true, encoding: .utf8)

        let command = """
        curl -s -X POST http://localhost:5680/webhook/task-dispatch \
          -H 'Content-Type: application/json' \
          -H 'X-Dispatch-Secret: \(secret)' \
          -d @\(tempFile) && rm \(tempFile)
        """

        let result = await InfrastructureExecutor.shell(command)

        guard result.exitCode == 0 else {
            throw DispatchError.networkError(result.stderr)
        }

        // Parse response
        guard let data = result.stdout.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let taskNum = json["task_num"] as? Int else {
            throw DispatchError.invalidResponse
        }

        return taskNum
    }
}
