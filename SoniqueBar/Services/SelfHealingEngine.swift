import Foundation
import os.log

/// Quinn's self-healing engine - detects, diagnoses, and fixes her own issues
@MainActor
class SelfHealingEngine: ObservableObject {
    static let shared = SelfHealingEngine()

    @Published var isHealthy = true
    @Published var lastSelfCheck: Date?
    @Published var healingHistory: [HealingEvent] = []

    private let logger = Logger(subsystem: "com.seayniclabs.soniquebar", category: "SelfHealing")
    private var healthTimer: Timer?
    private let selfCheckInterval: TimeInterval = 30.0  // Self-check every 30 seconds

    struct HealingEvent: Codable {
        let timestamp: Date
        let issue: String
        let diagnosis: String
        let action: String
        let success: Bool
    }

    private init() {
        startSelfMonitoring()
    }

    // MARK: - Self-Monitoring

    func startSelfMonitoring() {
        logger.info("🏥 Starting self-healing engine")

        healthTimer = Timer.scheduledTimer(withTimeInterval: selfCheckInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                await self?.performSelfCheck()
            }
        }

        // Immediate first check
        Task {
            await performSelfCheck()
        }
    }

    func stopSelfMonitoring() {
        healthTimer?.invalidate()
        healthTimer = nil
    }

    /// Perform comprehensive self-check and auto-heal issues
    private func performSelfCheck() async {
        lastSelfCheck = Date()

        // Check all critical subsystems
        await checkCommandServer()
        await checkMemoryService()
        await checkBackgroundMonitor()
        await checkLLMConnectivity()
        await checkICloudSync()
        await checkDiskSpace()

        // Overall health assessment
        isHealthy = healingHistory.isEmpty || healingHistory.last?.success == true
    }

    // MARK: - Individual Health Checks

    private func checkCommandServer() async {
        // Check if CommandServer is responding
        let result = await InfrastructureExecutor.shell("curl -s --max-time 2 http://localhost:8890/health")

        if result.exitCode != 0 {
            await diagnoseAndHeal(
                issue: "CommandServer not responding on port 8890",
                diagnosis: "Port may be blocked, listener crashed, or app restarted",
                autoFix: {
                    // Attempt to restart CommandServer (if possible without restarting entire app)
                    self.logger.warning("⚠️ CommandServer down - would trigger app restart")
                    return false  // Can't self-restart from within
                },
                escalate: true
            )
        }
    }

    private func checkMemoryService() async {
        // Verify memory files are accessible
        let iCloudDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Mobile Documents/iCloud~com~seayniclabs~sonique/Documents/SoniqueProfiles/Desktop")

        let requiredFiles = ["IDENTITY.md", "RULES.md", "SOUL.md", "CAPABILITIES.md"]
        var missingFiles: [String] = []

        for file in requiredFiles {
            let path = iCloudDir.appendingPathComponent(file)
            if !FileManager.default.fileExists(atPath: path.path) {
                missingFiles.append(file)
            }
        }

        if !missingFiles.isEmpty {
            await diagnoseAndHeal(
                issue: "Missing iCloud memory files: \(missingFiles.joined(separator: ", "))",
                diagnosis: "iCloud sync may be paused or files were deleted",
                autoFix: {
                    // Create placeholder files to prevent crashes
                    for file in missingFiles {
                        let path = iCloudDir.appendingPathComponent(file)
                        let placeholder = "# \(file.replacingOccurrences(of: ".md", with: ""))\n\nPlaceholder - file was missing and auto-recreated by self-healing.\n"
                        try? placeholder.write(to: path, atomically: true, encoding: .utf8)
                    }
                    self.logger.info("✅ Created placeholder memory files")
                    return true
                },
                escalate: true
            )
        }
    }

    private func checkBackgroundMonitor() async {
        // Verify BackgroundMonitor is running
        if !BackgroundMonitor.shared.isMonitoring {
            await diagnoseAndHeal(
                issue: "BackgroundMonitor not running",
                diagnosis: "Monitor was stopped or never started",
                autoFix: {
                    BackgroundMonitor.shared.startMonitoring()
                    self.logger.info("✅ Restarted BackgroundMonitor")
                    return true
                },
                escalate: false
            )
        }
    }

    private func checkLLMConnectivity() async {
        // Test ask_claude connection
        let result = await InfrastructureExecutor.shell("ask_claude 'ping' --prefer haiku --max-tokens 5")

        if result.exitCode != 0 {
            await diagnoseAndHeal(
                issue: "ask_claude not responding (exit code \(result.exitCode))",
                diagnosis: "Claude API may be rate-limited, credentials invalid, or network down",
                autoFix: {
                    // Try Bedrock fallback
                    let bedrock = await InfrastructureExecutor.shell("ask_claude_bedrock 'ping' --lane haiku --max-tokens 5")
                    if bedrock.exitCode == 0 {
                        self.logger.info("✅ Bedrock fallback working")
                        return true
                    }
                    return false
                },
                escalate: true
            )
        }
    }

    private func checkICloudSync() async {
        // Check if iCloud container is accessible
        let iCloudDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Mobile Documents/iCloud~com~seayniclabs~sonique")

        if !FileManager.default.fileExists(atPath: iCloudDir.path) {
            await diagnoseAndHeal(
                issue: "iCloud container not accessible",
                diagnosis: "iCloud Drive may be disabled or container not initialized",
                autoFix: {
                    // Create local fallback directory
                    let fallback = FileManager.default.homeDirectoryForCurrentUser
                        .appendingPathComponent("Library/Application Support/SoniqueBar/memory")
                    try? FileManager.default.createDirectory(at: fallback, withIntermediateDirectories: true)
                    self.logger.warning("⚠️ Using local fallback - iCloud unavailable")
                    return true
                },
                escalate: true
            )
        }
    }

    private func checkDiskSpace() async {
        let result = await InfrastructureExecutor.shell("df -h / | tail -1 | awk '{print $5}' | sed 's/%//'")

        if result.exitCode == 0, let percentage = Int(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)) {
            if percentage > 95 {
                await diagnoseAndHeal(
                    issue: "Critical disk space: \(percentage)% full",
                    diagnosis: "Root volume critically low - may cause app crashes",
                    autoFix: {
                        // Clean up known safe locations
                        let cleaned = await self.emergencyDiskCleanup()
                        return cleaned > 0
                    },
                    escalate: true
                )
            }
        }
    }

    // MARK: - Auto-Healing Actions

    private func diagnoseAndHeal(
        issue: String,
        diagnosis: String,
        autoFix: () async -> Bool,
        escalate: Bool
    ) async {
        logger.warning("🔍 DETECTED: \(issue)")
        logger.info("📋 DIAGNOSIS: \(diagnosis)")

        // Attempt auto-fix
        logger.info("🔧 Attempting auto-heal...")
        let success = await autoFix()

        let event = HealingEvent(
            timestamp: Date(),
            issue: issue,
            diagnosis: diagnosis,
            action: success ? "Auto-healed" : "Failed to auto-heal",
            success: success
        )

        healingHistory.append(event)

        // Keep only last 50 events
        if healingHistory.count > 50 {
            healingHistory.removeFirst()
        }

        // Save to log file
        await logHealingEvent(event)

        if success {
            logger.info("✅ AUTO-HEALED: \(issue)")
            NotificationService.shared.notify(
                title: "Quinn Self-Healed",
                message: issue,
                priority: .normal
            )
        } else {
            logger.error("❌ FAILED TO HEAL: \(issue)")

            if escalate {
                // Create task in helmsman for human intervention
                await escalateToHelmsman(issue: issue, diagnosis: diagnosis)
            }
        }
    }

    private func emergencyDiskCleanup() async -> Int {
        var freedMB = 0

        // Clean Xcode DerivedData (safe to delete, rebuilds automatically)
        let derivedData = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Developer/Xcode/DerivedData")

        if let items = try? FileManager.default.contentsOfDirectory(at: derivedData, includingPropertiesForKeys: nil) {
            for item in items {
                if let size = try? FileManager.default.attributesOfItem(atPath: item.path)[.size] as? Int {
                    try? FileManager.default.removeItem(at: item)
                    freedMB += size / 1_000_000
                }
            }
        }

        // Clean iOS Simulator caches
        let simCache = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Developer/CoreSimulator/Caches")

        if FileManager.default.fileExists(atPath: simCache.path) {
            if let size = try? FileManager.default.attributesOfItem(atPath: simCache.path)[.size] as? Int {
                try? FileManager.default.removeItem(at: simCache)
                freedMB += size / 1_000_000
            }
        }

        logger.info("🧹 Emergency cleanup freed ~\(freedMB)MB")
        return freedMB
    }

    private func escalateToHelmsman(issue: String, diagnosis: String) async {
        let brief = """
        ## Goal
        Fix Quinn self-healing failure: \(issue)

        ## Context
        Source: Quinn's SelfHealingEngine autonomous detection
        Diagnosis: \(diagnosis)
        Auto-heal attempted but failed
        Requires code fix + redeploy

        ## Steps
        1. Investigate the reported issue on Mac Mini
        2. Determine root cause and implement fix in SoniqueBar codebase
        3. Commit and push to GitHub (feature/sidecar-packaging branch)
        4. Run auto-deploy: `/Users/charlieseay/Projects/sonique-mac/scripts/auto-deploy.sh`
        5. Auto-deploy will: pull code, build, update launchd, restart Quinn
        6. Verify Quinn's health check passes after redeploy
        7. Document fix in Quinn's CAPABILITIES.md

        ## Expected Output
        - Root cause identified and fixed in code
        - Git commit pushed to GitHub
        - Quinn redeployed via auto-deploy.sh (pulls, builds, restarts)
        - Health check passing (curl http://localhost:8890/health)
        - Prevention added to SelfHealingEngine for future

        ## Success
        Quinn auto-redeployed and self-check passes without errors

        ## Automation
        After fixing code and pushing to GitHub:
        ```bash
        /Users/charlieseay/Projects/sonique-mac/scripts/auto-deploy.sh
        ```
        This pulls latest, builds, and restarts Quinn automatically.
        """

        let escapedBrief = brief
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")

        let payload = """
        {
          "task": "Fix Quinn self-healing failure: \(issue.replacingOccurrences(of: "\"", with: "\\\""))",
          "owner": "CHARLIE",
          "project": "Sonique",
          "effort": "S",
          "brief_text": "\(escapedBrief)"
        }
        """

        let tempFile = "/tmp/quinn-selfheal-escalate-\(UUID().uuidString).json"
        try? payload.write(toFile: tempFile, atomically: true, encoding: .utf8)

        if let secret = try? String(contentsOfFile: "/Volumes/data/secrets/dispatch_webhook_secret").trimmingCharacters(in: .whitespacesAndNewlines) {
            let command = """
            curl -s -X POST http://localhost:5680/webhook/task-dispatch \
              -H 'Content-Type: application/json' \
              -H 'X-Dispatch-Secret: \(secret)' \
              -d @\(tempFile) && rm \(tempFile)
            """

            let result = await InfrastructureExecutor.shell(command)

            if result.exitCode == 0 {
                logger.info("📤 Escalated to helmsman: \(issue)")
            }
        }
    }

    private func logHealingEvent(_ event: HealingEvent) async {
        let logDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/SoniqueBar/logs")

        try? FileManager.default.createDirectory(at: logDir, withIntermediateDirectories: true)

        let logFile = logDir.appendingPathComponent("self-healing.jsonl")

        if let data = try? JSONEncoder().encode(event) {
            let line = String(data: data, encoding: .utf8)! + "\n"

            if let handle = try? FileHandle(forWritingTo: logFile) {
                handle.seekToEndOfFile()
                handle.write(line.data(using: .utf8)!)
                try? handle.close()
            } else {
                try? line.data(using: .utf8)?.write(to: logFile)
            }
        }
    }

    // MARK: - Manual Triggers

    /// Force a full self-diagnosis now (can be triggered by voice command)
    func runFullDiagnostic() async -> String {
        logger.info("🔬 Running full diagnostic (manual trigger)")

        await performSelfCheck()

        let recentEvents = healingHistory.suffix(5)
        let issueCount = recentEvents.filter { !$0.success }.count
        let healedCount = recentEvents.filter { $0.success }.count

        if issueCount == 0 {
            return "All systems healthy. No issues detected."
        } else if healedCount > 0 {
            return "Found \(issueCount) issue\(issueCount == 1 ? "" : "s"), auto-healed \(healedCount). Check logs for details."
        } else {
            return "Found \(issueCount) issue\(issueCount == 1 ? "" : "s") that couldn't be auto-fixed. Tasks created for Charlie."
        }
    }
}
