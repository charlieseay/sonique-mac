import Foundation
import os.log

/// VoiceBox subprocess manager - starts/stops embedded VoiceBox backend
/// VoiceBox runs on port 17493 as a subprocess of SoniqueBar
class VoiceBoxManager {
    private let logger = Logger(subsystem: "com.seayniclabs.soniquebar", category: "VoiceBoxManager")

    static let shared = VoiceBoxManager()

    private var process: Process?
    private var isRunning = false

    private let voiceboxPath: String
    private let port: Int = 17493

    private init() {
        // Path to VoiceBox backend
        let homeDir = FileManager.default.homeDirectoryForCurrentUser.path
        self.voiceboxPath = "\(homeDir)/Projects/voicebox/backend"

        logger.info("[VoiceBoxManager] Initialized with path: \(self.voiceboxPath)")
    }

    /// Start VoiceBox backend subprocess
    func start() async -> Bool {
        guard !isRunning else {
            logger.info("[VoiceBoxManager] Already running")
            return true
        }

        // Check if voicebox backend exists
        guard FileManager.default.fileExists(atPath: voiceboxPath) else {
            logger.error("[VoiceBoxManager] VoiceBox backend not found at \(self.voiceboxPath)")
            return false
        }

        logger.info("[VoiceBoxManager] Starting VoiceBox backend on port \(self.port)...")

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.currentDirectoryURL = URL(fileURLWithPath: voiceboxPath)
        process.arguments = [
            "-m", "backend.main",
            "--host", "127.0.0.1",
            "--port", String(port)
        ]

        // Capture output for debugging
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        // Log output in background
        outputPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if !data.isEmpty, let output = String(data: data, encoding: .utf8) {
                self.logger.info("[VoiceBox stdout] \(output.trimmingCharacters(in: .whitespacesAndNewlines))")
            }
        }

        errorPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if !data.isEmpty, let output = String(data: data, encoding: .utf8) {
                self.logger.error("[VoiceBox stderr] \(output.trimmingCharacters(in: .whitespacesAndNewlines))")
            }
        }

        do {
            try process.run()
            self.process = process
            self.isRunning = true

            logger.info("[VoiceBoxManager] VoiceBox process started (PID: \(process.processIdentifier))")

            // Wait a moment for startup
            try await Task.sleep(for: .seconds(2))

            // Health check
            let healthy = await healthCheck()
            if healthy {
                logger.info("[VoiceBoxManager] ✓ VoiceBox is healthy and ready")
                return true
            } else {
                logger.warning("[VoiceBoxManager] ⚠️ VoiceBox started but health check failed (may still be initializing)")
                return true  // Return true anyway - it might just need more time
            }

        } catch {
            logger.error("[VoiceBoxManager] Failed to start VoiceBox: \(error.localizedDescription)")
            return false
        }
    }

    /// Stop VoiceBox backend subprocess
    func stop() {
        guard let process = process, isRunning else {
            logger.info("[VoiceBoxManager] Not running")
            return
        }

        logger.info("[VoiceBoxManager] Stopping VoiceBox...")
        process.terminate()
        self.process = nil
        self.isRunning = false

        logger.info("[VoiceBoxManager] VoiceBox stopped")
    }

    /// Check if VoiceBox is healthy
    func healthCheck() async -> Bool {
        guard let url = URL(string: "http://127.0.0.1:\(port)/health") else {
            return false
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 5

        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            if let httpResponse = response as? HTTPURLResponse {
                let healthy = httpResponse.statusCode == 200
                if !healthy {
                    logger.warning("[VoiceBoxManager] Health check failed: HTTP \(httpResponse.statusCode)")
                }
                return healthy
            }
            return false
        } catch {
            logger.error("[VoiceBoxManager] Health check error: \(error.localizedDescription)")
            return false
        }
    }

    /// Get current status
    func getStatus() -> (running: Bool, port: Int) {
        return (isRunning, port)
    }
}
