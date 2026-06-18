import Foundation
import AppKit

/// Provides continuous screen awareness by capturing periodic screenshots
/// and maintaining a rolling buffer of recent screen states
@MainActor
class ScreenAwarenessService: ObservableObject {
    static let shared = ScreenAwarenessService()

    @Published var isMonitoring = false
    @Published var lastCaptureTime: Date?

    private var captureTimer: Timer?
    private let captureInterval: TimeInterval = 10.0  // Capture every 10 seconds
    private let screenshotDir = "/tmp/sonique-screen-awareness"
    private let maxStoredScreenshots = 6  // Keep last minute of screens (6 x 10s)

    private init() {
        setupScreenshotDirectory()
    }

    private func setupScreenshotDirectory() {
        try? FileManager.default.createDirectory(
            atPath: screenshotDir,
            withIntermediateDirectories: true
        )
    }

    /// Start continuous screen monitoring
    func startMonitoring() {
        guard !isMonitoring else { return }

        isMonitoring = true

        // Capture immediately
        captureScreen()

        // Then capture on interval
        captureTimer = Timer.scheduledTimer(
            withTimeInterval: captureInterval,
            repeats: true
        ) { [weak self] _ in
            Task { @MainActor in
                self?.captureScreen()
            }
        }
    }

    /// Stop continuous screen monitoring
    func stopMonitoring() {
        isMonitoring = false
        captureTimer?.invalidate()
        captureTimer = nil
    }

    /// Capture current screen state
    private func captureScreen() {
        let timestamp = Int(Date().timeIntervalSince1970)
        let path = "\(screenshotDir)/screen-\(timestamp).png"

        // Use screencapture to capture the main display
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        task.arguments = ["-x", "-t", "png", path]

        do {
            try task.run()
            task.waitUntilExit()

            if task.terminationStatus == 0 {
                lastCaptureTime = Date()
                cleanupOldScreenshots()
            }
        } catch {
            print("[ScreenAwareness] Capture failed: \(error)")
        }
    }

    /// Remove old screenshots beyond the buffer size
    private func cleanupOldScreenshots() {
        guard let files = try? FileManager.default.contentsOfDirectory(atPath: screenshotDir) else { return }

        let screenshots = files
            .filter { $0.hasPrefix("screen-") && $0.hasSuffix(".png") }
            .sorted()

        if screenshots.count > maxStoredScreenshots {
            let toDelete = screenshots.prefix(screenshots.count - maxStoredScreenshots)
            for file in toDelete {
                try? FileManager.default.removeItem(atPath: "\(screenshotDir)/\(file)")
            }
        }
    }

    /// Get path to the most recent screenshot
    func getLatestScreenshot() -> String? {
        guard let files = try? FileManager.default.contentsOfDirectory(atPath: screenshotDir) else {
            return nil
        }

        let screenshots = files
            .filter { $0.hasPrefix("screen-") && $0.hasSuffix(".png") }
            .sorted()

        guard let latest = screenshots.last else { return nil }
        return "\(screenshotDir)/\(latest)"
    }

    /// Get all recent screenshots (most recent first)
    func getRecentScreenshots(limit: Int = 6) -> [String] {
        guard let files = try? FileManager.default.contentsOfDirectory(atPath: screenshotDir) else {
            return []
        }

        return files
            .filter { $0.hasPrefix("screen-") && $0.hasSuffix(".png") }
            .sorted()
            .suffix(limit)
            .reversed()
            .map { "\(screenshotDir)/\($0)" }
    }
}
