import Foundation

/// Tool for searching files using Spotlight (mdfind)
enum FileSearchTool {
    static let toolName = "file_search"

    static func execute(input: [String: Any]) async -> String {
        guard let query = input["query"] as? String else {
            return "ERROR: Missing 'query' parameter"
        }

        let process = Process()
        process.launchPath = "/usr/bin/mdfind"

        // Optional: limit results
        let limit = input["limit"] as? Int ?? 20

        // Optional: search in specific directory
        if let directory = input["directory"] as? String {
            process.arguments = ["-onlyin", directory, query]
        } else {
            process.arguments = [query]
        }

        let pipe = Pipe()
        process.standardOutput = pipe

        do {
            try process.run()
            process.waitUntilExit()

            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            guard let output = String(data: data, encoding: .utf8) else {
                return "ERROR: Could not decode output"
            }

            let lines = output.split(separator: "\n").map(String.init)
            let limited = lines.prefix(limit)

            if limited.isEmpty {
                return "No files found matching '\(query)'"
            }

            return limited.joined(separator: "\n")
        } catch {
            return "ERROR: \(error.localizedDescription)"
        }
    }
}
