import Foundation

/// Connector for Obsidian / Logseq / plain markdown vault operations.
/// Allows Sonique to create notes and search the knowledge vault.
struct ObsidianConnector: ActionConnector {
    let id = UUID()
    let name = "Knowledge Vault"
    let version = "1.1.0"
    let description = "Create and search Obsidian/Logseq vault notes"
    let category: ConnectorCategory = .knowledge
    var isEnabled: Bool

    private let vaultPath: String
    private let defaultFolder: String
    private let kind: String

    /// Initialize with config (preferred)
    init(config: ObsidianConfig, enabled: Bool = true) {
        self.vaultPath = (config.vaultPath as NSString).expandingTildeInPath
        self.defaultFolder = config.defaultFolder
        self.kind = config.kind ?? Self.detectKind(at: self.vaultPath)
        self.isEnabled = enabled
    }

    /// Fallback: linked example vault, then legacy personal path if present.
    init() {
        let linked = (NSString(string: "~/.sonique/vault")).expandingTildeInPath
        let legacy = (NSString(string: "~/Library/Mobile Documents/iCloud~md~obsidian/Documents/SeaynicNet")).expandingTildeInPath
        if FileManager.default.fileExists(atPath: linked) {
            self.vaultPath = linked
            self.defaultFolder = "Ideas"
            self.kind = Self.detectKind(at: linked)
        } else if FileManager.default.fileExists(atPath: legacy) {
            self.vaultPath = legacy
            self.defaultFolder = "Projects"
            self.kind = "obsidian"
        } else {
            self.vaultPath = linked
            self.defaultFolder = "Ideas"
            self.kind = "hybrid"
        }
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
        guard await healthCheck() else {
            throw ConnectorError.serviceUnavailable
        }
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
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: vaultPath, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    // MARK: - Detection

    static func detectKind(at path: String) -> String {
        let fm = FileManager.default
        let hasObsidian = fm.fileExists(atPath: (path as NSString).appendingPathComponent(".obsidian"))
        let hasLogseqDir = fm.fileExists(atPath: (path as NSString).appendingPathComponent("logseq"))
        let hasPages = fm.fileExists(atPath: (path as NSString).appendingPathComponent("pages"))
        let hasJournals = fm.fileExists(atPath: (path as NSString).appendingPathComponent("journals"))
        let hasLogseq = hasLogseqDir || (hasPages && hasJournals)
        if hasObsidian && hasLogseq { return "hybrid" }
        if hasObsidian { return "obsidian" }
        if hasLogseq { return "logseq" }
        return "markdown"
    }

    static func defaultFolder(forKind kind: String) -> String {
        kind == "logseq" ? "pages" : "Ideas"
    }

    // MARK: - Private Implementation

    private func createNote(_ params: [String: Any]) async throws -> ConnectorResult {
        guard let title = params["title"] as? String else {
            throw ConnectorError.missingParameter("title")
        }

        let content = params["content"] as? String ?? ""
        let folder = params["folder"] as? String ?? defaultFolder

        let filename = title.replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let folderPath = "\(vaultPath)/\(folder)"
        let notePath = "\(folderPath)/\(filename).md"

        try? FileManager.default.createDirectory(atPath: folderPath, withIntermediateDirectories: true)

        let now = ISO8601DateFormatter().string(from: Date()).prefix(10)
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
            data: ["path": notePath, "kind": kind]
        )
    }

    private func searchNotes(_ params: [String: Any]) async throws -> ConnectorResult {
        guard let query = params["query"] as? String else {
            throw ConnectorError.missingParameter("query")
        }

        let escaped = query.replacingOccurrences(of: "\"", with: "\\\"")
        let command = "grep -r -i -l \"\(escaped)\" \"\(vaultPath)\" --include=\"*.md\" | head -10"
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

        guard var existing = try? String(contentsOfFile: fullPath, encoding: .utf8) else {
            throw ConnectorError.invalidResponse("Could not read note")
        }

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
