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

        guard result.exitCode == 0 else {
            print("[TaskDispatcher] Shell command failed (exit \(result.exitCode)): \(result.stderr)")
            print("[TaskDispatcher] stdout was: \(result.stdout)")
            return nil
        }

        print("[TaskDispatcher] Raw response: \(result.stdout)")

        // Extract JSON from response - handle markdown fences, multi-line output, etc
        var jsonString = result.stdout

        // Try markdown code fence first
        if let jsonStart = jsonString.range(of: "```json\n"),
           let jsonEnd = jsonString.range(of: "\n```", range: jsonStart.upperBound..<jsonString.endIndex) {
            jsonString = String(jsonString[jsonStart.upperBound..<jsonEnd.lowerBound])
        } else if let jsonStart = jsonString.range(of: "```\n"),
                  let jsonEnd = jsonString.range(of: "\n```", range: jsonStart.upperBound..<jsonString.endIndex) {
            jsonString = String(jsonString[jsonStart.upperBound..<jsonEnd.lowerBound])
        } else {
            // No markdown fence - find the actual task metadata JSON object
            // Look for object with required fields: project, type, effort, description, owner
            let lines = jsonString.components(separatedBy: .newlines)
            var jsonLines: [String] = []
            var inObject = false
            var braceCount = 0

            for line in lines {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("{") {
                    inObject = true
                    braceCount = 1
                    jsonLines = [line]
                } else if inObject {
                    jsonLines.append(line)
                    braceCount += line.filter { $0 == "{" }.count
                    braceCount -= line.filter { $0 == "}" }.count
                    if braceCount == 0 {
                        // Complete object found
                        let candidate = jsonLines.joined(separator: "\n")
                        if candidate.contains("\"type\"") && candidate.contains("\"effort\"") {
                            jsonString = candidate
                            break
                        }
                        inObject = false
                    }
                }
            }
        }

        guard let data = jsonString.trimmingCharacters(in: .whitespacesAndNewlines).data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            print("[TaskDispatcher] Failed to parse JSON from response: \(result.stdout)")
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
        ## Prior Lessons
        Run `read-lessons \(project.lowercased())` before starting. Check for patterns related to this task type.

        ## Goal
        \(metadata.description)

        ## Context
        Project: \(project)
        Type: \(metadata.type)
        Source: Voice command from Charlie via Sonique
        \(context.isEmpty ? "" : "\nAdditional context: \(context)")

        ## Steps
        1. Read relevant lessons for this project/domain
        2. Investigate current state and identify exact changes needed
        3. Implement changes following project conventions
        4. Test changes work as expected
        5. Commit to git with descriptive message

        ## Dependencies
        - Project repo must be accessible
        - Required tools/frameworks installed
        - Any service dependencies running

        ## Potential Issues
        - Project conventions may differ from assumptions
        - Dependencies may need updates
        - Related code may need refactoring for consistency

        ## Research Questions
        ```bash
        # Verify project exists and is accessible
        ls -la ~/Projects/\(project.lowercased()) 2>/dev/null || echo "Project not found"

        # Check git status
        cd ~/Projects/\(project.lowercased()) && git status

        # Search for related code
        grep -r "relevant_pattern" ~/Projects/\(project.lowercased())/
        ```

        ## Expected Output
        \(metadata.description) - fully implemented and tested
        - Code changes committed to git
        - Verification commands pass

        ## Success
        - Feature/fix works as described
        - Tests pass (or manual verification succeeds)
        - Code committed to repo with descriptive message

        ## Verification
        ```bash
        # Verify commit exists
        cd ~/Projects/\(project.lowercased()) && git log -1 --oneline

        # Run project-specific tests if available
        # [Agent to add project-specific verification]
        ```

        ## Security Review
        - No credentials in code
        - Input validation where applicable
        - No SQL injection or XSS vulnerabilities
        - Secrets read from /Volumes/data/secrets/ if needed

        ## Functional Test
        Agent should perform end-to-end test of the implemented functionality.
        Document test steps in completion summary.

        ## Recovery
        If blocked: mark as needs_human_review with diagnosis
        If tools missing: install or escalate to CHARLIE
        If unclear requirements: ask for clarification in #cael

        ## QA Checklist
        - [ ] Code compiles/builds
        - [ ] Tests pass (or manual verification successful)
        - [ ] No console errors
        - [ ] Matches requirements
        - [ ] Committed to git

        ## Validation Markers
        - Git commit SHA in completion summary
        - Test output showing success
        - For deployed changes: health check endpoints responding

        ## Rollback
        Git revert if needed: `cd ~/Projects/\(project.lowercased()) && git revert HEAD`
        For production config changes: document specific rollback steps in completion.

        ## Scope Boundary
        IN SCOPE:
        - \(metadata.description)
        - Related tests/fixes required for this change

        OUT OF SCOPE:
        - Unrelated features or refactoring
        - Documentation updates (unless critical)
        - Performance optimization (unless part of the fix)

        ## Assumptions
        - Standard project setup and tooling in place
        - No breaking changes to existing functionality required
        - Project follows established conventions

        ## Handoff Notes
        This task was created via voice command to Sonique. If requirements are unclear, ask Charlie for clarification in #cael or via voice.
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
