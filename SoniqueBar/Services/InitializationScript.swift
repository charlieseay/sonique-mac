import Foundation
import os.log

/// Startup validation and auto-healing script for SoniqueBar
/// Runs health checks and repairs issues before accepting commands
struct InitializationScript {

    private static let logger = Logger(subsystem: "com.seayniclabs.soniquebar", category: "Init")

    struct HealthReport {
        var memoryValid: Bool = false
        var routingHealthy: Bool = false
        var servicesUp: Bool = false
        var errors: [String] = []
        var warnings: [String] = []
        var repaired: [String] = []

        var isHealthy: Bool {
            memoryValid && routingHealthy && servicesUp && errors.isEmpty
        }

        var summary: String {
            var lines: [String] = []
            if isHealthy {
                lines.append("✅ SoniqueBar initialized successfully")
            } else {
                lines.append("⚠️ SoniqueBar initialized with issues")
            }

            if !errors.isEmpty {
                lines.append("\nErrors:")
                errors.forEach { lines.append("  ❌ \($0)") }
            }

            if !warnings.isEmpty {
                lines.append("\nWarnings:")
                warnings.forEach { lines.append("  ⚠️  \($0)") }
            }

            if !repaired.isEmpty {
                lines.append("\nAuto-repaired:")
                repaired.forEach { lines.append("  🔧 \($0)") }
            }

            return lines.joined(separator: "\n")
        }
    }

    /// Run full initialization: validate + auto-heal + report
    static func initialize() async -> HealthReport {
        logger.info("🚀 Starting SoniqueBar initialization...")
        var report = HealthReport()

        // 1. Validate memory layer
        logger.info("📝 Checking memory layer...")
        await validateMemory(report: &report)

        // 2. Test routing (LLM availability)
        logger.info("🔌 Testing LLM routing...")
        await testRouting(report: &report)

        // 3. Check critical services
        logger.info("🏥 Checking critical services...")
        await checkServices(report: &report)

        print(report.summary)
        return report
    }

    // MARK: - Health Checks

    private static func validateMemory(report: inout HealthReport) async {
        let memoryPath = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/SoniqueBar/memory")

        // Check if memory directory exists
        guard FileManager.default.fileExists(atPath: memoryPath.path) else {
            report.errors.append("Memory directory missing: \(memoryPath.path)")

            // Auto-repair: create directory
            do {
                try FileManager.default.createDirectory(at: memoryPath, withIntermediateDirectories: true)
                report.repaired.append("Created missing memory directory")
                report.memoryValid = true
            } catch {
                report.errors.append("Failed to create memory directory: \(error.localizedDescription)")
            }
            return
        }

        // Validate memory files exist and aren't corrupted
        let requiredFiles = ["conversations.json", "lessons.json"]
        var allValid = true

        for file in requiredFiles {
            let filePath = memoryPath.appendingPathComponent(file)

            if !FileManager.default.fileExists(atPath: filePath.path) {
                // Auto-repair: create empty valid JSON
                let emptyJSON = "[]"
                do {
                    try emptyJSON.write(to: filePath, atomically: true, encoding: .utf8)
                    report.repaired.append("Created missing \(file)")
                } catch {
                    report.errors.append("Failed to create \(file): \(error.localizedDescription)")
                    allValid = false
                }
                continue
            }

            // Validate JSON isn't corrupted
            if let data = try? Data(contentsOf: filePath),
               (try? JSONSerialization.jsonObject(with: data)) == nil {
                report.warnings.append("\(file) is corrupted, resetting")

                // Auto-repair: reset to empty array
                let emptyJSON = "[]"
                do {
                    try emptyJSON.write(to: filePath, atomically: true, encoding: .utf8)
                    report.repaired.append("Repaired corrupted \(file)")
                } catch {
                    report.errors.append("Failed to repair \(file): \(error.localizedDescription)")
                    allValid = false
                }
            }
        }

        report.memoryValid = allValid
    }

    private static func testRouting(report: inout HealthReport) async {
        // Just check if Ollama is up - LLMRouter will handle fallback
        let ollamaResult = await Self.shell("curl -sf http://localhost:11434/api/tags")
        if ollamaResult.exitCode == 0 {
            report.routingHealthy = true
        } else {
            report.warnings.append("Ollama not running (will use fallback LLM)")
            report.routingHealthy = true // Not a blocker - we have fallbacks
        }
    }

    private static func checkServices(report: inout HealthReport) async {
        var servicesOK = true

        // Check Helmsman REST API
        let helmsmanResult = await Self.shell("curl -sf http://localhost:5682/health")
        if helmsmanResult.exitCode == 0 && helmsmanResult.stdout.contains("ok") {
            // OK
        } else {
            report.warnings.append("Helmsman REST API not responding")
            servicesOK = false
        }

        // Check Docker daemon
        let dockerResult = await Self.shell("docker info")
        if dockerResult.exitCode != 0 {
            report.warnings.append("Docker daemon not running")
            servicesOK = false
        }


        report.servicesUp = servicesOK
    }

    // MARK: - Shell Helper

    private static func shell(_ command: String) async -> (stdout: String, stderr: String, exitCode: Int32) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-c", command]

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        do {
            try process.run()
            process.waitUntilExit()

            let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
            let errData = errPipe.fileHandleForReading.readDataToEndOfFile()

            return (
                String(data: outData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
                String(data: errData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
                process.terminationStatus
            )
        } catch {
            return ("", error.localizedDescription, -1)
        }
    }
}
