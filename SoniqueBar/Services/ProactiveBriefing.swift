import Foundation
import EventKit

/// Proactive intelligence - morning briefings, context switching, smart reminders
@MainActor
class ProactiveBriefing: ObservableObject {
    static let shared = ProactiveBriefing()

    @Published private(set) var lastBriefing: String = ""
    @Published private(set) var lastBriefingTime: Date?

    private let eventStore = EKEventStore()
    private var contextMonitor: Timer?
    private var lastGitBranch: String?
    private var lastActiveApp: String?
    private var lastIdleTime: Date?

    private init() {
        startContextMonitoring()
    }

    // MARK: - Morning Briefing

    /// Generate comprehensive morning briefing
    func generateMorningBriefing() async -> String {
        var sections: [String] = []

        // 1. Greeting with time context
        let greeting = generateGreeting()
        sections.append(greeting)

        // 2. Calendar events
        if let calendarSummary = await getCalendarSummary() {
            sections.append(calendarSummary)
        }

        // 3. Helmsman tasks
        if let taskSummary = await getHelmsmanSummary() {
            sections.append(taskSummary)
        }

        // 4. Docker status
        if let dockerSummary = await getDockerSummary() {
            sections.append(dockerSummary)
        }

        // 5. Recent git activity
        if let gitSummary = await getGitSummary() {
            sections.append(gitSummary)
        }

        let briefing = sections.joined(separator: " ")
        lastBriefing = briefing
        lastBriefingTime = Date()

        return briefing
    }

    private func generateGreeting() -> String {
        // Use device-aware greeting (adjusts for iOS timezone)
        let timeOfDay = DeviceContext.shared.getGreeting()
        return "\(timeOfDay), Charlie."
    }

    // MARK: - Calendar Integration

    private func getCalendarSummary() async -> String? {
        // Request calendar access
        let granted = await withCheckedContinuation { continuation in
            eventStore.requestAccess(to: .event) { granted, _ in
                continuation.resume(returning: granted)
            }
        }

        guard granted else { return nil }

        let calendar = Calendar.current
        let startOfDay = calendar.startOfDay(for: Date())
        let endOfDay = calendar.date(byAdding: .day, value: 1, to: startOfDay)!

        let predicate = eventStore.predicateForEvents(withStart: startOfDay, end: endOfDay, calendars: nil)
        let events = eventStore.events(matching: predicate)

        guard !events.isEmpty else { return nil }

        let formatter = DateFormatter()
        formatter.dateFormat = "h:mm a"

        if events.count == 1 {
            let event = events[0]
            return "You have one meeting today: \(event.title ?? "Untitled") at \(formatter.string(from: event.startDate))."
        } else {
            let firstEvent = events[0]
            let timeUntilFirst = firstEvent.startDate.timeIntervalSinceNow
            let minutesUntil = Int(timeUntilFirst / 60)

            if minutesUntil > 0 && minutesUntil < 60 {
                return "You have \(events.count) meetings today. First one in \(minutesUntil) minutes: \(firstEvent.title ?? "Untitled")."
            } else {
                return "You have \(events.count) meetings today. First one at \(formatter.string(from: firstEvent.startDate))."
            }
        }
    }

    // MARK: - Helmsman Integration

