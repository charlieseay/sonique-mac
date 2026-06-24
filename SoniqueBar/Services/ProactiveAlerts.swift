import Foundation
import UserNotifications

/// Proactive alert system - Quinn notifies Charlie about important events
@MainActor
class ProactiveAlerts: NSObject, ObservableObject {
    static let shared = ProactiveAlerts()

    @Published private(set) var isEnabled: Bool = false

    private var monitoringTimers: [Timer] = []

    private override init() {
        super.init()
    }

    func enable() async {
        guard !isEnabled else { return }

        // Request notification permission
        let center = UNUserNotificationCenter.current()
        do {
            try await center.requestAuthorization(options: [.alert, .sound, .badge])
            isEnabled = true

            // Start monitoring various systems
            startTaskQueueMonitoring()
            startDockerHealthMonitoring()
            startDiskSpaceMonitoring()

            print("[ProactiveAlerts] Enabled")
        } catch {
            print("[ProactiveAlerts] Failed to get notification permission: \(error)")
        }
    }

    func disable() {
        monitoringTimers.forEach { $0.invalidate() }
        monitoringTimers.removeAll()
        isEnabled = false

        print("[ProactiveAlerts] Disabled")
    }

    // MARK: - Task Queue Monitoring

    private func startTaskQueueMonitoring() {
        let timer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            Task { @MainActor in
                await self?.checkTaskQueue()
            }
        }
        monitoringTimers.append(timer)
    }

    private func checkTaskQueue() async {
        // Query helmsman queue
        guard let url = URL(string: "http://localhost:5682/tasks?status=pending&owner=CLAUDE") else { return }

        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            let decoder = JSONDecoder()
            guard let tasks = try? decoder.decode([Task].self, from: data) else { return }

            // Alert if queue is growing
            if tasks.count > 10 {
                await sendAlert(
                    title: "Task Queue Growing",
                    body: "\(tasks.count) pending tasks in Helmsman queue"
                )
            }
        } catch {
            print("[ProactiveAlerts] Failed to check task queue: \(error)")
        }
    }

    private struct Task: Codable {
        let num: Int
        let task: String
        let owner: String
    }

    // MARK: - Docker Health Monitoring

    private func startDockerHealthMonitoring() {
        let timer = Timer.scheduledTimer(withTimeInterval: 600, repeats: true) { [weak self] _ in
            Task { @MainActor in
                await self?.checkDockerHealth()
            }
        }
        monitoringTimers.append(timer)
    }

    private func checkDockerHealth() async {
        let result = await InfrastructureExecutor.shell("docker ps --filter health=unhealthy --format '{{.Names}}'")

        if result.exitCode == 0 && !result.stdout.isEmpty {
            let unhealthy = result.stdout
                .components(separatedBy: "\n")
                .filter { !$0.isEmpty }

            if !unhealthy.isEmpty {
                await sendAlert(
                    title: "Unhealthy Containers",
                    body: "\(unhealthy.count) container(s) reporting unhealthy: \(unhealthy.joined(separator: ", "))"
                )
            }
        }
    }

    // MARK: - Disk Space Monitoring

    private func startDiskSpaceMonitoring() {
        let timer = Timer.scheduledTimer(withTimeInterval: 1800, repeats: true) { [weak self] _ in
            Task { @MainActor in
                await self?.checkDiskSpace()
            }
        }
        monitoringTimers.append(timer)
    }

    private func checkDiskSpace() async {
        let result = await InfrastructureExecutor.shell("df -H / | awk 'NR==2 {print $5}' | sed 's/%//'")

        if result.exitCode == 0,
           let usedPercent = Int(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)),
           usedPercent > 90 {
            await sendAlert(
                title: "Low Disk Space",
                body: "Disk usage at \(usedPercent)%"
            )
        }
    }

    // MARK: - Notification Delivery

    private func sendAlert(title: String, body: String) async {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil // Deliver immediately
        )

        do {
            try await UNUserNotificationCenter.current().add(request)
            print("[ProactiveAlerts] Sent: \(title)")

            // Also speak if voice is enabled
            if UserDefaults.standard.bool(forKey: "proactive_voice_enabled") {
                try? await VoiceRouter.shared.speak(text: "\(title). \(body)")
            }
        } catch {
            print("[ProactiveAlerts] Failed to send notification: \(error)")
        }
    }
}
