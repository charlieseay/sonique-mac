import Foundation

/// Task decomposition - breaks complex requests into executable subtasks
@MainActor
class TaskDecomposer {
    static let shared = TaskDecomposer()

    private init() {}

    /// Decompose a complex task into actionable subtasks
    func decompose(task: String) async throws -> [SubTask] {
        // Use LLM to break down the task
        let prompt = """
        Break down this task into 3-5 specific, actionable subtasks.

        Task: \(task)

        Return a JSON array of subtasks with this format:
        [
          {
            "description": "Clear action to take",
            "connector": "name of connector to use (helmsman, docker, slack, github, obsidian, or null)",
            "parameters": {"key": "value"}
          }
        ]

        Only return the JSON array, no explanation.
        """

        let response = try await LLMRouter.shared.complete(prompt: prompt, preferredModel: "sonnet")

        // Parse JSON response
        guard let data = response.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw TaskDecomposerError.parseError
        }

        return json.compactMap { dict in
            guard let description = dict["description"] as? String else { return nil }

            let connector = dict["connector"] as? String
            let parameters = dict["parameters"] as? [String: Any] ?? [:]

            return SubTask(
                description: description,
                connector: connector,
                parameters: parameters
            )
        }
    }

    /// Execute a subtask using the appropriate connector
    func execute(subtask: SubTask) async throws -> String {
        guard let connectorName = subtask.connector else {
            // No connector specified - this is a manual task
            return "Manual action required: \(subtask.description)"
        }

        // Execute via ConnectorRegistry
        do {
            let result = try await ConnectorRegistry.shared.execute(
                capability: connectorName,
                parameters: subtask.parameters
            )

            return result.message
        } catch {
            throw TaskDecomposerError.executionFailed(error.localizedDescription)
        }
    }
}

// MARK: - Types

struct SubTask: Identifiable {
    let id = UUID()
    let description: String
    let connector: String?
    let parameters: [String: Any]
}

enum TaskDecomposerError: Error, LocalizedError {
    case parseError
    case executionFailed(String)

    var errorDescription: String? {
        switch self {
        case .parseError:
            return "Failed to parse task breakdown"
        case .executionFailed(let message):
            return "Task execution failed: \(message)"
        }
    }
}
