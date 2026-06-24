import Foundation
import UserNotifications

/// Predictive notifications - Quinn anticipates Charlie's needs
@MainActor
class PredictiveNotifications: NSObject, ObservableObject {
    static let shared = PredictiveNotifications()

    @Published private(set) var isEnabled: Bool = false

    private var predictionTimer: Timer?
    private let contextEngine = ContextEngine.shared

    private override init() {
        super.init()
    }

    func enable() async {
        guard !isEnabled else { return }

        // Request notification permission
        let center = UNUserNotificationCenter.current()
        do {
            try await center.requestAuthorization(options: [.alert, .sound])
            isEnabled = true

            // Run predictions every 15 minutes
            predictionTimer = Timer.scheduledTimer(withTimeInterval: 900, repeats: true) { [weak self] _ in
                Task { @MainActor in
                    await self?.runPredictions()
                }
            }

            // Initial run
            await runPredictions()

            print("[PredictiveNotifications] Enabled")
        } catch {
            print("[PredictiveNotifications] Failed to get permission: \(error)")
        }
    }

    func disable() {
        predictionTimer?.invalidate()
        predictionTimer = nil
        isEnabled = false

        print("[PredictiveNotifications] Disabled")
    }

    // MARK: - Prediction Logic

    private func runPredictions() async {
        // Only be proactive if context allows
        guard contextEngine.shouldBeProactive else { return }

        // Check various predictive scenarios
        await checkUpcomingMeetings()
        await checkPendingTasks()
        await checkSystemHealth()
        await checkDailyBrief()
    }

    private func checkUpcomingMeetings() async {
        // TODO: Check calendar for meetings in next 10 minutes
        // For now, stub
    }

    private func checkPendingTasks() async {
        // Check if there are urgent tasks in Helmsman queue
        guard let url = URL(string: "http://localhost:5682/tasks?status=pending&owner=CLAUDE") else { return }

        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            let decoder = JSONDecoder()
            guard let tasks = try? decoder.decode([HTask].self, from: data) else { return }

            // Notify if urgent tasks are piling up
            if tasks.count > 15 {
                await sendPrediction(
                    title: "Task Queue Alert",
                    body: "\(tasks.count) pending tasks. Should I help clear the queue?"
                )
            }
        } catch {
            // Silent fail - predictions are non-critical
        }
    }

    private func checkSystemHealth() async {
        // Check Docker health
        let result = await InfrastructureExecutor.shell("docker ps --filter health=unhealthy --format '{{.Names}}'")

        if result.exitCode == 0 && !result.stdout.isEmpty {
            let unhealthy = result.stdout.components(separatedBy: "\n").filter { !$0.isEmpty }

            if !unhealthy.isEmpty {
                await sendPrediction(
                    title: "System Health",
                    body: "\(unhealthy.count) container(s) unhealthy. Want me to restart them?"
                )
            }
        }
    }

    private func checkDailyBrief() async {
        // Morning brief - once per day at 9am
        let now = Date()
        let hour = Calendar.current.component(.hour, from: now)
        let minute = Calendar.current.component(.minute, from: now)

        // Only between 9:00-9:15am
        guard hour == 9, minute < 15 else { return }

        // Check if we already sent today's brief
        let lastBriefDate = UserDefaults.standard.object(forKey: "last_morning_brief") as? Date
        let today = Calendar.current.startOfDay(for: now)

        if let lastBrief = lastBriefDate,
           Calendar.current.isDate(lastBrief, inSameDayAs: today) {
            return // Already sent today
        }

        // Send morning brief
        let brief = await generateMorningBrief()
        await sendPrediction(title: "Good Morning", body: brief)

        // Mark as sent
        UserDefaults.standard.set(now, forKey: "last_morning_brief")
    }

    private func generateMorningBrief() async -> String {
        // TODO: Generate comprehensive morning brief
        // - Pending tasks
        // - System health
        // - Calendar events
        // - Weather (if integrated)

        return "You have 5 tasks pending and all systems are healthy."
    }

    // MARK: - Notification Delivery

    private func sendPrediction(title: String, body: String) async {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )

        do {
            try await UNUserNotificationCenter.current().add(request)
            print("[PredictiveNotifications] Sent: \(title)")

            // Also speak if voice is enabled and context allows
            if UserDefaults.standard.bool(forKey: "predictive_voice_enabled"),
               contextEngine.shouldBeProactive {
                try? await VoiceRouter.shared.speak(text: "\(title). \(body)")
            }
        } catch {
            print("[PredictiveNotifications] Failed to send: \(error)")
        }
    }
}

// MARK: - Helper Types

private struct HTask: Codable {
    let num: Int
    let task: String
}
