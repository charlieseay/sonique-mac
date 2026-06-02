import Foundation

/// Aggregates lab environment status with caching
@MainActor
class LabStatusService: ObservableObject {
    static let shared = LabStatusService()

    @Published var cachedStatus: LabStatus?
    @Published var lastUpdate: Date?

    private let cacheTimeout: TimeInterval = 300  // 5 minutes

    struct LabStatus: Codable {
        let helmsmanTasks: Int
        let topTasks: [String]
        let dockerHealthy: Bool
        let stoppedContainers: [String]
        let recentCommits: Int
        let alerts: Int
        let timestamp: Date
    }

    private init() {}

    func getStatus(forceRefresh: Bool = false) async -> String {
        // Check cache
        if !forceRefresh,
           let cached = cachedStatus,
           let lastUpdate = lastUpdate,
           Date().timeIntervalSince(lastUpdate) < cacheTimeout {
            return formatStatus(cached)
        }

        // Refresh status
        await refreshStatus()

        guard let status = cachedStatus else {
            return "Failed to get lab status"
        }

        return formatStatus(status)
    }

    private func refreshStatus() async {
        print("[LabStatus] Refreshing status...")

        // Query in parallel
        async let helmsman = queryHelmsman()
        async let docker = queryDocker()
        async let commits = queryCommits()

        let (helmsmanResult, dockerResult, commitsResult) = await (helmsman, docker, commits)

        let status = LabStatus(
            helmsmanTasks: helmsmanResult.count,
            topTasks: helmsmanResult.tasks,
            dockerHealthy: dockerResult.healthy,
            stoppedContainers: dockerResult.stopped,
            recentCommits: commitsResult,
            alerts: 0,  // TODO: query Bridge
            timestamp: Date()
        )

        cachedStatus = status
        lastUpdate = Date()
    }

    private func formatStatus(_ status: LabStatus) -> String {
        var summary = ""

        // Helmsman
        if status.helmsmanTasks == 0 {
            summary += "Helmsman queue is empty. "
        } else {
            summary += "\(status.helmsmanTasks) pending task\(status.helmsmanTasks == 1 ? "" : "s") in Helmsman queue"
            if !status.topTasks.isEmpty {
                summary += ": " + status.topTasks.prefix(3).joined(separator: ", ") + ". "
            } else {
                summary += ". "
            }
        }

        // Docker
        if status.dockerHealthy {
            summary += "All Docker containers healthy. "
        } else {
            summary += "Docker issues: \(status.stoppedContainers.joined(separator: ", ")) stopped. "
        }

        // Recent commits
        if status.recentCommits > 0 {
            summary += "\(status.recentCommits) commit\(status.recentCommits == 1 ? "" : "s") in the last 24 hours. "
        }

        // Alerts
        if status.alerts > 0 {
            summary += "\(status.alerts) alert\(status.alerts == 1 ? "" : "s") in Bridge. "
        } else {
            summary += "No alerts. "
        }

        return summary.trimmingCharacters(in: .whitespaces)
    }

    // MARK: - Individual Queries

    private func queryHelmsman() async -> (count: Int, tasks: [String]) {
        let result = await InfrastructureExecutor.shell("curl -s 'http://localhost:5682/tasks?status=pending'")

        guard result.exitCode == 0,
              let data = result.stdout.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return (0, [])
        }

        let tasks = json.prefix(3).compactMap { task -> String? in
            guard let num = task["num"] as? Int,
                  let title = task["task"] as? String else { return nil }
            return "#\(num): \(title)"
        }

        return (json.count, tasks)
    }

    private func queryDocker() async -> (healthy: Bool, stopped: [String]) {
        let result = await InfrastructureExecutor.shell("docker ps -a --format '{{.Names}}:{{.Status}}'")

        guard result.exitCode == 0 else {
            return (false, ["Docker daemon unreachable"])
        }

        let lines = result.stdout.components(separatedBy: "\n").filter { !$0.isEmpty }
        let stopped = lines.filter { !$0.contains("Up") }.compactMap { line -> String? in
            let parts = line.components(separatedBy: ":")
            return parts.first
        }

        return (stopped.isEmpty, stopped)
    }

    private func queryCommits() async -> Int {
        let repos = [
            "~/Projects/StoryChat",
            "~/Projects/sonique-mac",
            "~/Projects/sonique-ios",
            "~/Library/Mobile\\ Documents/iCloud~md~obsidian/Documents/SeaynicNet"
        ]

        var totalCommits = 0

        for repo in repos {
            let result = await InfrastructureExecutor.shell("cd \(repo) && git log --since='24 hours ago' --oneline 2>/dev/null | wc -l")
            if result.exitCode == 0, let count = Int(result.stdout.trimmingCharacters(in: .whitespaces)) {
                totalCommits += count
            }
        }

        return totalCommits
    }
}
