import Foundation
import os.log

/// Fish Speech TTS manager - starts/stops bundled Fish Speech Rust binary
/// Fish TTS runs on port 3000 as a subprocess of SoniqueBar
class FishTTSManager {
    private let logger = Logger(subsystem: "com.seayniclabs.soniquebar", category: "FishTTSManager")

    static let shared = FishTTSManager()

    private var process: Process?
    private var isRunning = false

    private let fishBinaryPath: String
    private let voicesPath: String
    private let port: Int = 3000

    private init() {
        // Path to bundled Fish TTS binary
        let resourcePath = Bundle.main.resourcePath ?? ""
        self.fishBinaryPath = "\(resourcePath)/fish-tts"
        self.voicesPath = "\(resourcePath)/voices"

        logger.info("[FishTTSManager] Initialized with binary: \(self.fishBinaryPath)")
    }

    /// Start Fish TTS subprocess
    func start() async -> Bool {
        guard !isRunning else {
            logger.info("[FishTTSManager] Already running")
            return true
        }

        // Check if fish-tts binary exists
        guard FileManager.default.fileExists(atPath: fishBinaryPath) else {
            logger.error("[FishTTSManager] Fish TTS binary not found at \(self.fishBinaryPath)")
            return false
        }

        logger.info("[FishTTSManager] Starting Fish TTS on port \(self.port)...")

        let process = Process()
        process.executableURL = URL(fileURLWithPath: fishBinaryPath)
        process.arguments = [
            "--port", String(port),
            "--voice-dir", voicesPath
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
                self.logger.info("[Fish TTS stdout] \(output.trimmingCharacters(in: .whitespacesAndNewlines))")
            }
        }

        errorPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if !data.isEmpty, let output = String(data: data, encoding: .utf8) {
                self.logger.error("[Fish TTS stderr] \(output.trimmingCharacters(in: .whitespacesAndNewlines))")
            }
        }

        do {
            try process.run()
            self.process = process
            self.isRunning = true

            logger.info("[FishTTSManager] Fish TTS process started (PID: \(process.processIdentifier))")

            // Wait a moment for startup
            try await Task.sleep(for: .seconds(2))

            // Health check
            let healthy = await healthCheck()
            if healthy {
                logger.info("[FishTTSManager] ✓ Fish TTS is healthy and ready")
                return true
            } else {
                logger.warning("[FishTTSManager] ⚠️ Fish TTS started but health check failed (may still be initializing)")
                return true  // Return true anyway - it might just need more time
            }

        } catch {
            logger.error("[FishTTSManager] Failed to start Fish TTS: \(error.localizedDescription)")
            return false
        }
    }

    /// Stop Fish TTS subprocess
    func stop() {
        guard let process = process, isRunning else {
            logger.info("[FishTTSManager] Not running")
            return
        }

        logger.info("[FishTTSManager] Stopping Fish TTS...")
        process.terminate()
        self.process = nil
        self.isRunning = false

        logger.info("[FishTTSManager] Fish TTS stopped")
    }

    /// Check if Fish TTS is healthy
    func healthCheck() async -> Bool {
        // Fish TTS doesn't have a /health endpoint, so we'll check /v1/voices
        guard let url = URL(string: "http://127.0.0.1:\(port)/v1/voices") else {
            return false
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 5

        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            if let httpResponse = response as? HTTPURLResponse {
                let healthy = httpResponse.statusCode == 200
                if !healthy {
                    logger.warning("[FishTTSManager] Health check failed: HTTP \(httpResponse.statusCode)")
                }
                return healthy
            }
            return false
        } catch {
            logger.error("[FishTTSManager] Health check error: \(error.localizedDescription)")
            return false
        }
    }

    /// Get current status
    func getStatus() -> (running: Bool, port: Int) {
        return (isRunning, port)
    }
}
