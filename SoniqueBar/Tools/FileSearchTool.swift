import Foundation

/// Wraps `/usr/bin/mdfind` (Spotlight) for file search.
enum FileSearchTool {

    static let toolName = "file_search"

    /// Execute the file search tool with a sanitized query.
    static func execute(input: [String: Any]) async -> String {
        guard let query = input["query"] as? String, !query.isEmpty else {
            return "Please provide a search query."
        }

        // Sanitize: strip shell metacharacters to prevent injection.
        // We pass each argument separately (no shell -c interpolation).
        let sanitized = query
            .replacingOccurrences(of: "\"", with: "")
            .replacingOccurrences(of: "'", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !sanitized.isEmpty else {
            return "Search query contained only invalid characters."
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/mdfind")
        process.arguments = ["-name", sanitized]

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        do {
            try process.run()
            let completed = await waitWithTimeout(process, seconds: 10)
            if !completed {
                process.terminate()
                return "File search timed out."
            }

            let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: outData, encoding: .utf8) ?? ""
            let results = output
                .components(separatedBy: "\n")
                .filter { !$0.isEmpty }

            if results.isEmpty {
                return "No files found matching '\(sanitized)'."
            }

            let top = results.prefix(10)
            let list = top.joined(separator: "\n")
            let suffix = results.count > 10 ? "\n…and \(results.count - 10) more." : ""
            return "Found \(results.count) file(s) matching '\(sanitized)':\n\(list)\(suffix)"
        } catch {
            return "File search failed: \(error.localizedDescription)"
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
