import Foundation

/// The iCloud-backed "brain" — persona, lessons, and directives stored in
/// iCloud Drive/SoniqueProfiles so they grow, sync, and back up natively.
///
///   SoniqueProfiles/
///     shared/   IDENTITY.md, RULES.md, SOUL.md   (one persona, both devices read)
///     Desktop/  lessons.jsonl, directives.md, conversations.jsonl   (SoniqueBar owns)
///     mobile/   ...                                                  (Sonique iOS owns)
///
/// SoniqueBar manages the Desktop folder; Sonique iOS manages mobile. Shared persona is
/// read by both; SoniqueBar is the canonical writer for shared (it has the fuller context).
@MainActor
final class SoniqueBrain {
    static let shared = SoniqueBrain()

    /// Soft quota for this device's folder; oldest lessons/turns trimmed past it.
    var quotaBytes: Int = 50 * 1024 * 1024   // 50 MB per device

    private let device = "Desktop"
    private let fm = FileManager.default

    /// Shared iCloud container base — the SAME container the iOS app uses, so both devices
    /// read/write one brain. Container id: iCloud.com.seayniclabs.sonique.
    /// On macOS this resolves to ~/Library/Mobile Documents/iCloud~com~seayniclabs~sonique/Documents.
    private let containerID = "iCloud.com.seayniclabs.sonique"

    // Resolved once, OFF the main thread (Apple: url(forUbiquityContainerIdentifier:) is
    // potentially slow/blocking). Cached for all subsequent access.
    private var cachedBase: URL?
    private var localFallback: URL {
        fm.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/SoniqueBar/SoniqueProfiles")
    }

    private var base: URL { cachedBase ?? localFallback }
    private var sharedDir: URL { base.appendingPathComponent("shared") }
    private var deviceDir: URL { base.appendingPathComponent(device) }

    private init() {
        // Resolve the ubiquity container off-main, then ensure the folder structure.
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
        ensureStructure()  // ensure local fallback exists immediately
    }

    private func ensureStructure() {
        for dir in [sharedDir, deviceDir] {
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
    }

    // MARK: - Reads (persona context for the LLM)

    /// Compose the persona context: shared identity/rules/soul + this device's directives.
    func personaContext() -> String {
        let identity = readText(sharedDir.appendingPathComponent("IDENTITY.md"))
        let rules = readText(sharedDir.appendingPathComponent("RULES.md"))
        let soul = readText(sharedDir.appendingPathComponent("SOUL.md"))
        let directives = readText(deviceDir.appendingPathComponent("directives.md"))
        let lessons = recentLessons(limit: 10)

        var parts: [String] = []
        if !identity.isEmpty { parts.append("# Identity\n\(identity)") }
        if !soul.isEmpty { parts.append("# Persona\n\(soul)") }
        if !rules.isEmpty { parts.append("# Rules\n\(rules)") }
        if !directives.isEmpty { parts.append("# Device Directives (\(device))\n\(directives)") }
        if !lessons.isEmpty { parts.append("# Recent Lessons\n" + lessons.joined(separator: "\n")) }
        return parts.joined(separator: "\n\n")
    }

    // MARK: - Writes (grow the brain)

    /// Append a lesson learned to this device's lessons.jsonl.
    func recordLesson(_ text: String) {
        let entry: [String: Any] = ["lesson": text, "ts": ISO8601DateFormatter().string(from: Date())]
        appendJSONL(entry, to: deviceDir.appendingPathComponent("lessons.jsonl"))
        enforceQuota()
    }

    /// Append a conversation exchange to this device's conversations.jsonl.
    func recordExchange(user: String, assistant: String) {
        let entry: [String: Any] = [
            "user": user, "assistant": assistant,
            "ts": ISO8601DateFormatter().string(from: Date())
        ]
        appendJSONL(entry, to: deviceDir.appendingPathComponent("conversations.jsonl"))
        enforceQuota()
    }

    private func recentLessons(limit: Int) -> [String] {
        let url = deviceDir.appendingPathComponent("lessons.jsonl")
        guard let content = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        let lines = content.split(separator: "\n").suffix(limit)
        return lines.compactMap { line in
            guard let data = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let lesson = obj["lesson"] as? String else { return nil }
            return "- \(lesson)"
        }
    }

    // MARK: - Quota

    /// Trim oldest lines from conversations.jsonl (then lessons) until under quota.
    private func enforceQuota() {
        guard deviceFolderSize() > quotaBytes else { return }
        let convo = deviceDir.appendingPathComponent("conversations.jsonl")
        trimOldest(convo, keepFraction: 0.7)
        if deviceFolderSize() > quotaBytes {
            trimOldest(deviceDir.appendingPathComponent("lessons.jsonl"), keepFraction: 0.8)
        }
    }

    private func deviceFolderSize() -> Int {
        guard let files = try? fm.contentsOfDirectory(at: deviceDir, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        return files.reduce(0) { acc, url in
            acc + ((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
    }

    private func trimOldest(_ url: URL, keepFraction: Double) {
        guard let content = try? String(contentsOf: url, encoding: .utf8) else { return }
        let lines = content.split(separator: "\n", omittingEmptySubsequences: true)
        let keep = max(1, Int(Double(lines.count) * keepFraction))
        let trimmed = lines.suffix(keep).joined(separator: "\n") + "\n"
        try? trimmed.write(to: url, atomically: true, encoding: .utf8)
    }

    // MARK: - Helpers

    private func readText(_ url: URL) -> String {
        // Files authored on another device may not be downloaded yet — trigger it, then
        // read via a coordinated read so we get a consistent snapshot.
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

    /// Coordinated append — prevents corruption if both devices touch the same file.
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
