import Foundation

/// Wraps `/usr/sbin/screencapture -c` to capture the screen to the clipboard.
/// Requires Screen Recording permission in System Settings → Privacy & Security.
enum ScreenshotTool {

    static let toolName = "take_screenshot"

    /// Execute the screenshot tool. Captures full screen to clipboard.
    static func execute(input: [String: Any]) async -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        // -c: copy to clipboard instead of saving a file
        // -x: suppress sound
        process.arguments = ["-c", "-x"]

        let errPipe = Pipe()
        process.standardError = errPipe

        do {
            try process.run()
            let completed = await waitWithTimeout(process, seconds: 10)
            if !completed {
                process.terminate()
                return "Screenshot timed out."
            }
            if process.terminationStatus == 0 {
                return "Screenshot copied to clipboard."
            } else {
                let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
                let errMsg = String(data: errData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                if errMsg.lowercased().contains("permission") || errMsg.lowercased().contains("access") {
                    return "I don't have permission to capture the screen. Check System Settings → Privacy & Security → Screen Recording and enable SoniqueBar."
                }
                return "Screenshot failed. Check Screen Recording permission in System Settings."
            }
        } catch {
            return "I don't have permission to capture the screen. Check System Settings → Privacy & Security → Screen Recording and enable SoniqueBar."
        }
    }

    private static func waitWithTimeout(_ process: Process, seconds: Double) async -> Bool {
        await withCheckedContinuation { continuation in
            let deadline = DispatchTime.now() + seconds
            DispatchQueue.global().asyncAfter(deadline: deadline) {
                if process.isRunning {
                    continuation.resume(returning: false)
                }
            }
            DispatchQueue.global().async {
                process.waitUntilExit()
                continuation.resume(returning: true)
            }
        }
    }
}
