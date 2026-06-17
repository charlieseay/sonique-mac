import Foundation
import EventKit

/// Native-first intent layer. Handles common local facts and actions directly with
/// macOS native tools BEFORE any LLM is involved — instant, deterministic, free.
/// Returns nil if the request isn't a known native intent (→ falls through to the LLM).
enum NativeIntents {

    /// Try to answer/act on `text` natively. Returns the spoken response, or nil to defer to the LLM.
    static func handle(_ text: String, deviceBattery: (percent: Int, isCharging: Bool)? = nil) async -> String? {
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

        // --- Battery: Mac (check Mac patterns FIRST before generic battery) ---
        if lower.matchesAny(["mac battery", "mac mini battery", "computer battery", "laptop battery"]) {
            return await macBattery()
        }

        // --- Battery: device (iOS) ---
        if lower.matchesAny(["battery", "what's my battery", "whats my battery", "battery level",
                             "sonique battery", "device battery", "phone battery", "ipad battery"]) {
            if let battery = deviceBattery {
                let chargingText = battery.isCharging ? ", and it's charging" : ""
                return "Battery is at \(battery.percent) percent\(chargingText)."
            }
            // Fallback if no device info
            return "I can't read the device battery right now."
        }

        // --- Calendar: today's events ---
        if lower.matchesAny(["what's on my calendar", "whats on my calendar", "my calendar", "calendar today",
                             "what's on the calendar", "whats on the calendar", "today's calendar", "todays calendar",
                             "my schedule", "today's schedule", "todays schedule", "what do i have today"]) {
            return await todaysCalendar()
        }

        // --- Reminders: show all incomplete ---
        if lower.matchesAny(["my reminders", "show reminders", "what are my reminders", "reminder list",
                             "what do i need to do", "my tasks", "task list"]) {
            return await showReminders()
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

        // --- Home Assistant light control (direct REST API) ---
        if lower.contains("bedroom light") || lower.contains("bedroom lights") {
            if lower.matchesAny(["turn on", "turn the", "switch on"]) {
                return await homeAssistantControl(entity: "light.bedroom_3", service: "turn_on")
            } else if lower.matchesAny(["turn off", "switch off"]) {
                return await homeAssistantControl(entity: "light.bedroom_3", service: "turn_off")
            }
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

    private static func macBattery() async -> String {
        // Check if this Mac has a battery
        let hasBattery = await shell("pmset -g batt | grep -c 'InternalBattery'")
        if hasBattery.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == "0" {
            return "This Mac doesn't have a battery."
        }

        // Get battery percentage
        let result = await shell("pmset -g batt | grep -Eo '\\d+%' | head -1")
        let percent = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)

        // Check if charging
        let chargingCheck = await shell("pmset -g batt | grep -c 'AC Power'")
        let isCharging = chargingCheck.stdout.trimmingCharacters(in: .whitespacesAndNewlines) != "0"

        let chargingText = isCharging ? ", and it's charging" : ""
        return "Mac battery is at \(percent)\(chargingText)."
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

    // MARK: - Calendar & Reminders (native EventKit - no OAuth needed)

    private static func todaysCalendar() async -> String {
        let store = EKEventStore()

        // Request access if needed
        let granted = await withCheckedContinuation { continuation in
            store.requestFullAccessToEvents { granted, error in
                continuation.resume(returning: granted)
            }
        }

        guard granted else {
            return "I need Calendar permission. Go to System Settings → Privacy & Security → Calendar and enable SoniqueBar."
        }

        // Get today's events
        let calendar = Calendar.current
        let startOfDay = calendar.startOfDay(for: Date())
        let endOfDay = calendar.date(byAdding: .day, value: 1, to: startOfDay)!

        let predicate = store.predicateForEvents(withStart: startOfDay, end: endOfDay, calendars: nil)
        let events = store.events(matching: predicate)

        if events.isEmpty {
            return "You have no events scheduled for today."
        }

        let formatter = DateFormatter()
        formatter.timeStyle = .short

        var summary = events.count == 1 ? "You have 1 event today: " : "You have \(events.count) events today: "
        let eventList = events.map { event in
            let timeStr = event.isAllDay ? "all day" : formatter.string(from: event.startDate)
            return "\(event.title ?? "Untitled") at \(timeStr)"
        }.joined(separator: ", ")

        return summary + eventList + "."
    }

    private static func showReminders() async -> String {
        let store = EKEventStore()

        // Request access if needed
        let granted = await withCheckedContinuation { continuation in
            store.requestFullAccessToReminders { granted, error in
                continuation.resume(returning: granted)
            }
        }

        guard granted else {
            return "I need Reminders permission. Go to System Settings → Privacy & Security → Reminders and enable SoniqueBar."
        }

        // Get all incomplete reminders
        let predicate = store.predicateForIncompleteReminders(withDueDateStarting: nil, ending: nil, calendars: nil)

        return await withCheckedContinuation { continuation in
            store.fetchReminders(matching: predicate) { reminders in
                guard let reminders = reminders, !reminders.isEmpty else {
                    continuation.resume(returning: "You have no reminders.")
                    return
                }

                let count = reminders.count

                if count == 1 {
                    continuation.resume(returning: "You have 1 reminder: \(reminders[0].title ?? "Untitled").")
                } else if count <= 5 {
                    let list = reminders.map { $0.title ?? "Untitled" }.joined(separator: ", ")
                    continuation.resume(returning: "You have \(count) reminders: \(list).")
                } else {
                    // Many reminders - ask what they want
                    continuation.resume(returning: "You have \(count) reminders. Want all of them, just today's, or something specific?")
                }
            }
        }
    }

    // MARK: - Home Assistant (direct REST API)

    private static func homeAssistantControl(entity: String, service: String) async -> String {
        guard let tokenData = try? Data(contentsOf: URL(fileURLWithPath: "/Volumes/data/secrets/ha_token")),
              let token = String(data: tokenData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) else {
            return "Home Assistant isn't configured."
        }

        let domain = entity.components(separatedBy: ".").first ?? "light"
        let url = URL(string: "http://homeassistant.local:8123/api/services/\(domain)/\(service)")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body = ["entity_id": entity]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 {
                return "Done."
            } else {
                return "Couldn't control that device."
            }
        } catch {
            return "Home Assistant isn't responding."
        }
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
