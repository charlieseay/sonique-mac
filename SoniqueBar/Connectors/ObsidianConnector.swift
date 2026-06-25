import Foundation

/// Connector for Obsidian vault operations
/// Allows Quinn to create notes and search the vault
struct ObsidianConnector: ActionConnector {
    let id = UUID()
    let name = "Obsidian"
    let version = "1.0.0"
    let description = "Create and search Obsidian vault notes"
    let category: ConnectorCategory = .knowledge
    var isEnabled: Bool

    private let vaultPath: String
    private let defaultFolder: String

    /// Initialize with config (preferred)
    init(config: ObsidianConfig, enabled: Bool = true) {
        self.vaultPath = (config.vaultPath as NSString).expandingTildeInPath
        self.defaultFolder = config.defaultFolder
        self.isEnabled = enabled
    }

    /// Initialize with legacy hardcoded values (fallback)
    init() {
        self.vaultPath = "/Users/charlieseay/Library/Mobile Documents/iCloud~md~obsidian/Documents/SeaynicNet"
        self.defaultFolder = "Projects"
        self.isEnabled = true
    }

    var capabilities: [ConnectorCapability] {
        [
            .init(
                name: "create_note",
                description: "Create a new note in the vault",
                parameters: [
                    .init(name: "title", type: .string, required: true, description: "Note title"),
                    .init(name: "content", type: .string, required: false, description: "Note content"),
                    .init(name: "folder", type: .string, required: false, defaultValue: nil, description: "Folder path")
                ],
                requiredAuth: .none,
                mutates: true
            ),
            .init(
                name: "search_notes",
                description: "Search for notes containing text",
                parameters: [
                    .init(name: "query", type: .string, required: true, description: "Search query")
                ],
                requiredAuth: .none,
                mutates: false
            ),
            .init(
                name: "append_to_note",
                description: "Append content to an existing note",
                parameters: [
                    .init(name: "path", type: .string, required: true, description: "Note path"),
                    .init(name: "content", type: .string, required: true, description: "Content to append")
                ],
                requiredAuth: .none,
                mutates: true
            )
        ]
    }

    // MARK: - Execution

    func execute(_ capability: String, parameters: [String: Any]) async throws -> ConnectorResult {
        switch capability {
        case "create_note":
            return try await createNote(parameters)
        case "search_notes":
            return try await searchNotes(parameters)
        case "append_to_note":
            return try await appendToNote(parameters)
        default:
            throw ConnectorError.unknownCapability(capability)
        }
    }

    func healthCheck() async -> Bool {
        // Check if vault path exists
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: vaultPath, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    // MARK: - Private Implementation

    private func createNote(_ params: [String: Any]) async throws -> ConnectorResult {
        guard let title = params["title"] as? String else {
            throw ConnectorError.missingParameter("title")
        }

        let content = params["content"] as? String ?? ""
        let folder = params["folder"] as? String ?? defaultFolder

        // Sanitize filename
        let filename = title.replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let folderPath = "\(vaultPath)/\(folder)"
        let notePath = "\(folderPath)/\(filename).md"

        // Create folder if it doesn't exist
        try? FileManager.default.createDirectory(atPath: folderPath, withIntermediateDirectories: true)

        // Create note with frontmatter
        let now = ISO8601DateFormatter().string(from: Date()).prefix(10) // YYYY-MM-DD
        let noteContent = """
        ---
        tags: [note]
        created: \(now)
        ---

        # \(title)

        \(content)
        """

        try noteContent.write(toFile: notePath, atomically: true, encoding: .utf8)

        return .success(
            message: "Created note '\(title)'",
            data: ["path": notePath]
        )
    }

    private func searchNotes(_ params: [String: Any]) async throws -> ConnectorResult {
        guard let query = params["query"] as? String else {
            throw ConnectorError.missingParameter("query")
        }

        // Use grep to search vault
        let command = "grep -r -i -l \"\(query)\" \"\(vaultPath)\" --include=\"*.md\" | head -10"
        let result = await shell(command)

        let matches = result.stdout
            .components(separatedBy: "\n")
            .filter { !$0.isEmpty }
            .map { $0.replacingOccurrences(of: "\(vaultPath)/", with: "") }

        let message = matches.isEmpty ? "No matches found" : "Found \(matches.count) note(s)"

        return .success(
            message: message,
            data: ["matches": matches]
        )
    }

    private func appendToNote(_ params: [String: Any]) async throws -> ConnectorResult {
        guard let path = params["path"] as? String,
              let content = params["content"] as? String else {
            throw ConnectorError.missingParameter("path or content")
        }

        let fullPath = path.hasPrefix("/") ? path : "\(vaultPath)/\(path)"

        guard FileManager.default.fileExists(atPath: fullPath) else {
            throw ConnectorError.invalidParameter("path", expected: "existing note", got: path)
        }

        // Read existing content
        guard var existing = try? String(contentsOfFile: fullPath, encoding: .utf8) else {
            throw ConnectorError.invalidResponse("Could not read note")
        }

        // Append new content
        existing += "\n\n\(content)"

        try existing.write(toFile: fullPath, atomically: true, encoding: .utf8)

        return .success(message: "Updated note")
    }

    // MARK: - Helper

    private func shell(_ command: String) async -> (stdout: String, stderr: String, exitCode: Int32) {
        let task = Process()
        task.launchPath = "/bin/zsh"
        task.arguments = ["-c", command]

        let outPipe = Pipe()
        let errPipe = Pipe()
        task.standardOutput = outPipe
        task.standardError = errPipe

        do {
            try task.run()
            task.waitUntilExit()

            let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
            let errData = errPipe.fileHandleForReading.readDataToEndOfFile()

            let stdout = String(data: outData, encoding: .utf8) ?? ""
            let stderr = String(data: errData, encoding: .utf8) ?? ""

            return (stdout, stderr, task.terminationStatus)
        } catch {
            return ("", error.localizedDescription, -1)
        }
    }
}
