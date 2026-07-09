import Foundation

/// Tool for controlling macOS applications (open, quit, etc.)
enum AppControlTool {
    static let toolName = "app_control"

    static func execute(input: [String: Any]) async -> String {
        guard let app = input["app"] as? String else {
            return "ERROR: Missing 'app' parameter"
        }

        let action = input["action"] as? String ?? "open"

        let process = Process()

        switch action {
        case "open":
            process.launchPath = "/usr/bin/open"
            process.arguments = ["-a", app]

        case "quit":
            process.launchPath = "/usr/bin/osascript"
            process.arguments = ["-e", "tell application \"\(app)\" to quit"]

        case "activate":
            process.launchPath = "/usr/bin/osascript"
            process.arguments = ["-e", "tell application \"\(app)\" to activate"]

        default:
            return "ERROR: Unknown action '\(action)'. Use: open, quit, activate"
        }

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        do {
            try process.run()
            process.waitUntilExit()

            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: data, encoding: .utf8) ?? ""

            if process.terminationStatus == 0 {
                return "OK: \(action) '\(app)' succeeded"
            } else {
                return "ERROR: \(output.isEmpty ? "Failed to \(action) '\(app)'" : output)"
            }
        } catch {
            return "ERROR: \(error.localizedDescription)"
        }
    }
}
