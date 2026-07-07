import Foundation

/// Wraps `/usr/bin/pbcopy` and `/usr/bin/pbpaste` for clipboard read/write.
/// Never logs clipboard contents to persistent storage.
enum ClipboardTool {

    static let toolName = "clipboard"

    /// Execute the clipboard tool.
    /// Input key: "action" — "read" or "write"
    /// Input key: "text" — content to write (only for "write" action)
    static func execute(input: [String: Any]) async -> String {
        let action = (input["action"] as? String ?? "read").lowercased()

        switch action {
        case "read":
            return await readClipboard()
        case "write":
            guard let text = input["text"] as? String else {
                return "Please provide 'text' to write to the clipboard."
            }
            return await writeClipboard(text: text)
        default:
            return "Unknown action '\(action)'. Use 'read' or 'write'."
        }
    }

    // MARK: - Read clipboard via pbpaste

    private static func readClipboard() async -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pbpaste")
        process.arguments = []

        let outPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = Pipe()

        do {
            try process.run()
            let completed = await waitWithTimeout(process, seconds: 10)
            if !completed {
                process.terminate()
                return "Clipboard read timed out."
            }

            let data = outPipe.fileHandleForReading.readDataToEndOfFile()

            // Guard against binary clipboard content
            guard let text = String(data: data, encoding: .utf8) else {
                return "Clipboard contains non-text content (binary data)."
            }

            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                return "Clipboard is empty."
            }

            // Limit response length to avoid overwhelming TTS
            let preview = trimmed.prefix(500)
            let suffix = trimmed.count > 500 ? "… (\(trimmed.count) characters total)" : ""
            return "Clipboard contains: \(preview)\(suffix)"
        } catch {
            return "Couldn't read clipboard: \(error.localizedDescription)"
        }
    }

    // MARK: - Write clipboard via pbcopy

    private static func writeClipboard(text: String) async -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pbcopy")
        process.arguments = []

        let inPipe = Pipe()
        process.standardInput = inPipe
        process.standardError = Pipe()

        do {
            try process.run()

            if let data = text.data(using: .utf8) {
                inPipe.fileHandleForWriting.write(data)
            }
            inPipe.fileHandleForWriting.closeFile()

            let completed = await waitWithTimeout(process, seconds: 10)
            if !completed {
                process.terminate()
                return "Clipboard write timed out."
            }

            return process.terminationStatus == 0
                ? "Copied to clipboard."
                : "Couldn't write to clipboard."
        } catch {
            return "Couldn't write to clipboard: \(error.localizedDescription)"
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
