import Foundation

/// Background service that watches for critical events and can alert proactively
@MainActor
class BackgroundMonitor: ObservableObject {
    static let shared = BackgroundMonitor()

    @Published var isMonitoring = false

    private var monitorTimer: Timer?
    private let checkInterval: TimeInterval = 60.0  // Check every minute

    // Monitored conditions
    private var lastHelmsmanCheck: Date?
    private var lastErrorCount = 0

    private init() {}

    /// Start background monitoring
    func startMonitoring() {
        guard !isMonitoring else { return }

        isMonitoring = true
        print("[BackgroundMonitor] Starting continuous monitoring")

        // Initial check
        performChecks()

        // Then check on interval
        monitorTimer = Timer.scheduledTimer(
            withTimeInterval: checkInterval,
            repeats: true
        ) { [weak self] _ in
            Task { @MainActor in
                self?.performChecks()
            }
        }
    }

    /// Stop background monitoring
    func stopMonitoring() {
        isMonitoring = false
        monitorTimer?.invalidate()
        monitorTimer = nil
        print("[BackgroundMonitor] Stopped monitoring")
    }

    /// Perform all background checks
    private func performChecks() {
        Task {
            await checkHelmsmanQueue()
            await checkDockerHealth()
            await checkDiskSpace()
        }
    }

    // MARK: - Individual Checks

    private func checkHelmsmanQueue() async {
        let result = await InfrastructureExecutor.shell("curl -s http://localhost:5682/tasks?status=pending | python3 -c 'import json,sys; print(len(json.load(sys.stdin)))'")

        if result.exitCode == 0, let count = Int(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)) {
            // Alert if queue suddenly grows by 10+ tasks
            if let last = lastHelmsmanCheck, count > lastErrorCount + 10 {
                NotificationService.shared.notify(
                    title: "Helmsman Queue Alert",
                    message: "Task queue jumped from \(lastErrorCount) to \(count) pending tasks",
                    priority: .normal
                )
            }
            lastErrorCount = count
        }
        lastHelmsmanCheck = Date()
    }

    private func checkDockerHealth() async {
        let result = await InfrastructureExecutor.shell("docker ps --filter 'health=unhealthy' --format '{{.Names}}'")

        if result.exitCode == 0 && !result.stdout.isEmpty {
            let unhealthy = result.stdout.split(separator: "\n").map { String($0) }
            NotificationService.shared.notify(
                title: "Docker Health Alert",
                message: "Unhealthy containers: \(unhealthy.joined(separator: ", "))",
                priority: .critical
            )
        }
    }

    private func checkDiskSpace() async {
        let result = await InfrastructureExecutor.shell("df -h / | tail -1 | awk '{print $5}' | sed 's/%//'")

        if result.exitCode == 0, let percentage = Int(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)) {
            if percentage > 90 {
                NotificationService.shared.notify(
                    title: "Disk Space Critical",
                    message: "Root volume is \(percentage)% full",
                    priority: .critical
                )
            }
        }
    }

    // MARK: - Event Registration

    /// Register a custom watch condition
    func watch(condition: @escaping () async -> Bool, onTrigger: @escaping () -> Void) {
        // TODO: Allow dynamic condition registration
    }
}
