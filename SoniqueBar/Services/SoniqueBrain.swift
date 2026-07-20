import Foundation

/// SoniqueBar side of the iCloud-backed brain. Reads AND WRITES the SHARED persona.
/// iOS reads the shared persona but only writes to mobile/.
/// SoniqueBar owns the shared persona and can evolve it based on conversations.
///
///   iCloud Drive/SoniqueProfiles/
///     shared/   IDENTITY.md, RULES.md, SOUL.md, assistant.json   (SoniqueBar owns)
///     Desktop/  lessons.jsonl, directives.md, conversations.jsonl (this device owns)
///     mobile/   lessons.jsonl, directives.md, conversations.jsonl (iOS owns)
@MainActor
final class SoniqueBrain {
    static let shared = SoniqueBrain()

    var quotaBytes: Int = 50 * 1024 * 1024   // 50 MB on Desktop
    private let device = "Desktop"
    private let fm = FileManager.default

    private let containerID = "iCloud.com.seayniclabs.sonique"
    private var cachedBase: URL?

    // Cache personality to avoid re-reading iCloud every request
    private var cachedPersonality: String?
    private var lastPersonalityLoad: Date?
    private let personalityCacheDuration: TimeInterval = 30.0  // Refresh every 30 seconds

    private init() {
        ensureStructure()
        // Resolve the shared ubiquity container OFF the main thread
        let id = containerID
        let fmRef = fm
        Task.detached(priority: .utility) {
            let resolved = fmRef.url(forUbiquityContainerIdentifier: id)?
                .appendingPathComponent("Documents/SoniqueProfiles")
            await MainActor.run {
                self.cachedBase = resolved
                self.ensureStructure()
            }
        }
    }

    private var localFallback: URL {
        fm.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/SoniqueBar/SoniqueProfiles")
    }

    private var base: URL { cachedBase ?? localFallback }
    private var sharedDir: URL { base.appendingPathComponent("shared") }
    private var deviceDir: URL { base.appendingPathComponent(device) }

