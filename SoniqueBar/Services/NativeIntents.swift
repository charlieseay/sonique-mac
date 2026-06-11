import Foundation

/// Native-first intent layer. Handles common local facts and actions directly with
/// macOS native tools BEFORE any LLM is involved — instant, deterministic, free.
/// Returns nil if the request isn't a known native intent (→ falls through to the LLM).
enum NativeIntents {

    /// Try to answer/act on `text` natively. Returns the spoken response, or nil to defer to the LLM.
    static func handle(_ text: String) async -> String? {
        let lower = text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)

        // --- Time ---
        if lower.matchesAny(["what time", "what's the time", "whats the time", "current time", "the time is", "tell me the time"]) {
            return currentTime()
        }

        // --- Date / day ---
        if lower.matchesAny(["what's the date", "whats the date", "what is the date", "today's date", "todays date",
                             "what day is it", "what's today", "whats today", "what is today"]) {
            return currentDate()
        }

        // --- Day of week only ---
        if lower.matchesAny(["what day of the week", "which day is it"]) {
            return dayOfWeek()
        }

        // --- Open an app or URL: "open Safari", "open music" ---
        if lower.hasPrefix("open ") {
            let target = String(text.dropFirst(5)).trimmingCharacters(in: .whitespacesAndNewlines)
            if !target.isEmpty { return await openTarget(target) }
        }

        // --- Volume control (device control via osascript) ---
        if lower.matchesAny(["volume up", "turn up the volume", "louder"]) {
            return await setVolume(delta: +15)
        }
        if lower.matchesAny(["volume down", "turn down the volume", "quieter", "lower the volume"]) {
            return await setVolume(delta: -15)
        }
        if lower.matchesAny(["mute", "mute the volume", "silence"]) {
            _ = await shell("osascript -e 'set volume output muted true'")
            return "Muted."
        }

        return nil  // not a native intent → defer to LLM
    }

    // MARK: - Time / Date (native, no shell needed)

    private static func currentTime() -> String {
        let f = DateFormatter()
        f.dateFormat = "h:mm a"
        f.amSymbol = "AM"; f.pmSymbol = "PM"
        return "It's \(f.string(from: Date()))."
    }

    private static func currentDate() -> String {
        let f = DateFormatter()
        f.dateFormat = "EEEE, MMMM d"
        return "Today is \(f.string(from: Date()))."
    }

    private static func dayOfWeek() -> String {
        let f = DateFormatter()
        f.dateFormat = "EEEE"
        return "It's \(f.string(from: Date()))."
    }

    // MARK: - Actions (native macOS)

    private static func openTarget(_ target: String) async -> String {
        // URL?
        if target.contains(".") && !target.contains(" "),
           let _ = URL(string: target.hasPrefix("http") ? target : "https://\(target)") {
            let url = target.hasPrefix("http") ? target : "https://\(target)"
            _ = await shell("open '\(url.replacingOccurrences(of: "'", with: ""))'")
            return "Opening \(target)."
        }
        // App by name
        let app = target.replacingOccurrences(of: "'", with: "")
        let result = await shell("open -a '\(app)'")
        return result.exitCode == 0 ? "Opening \(app)." : "I couldn't find an app called \(app)."
    }

    private static func setVolume(delta: Int) async -> String {
        let getCmd = "osascript -e 'output volume of (get volume settings)'"
        let current = Int((await shell(getCmd)).stdout.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 50
        let next = max(0, min(100, current + delta))
        _ = await shell("osascript -e 'set volume output volume \(next)'")
        return "Volume \(delta > 0 ? "up" : "down") to \(next) percent."
    }

    // MARK: - Shell helper

    private static func shell(_ command: String) async -> (stdout: String, exitCode: Int32) {
        await withCheckedContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/zsh")
            process.arguments = ["-c", command]
            let out = Pipe()
            process.standardOutput = out
            process.standardError = Pipe()
            do {
                try process.run()
                process.waitUntilExit()
                let data = out.fileHandleForReading.readDataToEndOfFile()
                let str = String(data: data, encoding: .utf8) ?? ""
                continuation.resume(returning: (str, process.terminationStatus))
            } catch {
                continuation.resume(returning: ("", -1))
            }
        }
    }
}

private extension String {
    func matchesAny(_ phrases: [String]) -> Bool {
        phrases.contains { self.contains($0) }
    }
}
