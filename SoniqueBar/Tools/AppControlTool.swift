import Foundation

/// Wraps `/usr/bin/open -a` and `/usr/bin/osascript` for app control.
/// Requires Accessibility permission for osascript automation of other apps.
enum AppControlTool {

    static let toolName = "app_control"

    /// Execute the app control tool.
    /// Input keys:
    ///   - "action": "open" | "run_script"
    ///   - "app": app name (for "open")
    ///   - "script": AppleScript text (for "run_script")
    static func execute(input: [String: Any]) async -> String {
        guard let action = input["action"] as? String else {
            return "Please specify an action: 'open' or 'run_script'."
        }

        switch action {
        case "open":
            return await openApp(input: input)
        case "run_script":
            return await runAppleScript(input: input)
        default:
            return "Unknown action '\(action)'. Use 'open' or 'run_script'."
        }
    }

    // MARK: - Open App

    private static func openApp(input: [String: Any]) async -> String {
        guard let appName = input["app"] as? String, !appName.isEmpty else {
            return "Please specify an app name."
        }

        // Sanitize: only allow alphanumeric, spaces, dots, and hyphens.
        let allowed = CharacterSet.alphanumerics.union(.init(charactersIn: " .-"))
        let sanitized = String(appName.unicodeScalars.filter { allowed.contains($0) })
            .trimmingCharacters(in: .whitespaces)

        guard !sanitized.isEmpty else {
            return "App name contained only invalid characters."
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["-a", sanitized]

        let errPipe = Pipe()
        process.standardError = errPipe

        do {
            try process.run()
            let completed = await waitWithTimeout(process, seconds: 10)
            if !completed {
                process.terminate()
                return "Opening \(sanitized) timed out."
            }
            if process.terminationStatus == 0 {
                return "Opening \(sanitized)."
            } else {
                return "I couldn't find an app called '\(sanitized)'."
            }
        } catch {
            return "Failed to open app: \(error.localizedDescription)"
        }
    }

    // MARK: - Run AppleScript

    private static func runAppleScript(input: [String: Any]) async -> String {
        guard let script = input["script"] as? String, !script.isEmpty else {
            return "Please provide an AppleScript."
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        // Pass script via stdin to avoid any shell interpolation.
        process.arguments = ["-"]

        let inPipe = Pipe()
        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardInput = inPipe
        process.standardOutput = outPipe
        process.standardError = errPipe

        do {
            try process.run()
            if let scriptData = script.data(using: .utf8) {
                inPipe.fileHandleForWriting.write(scriptData)
            }
            inPipe.fileHandleForWriting.closeFile()

            let completed = await waitWithTimeout(process, seconds: 10)
            if !completed {
                process.terminate()
                return "AppleScript timed out."
            }

            if process.terminationStatus == 0 {
                let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
                let output = String(data: outData, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                return output.isEmpty ? "Done." : output
            } else {
                let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
                let errMsg = String(data: errData, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                if errMsg.lowercased().contains("not allowed") || errMsg.lowercased().contains("permission") {
                    return "I don't have permission for that. Check System Settings → Privacy & Security → Accessibility and enable SoniqueBar."
                }
                return "AppleScript failed: \(errMsg)"
            }
        } catch {
            return "I don't have permission for that. Check System Settings → Privacy & Security → Accessibility and enable SoniqueBar."
        }
    }

    private static func waitWithTimeout(_ process: Process, seconds: Double) async -> Bool {
        await withCheckedContinuation { continuation in
            var resumed = false
            let lock = NSLock()

            let deadline = DispatchTime.now() + seconds
            DispatchQueue.global().asyncAfter(deadline: deadline) {
                lock.lock()
                defer { lock.unlock() }
                if !resumed {
                    resumed = true
                    if process.isRunning { process.terminate() }
                    continuation.resume(returning: false)
                }
            }

            DispatchQueue.global().async {
                process.waitUntilExit()
                lock.lock()
                defer { lock.unlock() }
                if !resumed {
                    resumed = true
                    continuation.resume(returning: true)
                }
            }
        }
    }
}
