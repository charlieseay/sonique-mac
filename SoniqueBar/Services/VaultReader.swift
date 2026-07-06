import Foundation

/// Read access to the linked knowledge vault (Obsidian / Logseq / markdown).
struct VaultReader {

    /// Active vault root from connector config, linked example, or legacy path.
    static var vaultPath: String {
        if let configured = ConnectorRegistry.shared.config.knowledge?.obsidianConfig?.vaultPath {
            let expanded = (configured as NSString).expandingTildeInPath
            if FileManager.default.fileExists(atPath: expanded) {
                return expanded
            }
        }
        let linked = (NSString(string: "~/.sonique/vault")).expandingTildeInPath
        if FileManager.default.fileExists(atPath: linked) {
            return linked
        }
        let legacy = (NSString(string: "~/Library/Mobile Documents/iCloud~md~obsidian/Documents/SeaynicNet")).expandingTildeInPath
        if FileManager.default.fileExists(atPath: legacy) {
            return legacy
        }
        return linked
    }

    /// Read a Standards/ document
    static func readStandard(_ filename: String) -> String? {
        let path = "\(vaultPath)/Standards/\(filename)"
        return try? String(contentsOfFile: path, encoding: .utf8)
    }

    /// Read any vault file by relative path
    static func readVaultFile(_ relativePath: String) -> String? {
        let path = "\(vaultPath)/\(relativePath)"
        return try? String(contentsOfFile: path, encoding: .utf8)
    }

    /// List available Standards/ files
    static func listStandards() -> [String] {
        let standardsPath = "\(vaultPath)/Standards"
        guard let files = try? FileManager.default.contentsOfDirectory(atPath: standardsPath) else {
            return []
        }
        return files.filter { $0.hasSuffix(".md") }.sorted()
    }

    /// Get brief template
    static func getBriefTemplate() -> String {
        readStandard("Brief and Delivery Standard.md") ?? "Brief template not found"
    }
}

/// One-step knowledge-vault link (calls CAAL `/setup/vault`, falls back to local config).
enum VaultLinker {
    private static let caalSetupURL = URL(string: "http://127.0.0.1:8889/setup/vault")!

    struct LinkResult: Equatable {
        let path: String
        let kind: String
        let defaultFolder: String
        let noteCount: Int
        let message: String
    }

    /// Install/link the bundled example vault via CAAL, or copy from a known CAAL checkout.
    static func linkExample() async throws -> LinkResult {
        if let remote = try? await postSetup(body: ["use_example": true, "force": true]) {
            applyToRegistry(remote)
            return remote
        }
        return try linkLocalExample()
    }

    /// Link an existing vault folder.
    static func linkPath(_ path: String) async throws -> LinkResult {
        let expanded = (path as NSString).expandingTildeInPath
        if let remote = try? await postSetup(body: ["path": expanded]) {
            applyToRegistry(remote)
            return remote
        }
        return try linkLocalPath(expanded)
    }

    /// Current vault status (CAAL if up, else local).
    static func currentStatus() async -> LinkResult? {
        if let remote = try? await getSetup() {
            return remote
        }
        let path = VaultReader.vaultPath
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        let kind = ObsidianConnector.detectKind(at: path)
        let notes = countNotes(at: path)
        return LinkResult(
            path: path,
            kind: kind,
            defaultFolder: ObsidianConnector.defaultFolder(forKind: kind),
            noteCount: notes,
            message: "Vault at \(path)"
        )
    }

    // MARK: - CAAL API

    private static func postSetup(body: [String: Any]) async throws -> LinkResult {
        var request = URLRequest(url: caalSetupURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 8
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
        return try decodeResult(data)
    }

    private static func getSetup() async throws -> LinkResult {
        var request = URLRequest(url: caalSetupURL)
        request.timeoutInterval = 3
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
        return try decodeResult(data)
    }

    private static func decodeResult(_ data: Data) throws -> LinkResult {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              (json["success"] as? Bool) == true,
              let path = json["path"] as? String else {
            throw URLError(.cannotParseResponse)
        }
        return LinkResult(
            path: path,
            kind: json["kind"] as? String ?? "markdown",
            defaultFolder: json["default_folder"] as? String ?? "Ideas",
            noteCount: json["note_count"] as? Int ?? 0,
            message: json["message"] as? String ?? "Vault linked"
        )
    }

    // MARK: - Local fallback

    private static func linkLocalExample() throws -> LinkResult {
        let dest = (NSString(string: "~/.sonique/vault")).expandingTildeInPath
        let candidates = [
            NSString(string: "~/Projects/cael/example-vault").expandingTildeInPath,
            "/Users/charlieseay/Projects/cael/example-vault"
        ]
        guard let source = candidates.first(where: { FileManager.default.fileExists(atPath: $0) }) else {
            throw NSError(
                domain: "VaultLinker",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Example vault not found. Start CAAL or run: python -m caal.vault --example"]
            )
        }
        let fm = FileManager.default
        if fm.fileExists(atPath: dest) {
            try fm.removeItem(atPath: dest)
        }
        try fm.createDirectory(atPath: (dest as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try fm.copyItem(atPath: source, toPath: dest)
        return try linkLocalPath(dest)
    }

    private static func linkLocalPath(_ path: String) throws -> LinkResult {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue else {
            throw NSError(
                domain: "VaultLinker",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "Not a directory: \(path)"]
            )
        }
        let kind = ObsidianConnector.detectKind(at: path)
        let folder = ObsidianConnector.defaultFolder(forKind: kind)
        let folderURL = URL(fileURLWithPath: path).appendingPathComponent(folder)
        try? FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)
        let result = LinkResult(
            path: path,
            kind: kind,
            defaultFolder: folder,
            noteCount: countNotes(at: path),
            message: "Linked \(kind) vault at \(path)"
        )
        applyToRegistry(result)
        writeCAALSettings(result)
        return result
    }

    private static func applyToRegistry(_ result: LinkResult) {
        Task { @MainActor in
            var config = ConnectorRegistry.shared.config
            var knowledge = config.knowledge ?? KnowledgeConfig(provider: "vault", enabled: true, obsidianConfig: nil, notionConfig: nil)
            knowledge.provider = "vault"
            knowledge.enabled = true
            knowledge.obsidianConfig = ObsidianConfig(
                vaultPath: result.path,
                defaultFolder: result.defaultFolder,
                kind: result.kind
            )
            config.knowledge = knowledge
            ConnectorRegistry.shared.config = config
            // Re-register connector with new path
            ConnectorRegistry.shared.register(
                ObsidianConnector(config: knowledge.obsidianConfig!, enabled: true)
            )
        }
    }

    private static func writeCAALSettings(_ result: LinkResult) {
        let settingsPath = NSString(string: "~/Projects/cael/settings.json").expandingTildeInPath
        guard FileManager.default.fileExists(atPath: settingsPath),
              let data = try? Data(contentsOf: URL(fileURLWithPath: settingsPath)),
              var json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return
        }
        json["vault_path"] = result.path
        json["vault_kind"] = result.kind
        json["vault_default_folder"] = result.defaultFolder
        guard let out = try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys]) else {
            return
        }
        try? out.write(to: URL(fileURLWithPath: settingsPath))
    }

    private static func countNotes(at path: String) -> Int {
        guard let enumerator = FileManager.default.enumerator(atPath: path) else { return 0 }
        var count = 0
        while let item = enumerator.nextObject() as? String {
            if item.hasSuffix(".md") { count += 1 }
        }
        return count
    }
}
