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
            await checkClaudeHealth()

            // Self-diagnosis: run weekly (Sunday at midnight)
            let calendar = Calendar.current
            let now = Date()
            if calendar.component(.weekday, from: now) == 1 && calendar.component(.hour, from: now) == 0 {
                await runSelfDiagnosis()
            }
        }
    }

    // MARK: - Individual Checks

    private func checkHelmsmanQueue() async {
        let result = await InfrastructureExecutor.shell("curl -s http://localhost:5682/tasks?status=pending | python3 -c 'import json,sys; print(len(json.load(sys.stdin)))'")

        if result.exitCode == 0, let count = Int(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)) {
            // AUTO-DISPATCH: If queue grows suspiciously fast, investigate
            if let last = lastHelmsmanCheck, count > lastErrorCount + 10 {
                await autoDispatchTask(
                    task: "Investigate Helmsman queue spike: \(lastErrorCount) → \(count) tasks",
                    project: "Helmsman",
                    owner: "NVIDIA-BAL",
                    effort: "S",
                    context: "BackgroundMonitor detected queue jumped from \(lastErrorCount) to \(count) in 60 seconds. Check for runaway task creation or stuck workers."
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

            // SELF-HEAL: Restart unhealthy containers
            for container in unhealthy {
                print("[BackgroundMonitor] Self-healing: restarting unhealthy container \(container)")
                let restart = await InfrastructureExecutor.shell("docker restart \(container)")

                if restart.exitCode == 0 {
                    NotificationService.shared.notify(
                        title: "Auto-Healed: \(container)",
                        message: "Detected unhealthy and auto-restarted",
                        priority: .normal
                    )
                } else {
                    // AUTO-DISPATCH: Container won't restart, needs human investigation
                    await autoDispatchTask(
                        task: "Fix unhealthy Docker container: \(container)",
                        project: "Infrastructure",
                        owner: "CHARLIE",
                        effort: "S",
                        context: "BackgroundMonitor attempted auto-restart but failed. Container \(container) is unhealthy and won't restart. Check logs: docker logs \(container)"
                    )

                    NotificationService.shared.notify(
                        title: "Self-Heal Failed: \(container)",
                        message: "Could not restart unhealthy container - task dispatched to Charlie",
                        priority: .critical
                    )
                }
            }
        }
    }

    private func checkDiskSpace() async {
        let result = await InfrastructureExecutor.shell("df -h / | tail -1 | awk '{print $5}' | sed 's/%//'")

        if result.exitCode == 0, let percentage = Int(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)) {
            if percentage > 90 {
                // AUTO-DISPATCH: Critical disk space needs immediate cleanup
                await autoDispatchTask(
                    task: "Free up disk space on Mac Mini (root volume \(percentage)% full)",
                    project: "Infrastructure",
                    owner: "NVIDIA-FAST",
                    effort: "S",
                    context: "BackgroundMonitor detected root volume at \(percentage)% capacity. Check Docker volumes, logs, and Xcode caches for cleanup candidates."
                )

                NotificationService.shared.notify(
                    title: "Disk Space Critical",
                    message: "Root volume is \(percentage)% full - cleanup task dispatched",
                    priority: .critical
                )
            }
        }
    }

    private func checkClaudeHealth() async {
        // Test ask_claude is working
        let result = await InfrastructureExecutor.shell("ask_claude 'test' --prefer haiku --max-tokens 10")

        if result.exitCode != 0 {
            print("[BackgroundMonitor] ask_claude health check failed, attempting self-heal")

            // Try Bedrock directly
            let bedrock = await InfrastructureExecutor.shell("ask_claude_bedrock 'test' --lane haiku --max-tokens 10")

            if bedrock.exitCode == 0 {
                print("[BackgroundMonitor] Bedrock working, subscription likely rate-limited (normal)")
            } else {
                // AUTO-DISPATCH: Claude integration completely down
                await autoDispatchTask(
                    task: "Fix Claude API integration (both subscription and Bedrock failing)",
                    project: "Infrastructure",
                    owner: "CHARLIE",
                    effort: "S",
                    context: "BackgroundMonitor detected both ask_claude subscription and Bedrock are failing. Check API keys, rate limits, and network connectivity."
                )

                NotificationService.shared.notify(
                    title: "Claude Integration Down",
                    message: "Both subscription and Bedrock failing - task dispatched",
                    priority: .critical
                )
            }
        }
    }

    // MARK: - Self-Diagnosis

    /// Run self-diagnosis: compare capabilities vs what Quinn should have
    private func runSelfDiagnosis() async {
        print("[BackgroundMonitor] Running weekly self-diagnosis...")

        // Read CAPABILITIES.md
        let capabilitiesPath = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Mobile Documents/iCloud~com~seayniclabs~sonique/Documents/SoniqueProfiles/Desktop/CAPABILITIES.md")

        guard let capabilitiesContent = try? String(contentsOf: capabilitiesPath, encoding: .utf8) else {
            print("[BackgroundMonitor] Could not read CAPABILITIES.md")
            return
        }

        // Extract "Cannot Do Yet" section
        let lines = capabilitiesContent.components(separatedBy: .newlines)
        var inCannotSection = false
        var gaps: [String] = []

        for line in lines {
            if line.contains("## What Quinn Cannot Do Yet") {
                inCannotSection = true
                continue
            }
            if inCannotSection && line.starts(with: "##") {
                break
            }
            if inCannotSection && line.starts(with: "- ❌") {
                let gap = line.replacingOccurrences(of: "- ❌ ", with: "").trimmingCharacters(in: .whitespaces)
                gaps.append(gap)
            }
        }

        print("[BackgroundMonitor] Found \(gaps.count) capability gaps")

        // Auto-dispatch feasible gaps (limit to 3 per week to avoid overwhelming the queue)
        let feasibleGaps = gaps.filter { gap in
            // Only small, well-defined features
            gap.contains("voice alerts") || gap.contains("push notifications") ||
            gap.contains("self-diagnosis routine") || gap.contains("learn from corrections")
        }.prefix(3)

        for gap in feasibleGaps {
            await autoDispatchTask(
                task: "Implement Quinn capability: \(gap)",
                project: "Sonique",
                owner: "AIDER-GEM",
                effort: "M",
                context: "Self-diagnosis detected missing capability from CAPABILITIES.md. Implement this feature following existing patterns in SoniqueBar."
            )
        }

        print("[BackgroundMonitor] Self-diagnosis complete - dispatched \(feasibleGaps.count) improvement tasks")
    }

    // MARK: - Auto Task Dispatch

    /// Automatically dispatch a task to helmsman when an issue is detected
    private func autoDispatchTask(task: String, project: String, owner: String, effort: String, context: String) async {
        print("[BackgroundMonitor] AUTO-DISPATCH: \(task)")

        // Create minimal brief (BackgroundMonitor tasks are diagnostic/reactive, not full builds)
        let brief = """
        ## Goal
        \(task)

        ## Context
        Source: BackgroundMonitor autonomous detection
        Project: \(project)
        \(context)

        ## Steps
        1. Investigate the reported issue
        2. Determine root cause
        3. Implement fix or escalate if requires manual intervention
        4. Verify resolution
        5. Document outcome

        ## Expected Output
        - Root cause identified
        - Fix implemented or reason for escalation documented
        - Verification proof (command + output)

        ## Success
        Issue resolved and system healthy
        """

        // Dispatch via helmsman REST API
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

        let tempFile = "/tmp/quinn-auto-dispatch-\(UUID().uuidString).json"
        do {
            try payload.write(toFile: tempFile, atomically: true, encoding: .utf8)

            // Read dispatch secret
            let secretPath = "/Volumes/data/secrets/dispatch_webhook_secret"
            guard let secret = try? String(contentsOfFile: secretPath).trimmingCharacters(in: .whitespacesAndNewlines) else {
                print("[BackgroundMonitor] ERROR: Could not read dispatch secret")
                return
            }

            let command = """
            curl -s -X POST http://localhost:5680/webhook/task-dispatch \
              -H 'Content-Type: application/json' \
              -H 'X-Dispatch-Secret: \(secret)' \
              -d @\(tempFile) && rm \(tempFile)
            """

            let result = await InfrastructureExecutor.shell(command)

            if result.exitCode == 0 {
                if let data = result.stdout.data(using: .utf8),
                   let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let taskNum = json["task_num"] as? Int {
                    print("[BackgroundMonitor] ✅ Task #\(taskNum) dispatched: \(task)")
                }
            } else {
                print("[BackgroundMonitor] ❌ Failed to dispatch task: \(result.stderr)")
            }
        } catch {
            print("[BackgroundMonitor] ❌ Error writing dispatch payload: \(error)")
        }
    }

    // MARK: - Event Registration

    /// Register a custom watch condition
    func watch(condition: @escaping () async -> Bool, onTrigger: @escaping () -> Void) {
        // TODO: Allow dynamic condition registration
    }
}
