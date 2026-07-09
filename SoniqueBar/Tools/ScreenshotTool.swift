import Foundation

/// Tool for capturing screenshots
enum ScreenshotTool {
    static let toolName = "screenshot"

    static func execute(input: [String: Any]) async -> String {
        let action = input["action"] as? String ?? "clipboard"

        let process = Process()
        process.launchPath = "/usr/sbin/screencapture"

        var arguments: [String] = []

        switch action {
        case "clipboard":
            // Capture to clipboard
            arguments = ["-c"]

        case "file":
            // Capture to file
            guard let path = input["path"] as? String else {
                return "ERROR: 'path' parameter required for file action"
            }
            arguments = [path]

        case "interactive":
            // Interactive selection
            guard let path = input["path"] as? String else {
                return "ERROR: 'path' parameter required for interactive action"
            }
            arguments = ["-i", path]

        case "window":
            // Capture specific window
            arguments = ["-w", "-c"]

        default:
            return "ERROR: Unknown action '\(action)'. Use: clipboard, file, interactive, window"
        }

        process.arguments = arguments

        let pipe = Pipe()
        process.standardError = pipe

        do {
            try process.run()
            process.waitUntilExit()

            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let errorOutput = String(data: data, encoding: .utf8) ?? ""

            if process.terminationStatus == 0 {
                if action == "clipboard" {
                    return "OK: Screenshot captured to clipboard"
                } else if let path = input["path"] as? String {
                    return "OK: Screenshot saved to \(path)"
                } else {
                    return "OK: Screenshot captured"
                }
            } else {
                return "ERROR: \(errorOutput.isEmpty ? "Screenshot failed" : errorOutput)"
            }
        } catch {
            return "ERROR: \(error.localizedDescription)"
        }
    }
}