    private func getHelmsmanSummary() async -> String? {
        guard let url = URL(string: "http://localhost:5682/tasks?status=pending&owner=CLAUDE") else {
            return nil
        }

        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            guard let tasks = try? JSONDecoder().decode([HelmsmanTask].self, from: data) else {
                return nil
            }

            if tasks.isEmpty {
                return "No pending tasks in Helmsman."
            } else if tasks.count == 1 {
                return "1 pending task in Helmsman."
            } else {
                return "\(tasks.count) pending tasks in Helmsman."
            }
        } catch {
            return nil
        }
    }

    private struct HelmsmanTask: Codable {
        let num: Int
        let task: String
        let owner: String
    }

    // MARK: - Docker Status

    private func getDockerSummary() async -> String? {
        let result = await InfrastructureExecutor.shell("docker ps --filter health=unhealthy --format '{{.Names}}' 2>/dev/null")

        guard result.exitCode == 0 else { return nil }

        let unhealthy = result.stdout
            .components(separatedBy: "\n")
            .filter { !$0.isEmpty }

        if unhealthy.isEmpty {
            return "All Docker containers healthy."
        } else if unhealthy.count == 1 {
            return "\(unhealthy[0]) is down. Should I restart it?"
        } else {
            return "\(unhealthy.count) containers down: \(unhealthy.joined(separator: ", ")). Should I restart them?"
        }
    }

    // MARK: - Git Activity

    private func getGitSummary() async -> String? {
        // Get recent commits across common repos
        let repos = [
            "/Users/charlieseay/Projects/sonique-mac",
            "/Users/charlieseay/Projects/sonique-ios",
            "/Users/charlieseay/Library/Mobile Documents/iCloud~md~obsidian/Documents/SeaynicNet"
        ]

        var totalCommits = 0

        for repo in repos {
            let result = await InfrastructureExecutor.shell(
                "cd '\(repo)' && git log --since='24 hours ago' --oneline 2>/dev/null | wc -l"
            )

            if result.exitCode == 0, let count = Int(result.stdout.trimmingCharacters(in: .whitespaces)) {
                totalCommits += count
            }
        }

        if totalCommits == 0 {
            return nil
        } else if totalCommits == 1 {
            return "1 commit in the last 24 hours."
        } else {
            return "\(totalCommits) commits in the last 24 hours."
        }
    }

    // MARK: - Context Switching Detection

    private func startContextMonitoring() {
        // Monitor every 30 seconds for context changes
        contextMonitor = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in
                await self?.checkContextChanges()
            }
        }
    }

    private func checkContextChanges() async {
        // Detect git branch changes
        await detectGitBranchChange()

        // Detect active app changes (for project context)
        await detectActiveAppChange()

        // Detect idle time (for shutdown suggestions)
        await detectIdleTime()
    }

    private func detectGitBranchChange() async {
        // Check current git branch in common repos
        let repos = [
            "/Users/charlieseay/Projects/sonique-mac",
            "/Users/charlieseay/Projects/sonique-ios"
        ]

        for repo in repos {
            let result = await InfrastructureExecutor.shell(
                "cd '\(repo)' && git branch --show-current 2>/dev/null"
            )

            if result.exitCode == 0 {
                let currentBranch = result.stdout.trimmingCharacters(in: .whitespaces)
                let repoName = (repo as NSString).lastPathComponent
                let key = "lastBranch_\(repoName)"

                if let lastBranch = UserDefaults.standard.string(forKey: key),
                   lastBranch != currentBranch {
                    // Branch changed - notify
                    await notifyContextChange(
                        "Switched to \(currentBranch) in \(repoName). Want me to pull up recent changes?"
                    )
                }

                UserDefaults.standard.set(currentBranch, forKey: key)
            }
        }
    }

    private func detectActiveAppChange() async {
        // Get frontmost application using AppleScript
        let script = """
        tell application "System Events"
            set frontApp to name of first application process whose frontmost is true
            return frontApp
        end tell
        """

        let result = await InfrastructureExecutor.shell("osascript -e '\(script)' 2>/dev/null")

        if result.exitCode == 0 {
            let currentApp = result.stdout.trimmingCharacters(in: .whitespaces)

            // Only track development apps
            let devApps = ["Xcode", "Visual Studio Code", "Terminal", "iTerm"]

            if devApps.contains(currentApp),
               let lastApp = lastActiveApp,
               lastApp != currentApp,
               currentApp == "Xcode" {
                // Switched to Xcode - could offer project-specific help
                // Don't spam - only if significant context switch
            }

            lastActiveApp = currentApp
        }
    }

    private func detectIdleTime() async {
        // Get idle time in seconds
        let result = await InfrastructureExecutor.shell(
            "ioreg -c IOHIDSystem | awk '/HIDIdleTime/ {print int($NF/1000000000); exit}'"
        )

        if result.exitCode == 0,
           let idleSeconds = Int(result.stdout.trimmingCharacters(in: .whitespaces)),
           idleSeconds > 7200 { // 2 hours

            // Check if Docker containers are running
            let dockerResult = await InfrastructureExecutor.shell("docker ps -q | wc -l")

            if dockerResult.exitCode == 0,
               let containerCount = Int(dockerResult.stdout.trimmingCharacters(in: .whitespaces)),
               containerCount > 0 {

                // Mac idle for 2+ hours with containers running
                await notifyContextChange(
                    "Your Mac has been idle for 2 hours but \(containerCount) Docker containers are still running. Should I shut them down to save resources?"
                )
            }
        }
    }

    private func notifyContextChange(_ message: String) async {
        // Send to CommandServer for potential voice notification
        // For now, just log - will integrate with notification system
        NSLog("[ProactiveBriefing] Context change: \(message)")
    }

    // MARK: - Smart Reminders

    /// Check for pending follow-ups based on conversation history
    func checkFollowUps() async -> String? {
        // TODO: Integrate with conversation memory system (Phase 4)
        // For now, return nil
        return nil
    }
}
