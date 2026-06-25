import Foundation

/// Connector for Helmsman task dispatch webhook
/// Allows Quinn to create tasks and query the task queue
struct HelmsmanConnector: ActionConnector {
    let id = UUID()
    let name = "Task Management"  // Generic, not brand-specific
    let version = "1.0.0"
    let description = "Create and manage tasks"  // Generic description
    let category: ConnectorCategory = .taskManagement
    var isEnabled: Bool = true

    /// Endpoint for Helmsman webhook (TODO: make configurable)
    private let endpoint = "http://localhost:5680/webhook/task-dispatch"

    /// REST API endpoint for queries (TODO: make configurable)
    private let queryEndpoint = "http://localhost:5682"

    var capabilities: [ConnectorCapability] {
        [
            .init(
                name: "create_task",
                description: "Create a new task in Helmsman queue",
                parameters: [
                    .init(name: "task", type: .string, required: true, description: "Task description"),
                    .init(name: "owner", type: .enumeration(["CLAUDE", "NVIDIA-BAL", "AIDER-GEM", "CHARLIE"]), required: true, description: "Who should execute this task"),
                    .init(name: "project", type: .string, required: true, description: "Project name"),
                    .init(name: "effort", type: .enumeration(["S", "M", "L", "XL"]), required: true, description: "Effort estimate"),
                    .init(name: "context", type: .string, required: false, description: "Additional context for the task")
                ],
                requiredAuth: .bearer(token: getDispatchSecret()),
                mutates: true
            ),
            .init(
                name: "query_queue",
                description: "Get pending tasks from Helmsman queue",
                parameters: [
                    .init(name: "status", type: .enumeration(["pending", "running", "done", "cancelled"]), required: false, description: "Filter by status"),
                    .init(name: "owner", type: .string, required: false, description: "Filter by owner")
                ],
                requiredAuth: .none,
                mutates: false
            ),
            .init(
                name: "get_task",
                description: "Get details of a specific task",
                parameters: [
                    .init(name: "task_num", type: .integer, required: true, description: "Task number")
                ],
                requiredAuth: .none,
                mutates: false
            )
        ]
    }

    // MARK: - Execution

    func execute(_ capability: String, parameters: [String: Any]) async throws -> ConnectorResult {
        switch capability {
        case "create_task":
            return try await createTask(parameters)
        case "query_queue":
            return try await queryQueue(parameters)
        case "get_task":
            return try await getTask(parameters)
        default:
            throw ConnectorError.unknownCapability(capability)
        }
    }

    func healthCheck() async -> Bool {
        // Check if helmsman-db REST API is reachable
        guard let url = URL(string: "\(queryEndpoint)/health") else {
            return false
        }

        do {
            let (_, response) = try await URLSession.shared.data(from: url)
            guard let httpResponse = response as? HTTPURLResponse else {
                return false
            }
            return httpResponse.statusCode == 200
        } catch {
            return false
        }
    }

    // MARK: - Private Implementation

    private func createTask(_ params: [String: Any]) async throws -> ConnectorResult {
        guard let task = params["task"] as? String,
              let owner = params["owner"] as? String,
              let project = params["project"] as? String,
              let effort = params["effort"] as? String else {
            throw ConnectorError.missingParameter("task, owner, project, or effort")
        }

        let context = params["context"] as? String ?? ""

        // Build payload
        let payload: [String: Any] = [
            "task": task,
            "owner": owner,
            "project": project,
            "effort": effort,
            "context": context
        ]

        // Get dispatch secret
        let secret = getDispatchSecret()

        guard let url = URL(string: endpoint) else {
            throw ConnectorError.connectionFailed
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(secret)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)

        // Execute
        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw ConnectorError.connectionFailed
        }

        guard httpResponse.statusCode == 200 else {
            let errorMessage = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw ConnectorError.invalidResponse("HTTP \(httpResponse.statusCode): \(errorMessage)")
        }

        // Parse response
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            let taskNum = json["task_num"] as? Int ?? 0
            return .success(
                message: "Task #\(taskNum) created",
                data: json
            )
        }

        return .success(message: "Task created successfully")
    }

    private func queryQueue(_ params: [String: Any]) async throws -> ConnectorResult {
        var urlComponents = URLComponents(string: "\(queryEndpoint)/tasks")!

        // Add query parameters
        var queryItems: [URLQueryItem] = []

        if let status = params["status"] as? String {
            queryItems.append(URLQueryItem(name: "status", value: status))
        }

        if let owner = params["owner"] as? String {
            queryItems.append(URLQueryItem(name: "owner", value: owner))
        }

        if !queryItems.isEmpty {
            urlComponents.queryItems = queryItems
        }

        guard let url = urlComponents.url else {
            throw ConnectorError.connectionFailed
        }

        // Execute query
        let (data, response) = try await URLSession.shared.data(from: url)

        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            throw ConnectorError.connectionFailed
        }

        // Parse response
        if let tasks = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
            let count = tasks.count
            return .success(
                message: "Found \(count) task(s)",
                data: ["tasks": tasks, "count": count]
            )
        }

        throw ConnectorError.invalidResponse("Could not parse task list")
    }

    private func getTask(_ params: [String: Any]) async throws -> ConnectorResult {
        guard let taskNum = params["task_num"] as? Int else {
            throw ConnectorError.missingParameter("task_num")
        }

        guard let url = URL(string: "\(queryEndpoint)/tasks/\(taskNum)") else {
            throw ConnectorError.connectionFailed
        }

        let (data, response) = try await URLSession.shared.data(from: url)

        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            throw ConnectorError.connectionFailed
        }

        if let task = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            return .success(
                message: "Task #\(taskNum)",
                data: task
            )
        }

        throw ConnectorError.invalidResponse("Could not parse task details")
    }

    // MARK: - Helper

    /// Read dispatch secret from secure location
    private func getDispatchSecret() -> String {
        let secretPath = "/Volumes/data/secrets/dispatch_webhook_secret"

        if let secret = try? String(contentsOfFile: secretPath, encoding: .utf8) {
            return secret.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        print("[HelmsmanConnector] WARNING: Could not read dispatch secret from \(secretPath)")
        return ""
    }
}
