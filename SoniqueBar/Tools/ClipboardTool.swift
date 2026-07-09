import Foundation

/// Tool for clipboard operations (read/write)
enum ClipboardTool {
    static let toolName = "clipboard"

    static func execute(input: [String: Any]) async -> String {
        let action = input["action"] as? String ?? "get"

        if action == "set" {
            guard let text = input["text"] as? String else {
                return "ERROR: 'text' parameter required for set action"
            }

            let process = Process()
            process.launchPath = "/usr/bin/pbcopy"

            let pipe = Pipe()
            process.standardInput = pipe

            do {
                try process.run()
                pipe.fileHandleForWriting.write(text.data(using: .utf8)!)
                try pipe.fileHandleForWriting.close()
                process.waitUntilExit()

                if process.terminationStatus == 0 {
                    return "OK: Clipboard set to '\(text.prefix(50))...'"
                } else {
                    return "ERROR: pbcopy failed"
                }
            } catch {
                return "ERROR: \(error.localizedDescription)"
            }

        } else if action == "get" {
            let process = Process()
            process.launchPath = "/usr/bin/pbpaste"

            let pipe = Pipe()
            process.standardOutput = pipe

            do {
                try process.run()
                process.waitUntilExit()

                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                if let output = String(data: data, encoding: .utf8) {
                    return output.isEmpty ? "(clipboard empty)" : output
                } else {
                    return "ERROR: Could not read clipboard"
                }
            } catch {
                return "ERROR: \(error.localizedDescription)"
            }

        } else {
            return "ERROR: Unknown action '\(action)'. Use: get, set"
        }
    }
}
