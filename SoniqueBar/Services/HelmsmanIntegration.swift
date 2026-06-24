import Foundation

/// Deep Helmsman integration - task completion via voice, auto-dispatch, priority routing
@MainActor
class HelmsmanIntegration: ObservableObject {
    static let shared = HelmsmanIntegration()

    @Published private(set) var pendingTasks: [HelmsmanTask] = []
    @Published private(set) var lastTaskCheck: Date?

    private let baseURL = "http://localhost:5682"

    private init() {}

    // MARK: - Task Queries

    /// Get all pending tasks (optionally filtered by owner)
    func getPendingTasks(owner: String? = nil) async throws -> [HelmsmanTask] {
        var urlString = "\(baseURL)/tasks?status=pending"
        if let owner = owner {
            urlString += "&owner=\(owner)"
        }

        guard let url = URL(string: urlString) else {
            throw HelmsmanError.invalidURL
        }

        let (data, response) = try await URLSession.shared.data(from: url)

        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            throw HelmsmanError.requestFailed
        }

        let tasks = try JSONDecoder().decode([HelmsmanTask].self, from: data)
        self.pendingTasks = tasks
        self.lastTaskCheck = Date()

        return tasks
    }

    /// Get task by number
    func getTask(_ num: Int) async throws -> HelmsmanTask {
        guard let url = URL(string: "\(baseURL)/tasks/\(num)") else {
            throw HelmsmanError.invalidURL
        }

        let (data, response) = try await URLSession.shared.data(from: url)

        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            throw HelmsmanError.requestFailed
        }

        return try JSONDecoder().decode(HelmsmanTask.self, from: data)
    }

    /// Create a new task via voice
    func createTask(task: String, owner: String, effort: String = "M", priority: Int = 5, blockedBy: Int? = nil) async throws -> HelmsmanTask {
        guard let url = URL(string: "\(baseURL)/tasks") else {
            throw HelmsmanError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let payload: [String: Any] = [
            "task": task,
            "owner": owner,
            "effort": effort,
            "priority": priority,
            "blocked_by": blockedBy as Any
        ]

        request.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 201 else {
            throw HelmsmanError.requestFailed
        }

        return try JSONDecoder().decode(HelmsmanTask.self, from: data)
    }

    /// Mark task complete
    func completeTask(_ num: Int) async throws {
        guard let url = URL(string: "\(baseURL)/tasks/\(num)") else {
            throw HelmsmanError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "PATCH"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let payload: [String: String] = ["status": "done"]
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let (_, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            throw HelmsmanError.requestFailed
        }
    }

    // MARK: - Voice Task Completion

    /// Natural language task completion - finds task by description fuzzy match
    func completeTaskByDescription(_ description: String) async throws -> String {
        let tasks = try await getPendingTasks()

        // Fuzzy match task description
        guard let match = tasks.first(where: { task in
            task.task.lowercased().contains(description.lowercased()) ||
            description.lowercased().contains(task.task.lowercased().split(separator: " ").prefix(3).joined(separator: " "))
        }) else {
            throw HelmsmanError.taskNotFound
        }

        try await completeTask(match.num)

        return "Marked task #\(match.num) complete: \(match.task)"
    }

    // MARK: - Auto-Dispatch

    /// Suggest agent for a task based on content
    func suggestAgent(for taskDescription: String) -> String {
        let description = taskDescription.lowercased()

        // Code/file work
        if description.contains("fix") || description.contains("refactor") || description.contains("implement") ||
           description.contains("code") || description.contains("file") {
            return "AIDER-GEM"
        }

        // Research/analysis
        if description.contains("research") || description.contains("analyze") || description.contains("investigate") ||
           description.contains("find out") {
            return "NVIDIA-BAL"
        }

        // Fast operations
        if description.contains("quick") || description.contains("simple") || description.contains("check") {
            return "NVIDIA-FAST"
        }

        // Complex reasoning
        if description.contains("design") || description.contains("architecture") || description.contains("plan") {
            return "NVIDIA-THINK"
        }

        // Human decisions
        if description.contains("decide") || description.contains("approve") || description.contains("review") {
            return "CHARLIE"
        }

        // Default to NVIDIA-FAST for general work
        return "NVIDIA-FAST"
    }

    /// Create and dispatch task in one step
    func dispatchTask(description: String, autoRoute: Bool = true) async throws -> String {
        let owner = autoRoute ? suggestAgent(for: description) : "CHARLIE"
        let task = try await createTask(task: description, owner: owner)

        return "Created task #\(task.num) and assigned to \(owner)"
    }

    // MARK: - Priority Routing

    /// Get high-priority tasks (priority >= 8)
    func getHighPriorityTasks() async throws -> [HelmsmanTask] {
        let allTasks = try await getPendingTasks()
        return allTasks.filter { $0.priority >= 8 }
    }

    /// Get urgent tasks (created in last 4 hours with priority >= 7)
    func getUrgentTasks() async throws -> [HelmsmanTask] {
        let allTasks = try await getPendingTasks()
        let fourHoursAgo = Date().addingTimeInterval(-4 * 3600)

        return allTasks.filter { task in
            task.priority >= 7 &&
            (task.created.map { $0 >= fourHoursAgo } ?? false)
        }
    }

    /// Suggest next task to work on
    func suggestNextTask() async throws -> String? {
        // Check for urgent tasks first
        let urgent = try await getUrgentTasks()
        if let task = urgent.first {
            return "Urgent task #\(task.num): \(task.task) (priority \(task.priority))"
        }

        // Then high priority
        let highPri = try await getHighPriorityTasks()
        if let task = highPri.first {
            return "High priority task #\(task.num): \(task.task)"
        }

        // Otherwise just oldest pending
        let pending = try await getPendingTasks(owner: "CHARLIE")
        if let task = pending.first {
            return "Task #\(task.num): \(task.task)"
        }

        return nil
    }

    // MARK: - Voice Queries

    /// Generate spoken summary of pending tasks
    func getTaskStatusSummary() async throws -> String {
        let tasks = try await getPendingTasks()

        if tasks.isEmpty {
            return "No pending tasks."
        }

        let byOwner = Dictionary(grouping: tasks, by: { $0.owner })

        var parts: [String] = []

        for (owner, ownerTasks) in byOwner.sorted(by: { $0.value.count > $1.value.count }) {
            let count = ownerTasks.count
            let ownerName = owner == "CHARLIE" ? "you" : owner.replacingOccurrences(of: "-", with: " ")
            parts.append("\(count) for \(ownerName)")
        }

        return "\(tasks.count) pending tasks: \(parts.joined(separator: ", "))"
    }
}

// MARK: - Models

struct HelmsmanTask: Codable {
    let num: Int
    let task: String
    let owner: String
    let status: String
    let effort: String
    let priority: Int
    let blockedBy: Int?
    let created: Date?
    let completed: Date?

    enum CodingKeys: String, CodingKey {
        case num, task, owner, status, effort, priority
        case blockedBy = "blocked_by"
        case created, completed
    }
}

enum HelmsmanError: Error {
    case invalidURL
    case requestFailed
    case taskNotFound
}