    private func ensureStructure() {
        for dir in [sharedDir, deviceDir] {
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
    }

    // MARK: - Shared Persona (Read/Write)

    /// Full persona context: IDENTITY + RULES + assistant name + conversational guidelines
    /// Cached for performance - refreshes every 30 seconds to pick up iCloud changes
    func loadPersonaContext() -> String {
        // Check cache first
        if let cached = cachedPersonality,
           let lastLoad = lastPersonalityLoad,
           Date().timeIntervalSince(lastLoad) < personalityCacheDuration {
            return cached
        }

        // Cache miss or expired - reload from iCloud
        let identity = readText(sharedDir.appendingPathComponent("IDENTITY.md"))
        let rules = readText(sharedDir.appendingPathComponent("RULES.md"))
        let soul = readText(sharedDir.appendingPathComponent("SOUL.md"))
        let capabilities = readText(sharedDir.appendingPathComponent("CAPABILITIES.md"))
        let recentWork = readText(sharedDir.appendingPathComponent("RECENT_WORK.md"))

        var persona = ""

        // Load assistant name from iCloud-synced JSON
        let assistantFile = sharedDir.appendingPathComponent("assistant.json")
        if let data = try? Data(contentsOf: assistantFile),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let name = json["name"] as? String {
            persona += "Your name is \(name).\n\n"
        }

        if !identity.isEmpty { persona += identity + "\n\n" }
        if !rules.isEmpty { persona += rules + "\n\n" }
        if !soul.isEmpty { persona += "# Evolving Traits\n\(soul)\n\n" }
        if !capabilities.isEmpty { persona += capabilities + "\n\n" }
        if !recentWork.isEmpty { persona += recentWork + "\n\n" }

        // Add conversational tone constraints
        persona += """
        ## Voice Response Guidelines

        - Keep responses concise and conversational (2-3 sentences max unless detail is explicitly requested)
        - Don't provide detailed reports or verbose explanations unless asked
        - Answer questions directly without preambles
        - Use natural, spoken language - you're being heard, not read
        - If asked for detail, THEN provide it - otherwise stay brief

        """

        // Update cache
        cachedPersonality = persona
        lastPersonalityLoad = Date()

        return persona
    }

    /// Get assistant name from shared persona
    func getAssistantName() -> String {
        let assistantFile = sharedDir.appendingPathComponent("assistant.json")
        if let data = try? Data(contentsOf: assistantFile),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let name = json["name"] as? String {
            return name
        }
        return "Sonique"  // Default
    }

    /// Update assistant name in shared persona
    func setAssistantName(_ name: String) {
        let assistantFile = sharedDir.appendingPathComponent("assistant.json")
        let json: [String: Any] = ["name": name, "photo": NSNull()]
        guard let data = try? JSONSerialization.data(withJSONObject: json, options: .prettyPrinted),
              let jsonString = String(data: data, encoding: .utf8) else { return }

        writeText(jsonString, to: assistantFile)
    }

    /// Update IDENTITY.md (who she is, her role, her voice)
    func updateIdentity(_ markdown: String) {
        let identityFile = sharedDir.appendingPathComponent("IDENTITY.md")
        writeText(markdown, to: identityFile)
    }

    /// Update RULES.md (core behavioral rules)
    func updateRules(_ markdown: String) {
        let rulesFile = sharedDir.appendingPathComponent("RULES.md")
        writeText(markdown, to: rulesFile)
    }

    /// Update SOUL.md (evolving persona traits)
    func updateSoul(_ markdown: String) {
        let soulFile = sharedDir.appendingPathComponent("SOUL.md")
        writeText(markdown, to: soulFile)
    }

    /// Append to SOUL.md (record learned preferences/traits)
    func recordTrait(_ trait: String) {
        let soulFile = sharedDir.appendingPathComponent("SOUL.md")
        let existing = readText(soulFile)
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let entry = "\n- **\(timestamp)**: \(trait)"
        writeText(existing + entry, to: soulFile)
    }

    // MARK: - Desktop Device Memory (Read/Write)

    func recordExchange(user: String, assistant: String) {
        let entry: [String: Any] = [
            "user": user, "assistant": assistant,
            "ts": ISO8601DateFormatter().string(from: Date())
        ]
        appendJSONL(entry, to: deviceDir.appendingPathComponent("conversations.jsonl"))
        enforceQuota()
    }

    func recordLesson(_ text: String) {
        let entry: [String: Any] = ["lesson": text, "ts": ISO8601DateFormatter().string(from: Date())]
        appendJSONL(entry, to: deviceDir.appendingPathComponent("lessons.jsonl"))
        enforceQuota()
    }

    // MARK: - Preferences (iCloud-backed shared config)

    private var prefsURL: URL { sharedDir.appendingPathComponent("preferences.json") }

    struct Preferences: Codable {
        var authToken: String?  // Bearer token for CommandServer authentication
    }

    func loadPreferences() -> Preferences {
        let text = readText(prefsURL)
        guard !text.isEmpty,
              let data = text.data(using: .utf8),
              let prefs = try? JSONDecoder().decode(Preferences.self, from: data) else {
            return Preferences()
        }
        return prefs
    }

    func savePreferences(_ prefs: Preferences) {
        guard let data = try? JSONEncoder().encode(prefs),
              let json = String(data: data, encoding: .utf8) else { return }

        writeText(json, to: prefsURL)
    }

    // MARK: - Quota Management

    private func enforceQuota() {
        guard deviceFolderSize() > quotaBytes else { return }
        trimOldest(deviceDir.appendingPathComponent("conversations.jsonl"), keepFraction: 0.7)
        if deviceFolderSize() > quotaBytes {
            trimOldest(deviceDir.appendingPathComponent("lessons.jsonl"), keepFraction: 0.8)
        }
    }

    private func deviceFolderSize() -> Int {
        guard let files = try? fm.contentsOfDirectory(at: deviceDir, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        return files.reduce(0) { $0 + ((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
    }

    private func trimOldest(_ url: URL, keepFraction: Double) {
        guard let content = try? String(contentsOf: url, encoding: .utf8) else { return }
        let lines = content.split(separator: "\n", omittingEmptySubsequences: true)
        let keep = max(1, Int(Double(lines.count) * keepFraction))
        let trimmed = lines.suffix(keep).joined(separator: "\n") + "\n"
        writeText(trimmed, to: url)
    }

    // MARK: - File I/O Helpers

    private func readText(_ url: URL) -> String {
        // Trigger download for files another device wrote
        if (try? url.checkResourceIsReachable()) != true {
            try? fm.startDownloadingUbiquitousItem(at: url)
        }
        var result = ""
        var coordError: NSError?
        NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &coordError) { readURL in
            result = (try? String(contentsOf: readURL, encoding: .utf8)) ?? ""
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func writeText(_ text: String, to url: URL) {
        var coordError: NSError?
        NSFileCoordinator().coordinate(writingItemAt: url, options: [], error: &coordError) { writeURL in
            try? text.write(to: writeURL, atomically: true, encoding: .utf8)
        }
    }

    /// Coordinated append — safe when both devices touch the same file
    private func appendJSONL(_ obj: [String: Any], to url: URL) {
        guard let data = try? JSONSerialization.data(withJSONObject: obj),
              let line = String(data: data, encoding: .utf8) else { return }
        let entry = line + "\n"
        var coordError: NSError?
        NSFileCoordinator().coordinate(writingItemAt: url, options: [], error: &coordError) { writeURL in
            if let handle = try? FileHandle(forWritingTo: writeURL) {
                handle.seekToEndOfFile()
                if let d = entry.data(using: .utf8) { handle.write(d) }
                try? handle.close()
            } else {
                try? entry.write(to: writeURL, atomically: true, encoding: .utf8)
            }
        }
    }
}
// Updated Fri Jul 17 13:56:55 CDT 2026
