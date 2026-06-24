import Foundation
import AppKit

/// Quick win commands - aliases and smart shortcuts
@MainActor
class QuickCommands: ObservableObject {
    static let shared = QuickCommands()

    @Published private(set) var isFocusMode = false
    @Published private(set) var lastWrapUpSummary: String?

    private init() {}

    // MARK: - Focus Mode

    /// Enter focus mode - DND, close distractions, stop non-essential containers
    func enterFocusMode() async -> String {
        var actions: [String] = []

        // 1. Enable Do Not Disturb
        let dndResult = await InfrastructureExecutor.shell("""
            osascript -e 'tell application "System Events" to keystroke "D" using {command down, shift down, option down, control down}'
            """)

        if dndResult.exitCode == 0 {
            actions.append("Do Not Disturb enabled")
        }

        // 2. Close Slack if running
        let slackResult = await InfrastructureExecutor.shell("""
            osascript -e 'tell application "Slack" to quit' 2>/dev/null
            """)

        if slackResult.exitCode == 0 {
            actions.append("Closed Slack")
        }

        // 3. Stop non-essential Docker containers
        let containerResult = await InfrastructureExecutor.shell("""
            docker ps --filter "label=priority=low" --format "{{.Names}}" | xargs -r docker stop 2>/dev/null
            """)

        if containerResult.exitCode == 0 && !containerResult.stdout.isEmpty {
            let stopped = containerResult.stdout.components(separatedBy: "\n").filter { !$0.isEmpty }
            if !stopped.isEmpty {
                actions.append("Stopped \(stopped.count) non-essential containers")
            }
        }

        // 4. Set focus mode flag
        isFocusMode = true
        UserDefaults.standard.set(true, forKey: "quinn_focus_mode")

        let summary = actions.isEmpty ? "Focus mode activated" : "Focus mode: \(actions.joined(separator: ". "))"
        return summary
    }

    /// Exit focus mode - restore normal state
    func exitFocusMode() async -> String {
        var actions: [String] = []

        // 1. Disable Do Not Disturb (same keystroke toggles)
        let dndResult = await InfrastructureExecutor.shell("""
            osascript -e 'tell application "System Events" to keystroke "D" using {command down, shift down, option down, control down}'
            """)

        if dndResult.exitCode == 0 {
            actions.append("Do Not Disturb disabled")
        }

        // 2. Restart essential containers (optional - user can do manually)
        isFocusMode = false
        UserDefaults.standard.set(false, forKey: "quinn_focus_mode")

        let summary = actions.isEmpty ? "Focus mode deactivated" : "Back to normal: \(actions.joined(separator: ". "))"
        return summary
    }

    // MARK: - Wrap Up

    /// End of day wrap up - commit changes, stop Docker, summarize activity
    func wrapUp() async -> String {
        var summary: [String] = []

        // 1. Check for uncommitted changes in common repos
        let repos = [
            "/Users/charlieseay/Projects/sonique-mac",
            "/Users/charlieseay/Projects/sonique-ios",
            "/Users/charlieseay/Library/Mobile Documents/iCloud~md~obsidian/Documents/SeaynicNet"
        ]

        var uncommittedRepos: [String] = []

        for repo in repos {
            let result = await InfrastructureExecutor.shell(
                "cd '\(repo)' && git status --porcelain 2>/dev/null"
            )

            if result.exitCode == 0 && !result.stdout.isEmpty {
                let repoName = (repo as NSString).lastPathComponent
                uncommittedRepos.append(repoName)
            }
        }

        if !uncommittedRepos.isEmpty {
            summary.append("You have uncommitted changes in: \(uncommittedRepos.joined(separator: ", "))")
        }

        // 2. Stop all Docker containers
        let dockerResult = await InfrastructureExecutor.shell("docker stop $(docker ps -q) 2>/dev/null")

        if dockerResult.exitCode == 0 {
            summary.append("All Docker containers stopped")
        }

        // 3. Get today's commit count
        var totalCommits = 0

        for repo in repos {
            let result = await InfrastructureExecutor.shell(
                "cd '\(repo)' && git log --since='today' --oneline 2>/dev/null | wc -l"
            )

            if result.exitCode == 0, let count = Int(result.stdout.trimmingCharacters(in: .whitespaces)) {
                totalCommits += count
            }
        }

        if totalCommits > 0 {
            summary.append("\(totalCommits) commits today")
        }

        // 4. Check pending Helmsman tasks
        if let taskCount = await getHelmsmanPendingCount() {
            summary.append("\(taskCount) pending tasks for tomorrow")
        }

        let wrapUpMessage = summary.isEmpty ? "All wrapped up for today" : summary.joined(separator: ". ")
        lastWrapUpSummary = wrapUpMessage

        return wrapUpMessage
    }

    private func getHelmsmanPendingCount() async -> Int? {
        guard let url = URL(string: "http://localhost:5682/tasks?status=pending&owner=CLAUDE") else {
            return nil
        }

        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            guard let tasks = try? JSONDecoder().decode([HelmsmanTask].self, from: data) else {
                return nil
            }
            return tasks.count
        } catch {
            return nil
        }
    }

    private struct HelmsmanTask: Codable {
        let num: Int
        let task: String
    }

    // MARK: - Quick Status

    /// Ultra-condensed status for quick check-ins
    func quickStatus() async -> String {
        var parts: [String] = []

        // Helmsman tasks
        if let count = await getHelmsmanPendingCount(), count > 0 {
            parts.append("\(count) tasks")
        }

        // Docker health
        let dockerResult = await InfrastructureExecutor.shell(
            "docker ps --filter health=unhealthy --format '{{.Names}}' 2>/dev/null | wc -l"
        )

        if dockerResult.exitCode == 0,
           let unhealthyCount = Int(dockerResult.stdout.trimmingCharacters(in: .whitespaces)),
           unhealthyCount > 0 {
            parts.append("\(unhealthyCount) containers down")
        }

        return parts.isEmpty ? "All good" : parts.joined(separator: ", ")
    }

    // MARK: - Deep Work Timer

    /// Start a focused work session with timer
    func startDeepWork(minutes: Int = 90) async -> String {
        // Enter focus mode
        _ = await enterFocusMode()

        // Set timer notification
        let endTime = Date().addingTimeInterval(TimeInterval(minutes * 60))
        let formatter = DateFormatter()
        formatter.dateFormat = "h:mm a"

        UserDefaults.standard.set(endTime, forKey: "quinn_deep_work_end")

        return "Deep work session started. I'll notify you at \(formatter.string(from: endTime))"
    }

    /// Check if deep work session is complete
    func checkDeepWorkTimer() async -> Bool {
        guard let endTime = UserDefaults.standard.object(forKey: "quinn_deep_work_end") as? Date else {
            return false
        }

        if Date() >= endTime {
            UserDefaults.standard.removeObject(forKey: "quinn_deep_work_end")
            _ = await exitFocusMode()
            return true
        }

        return false
    }

    // MARK: - Smart Defaults

    /// Suggest next action based on context
    func suggestNextAction() async -> String? {
        let hour = Calendar.current.component(.hour, from: Date())

        // Morning: suggest starting work
        if hour >= 8 && hour < 10 {
            if let taskCount = await getHelmsmanPendingCount(), taskCount > 0 {
                return "Good morning. You have \(taskCount) tasks waiting. Ready to dive in?"
            }
        }

        // Late afternoon: suggest wrap up
        if hour >= 17 && hour < 19 {
            return "It's getting late. Want me to help you wrap up for the day?"
        }

        // Check battery on iOS devices (would need device context)
        // This is a placeholder for when device integration is added

        return nil
    }
}
