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

        // --- Weather ---
        if lower.matchesAny(["weather", "what's the weather", "whats the weather", "how's the weather", "hows the weather", "temperature", "what's it like outside"]) {
            return await getWeather()
        }

        // --- Music control (AppleScript to Music app) ---
        if lower.matchesAny(["play music", "pause music", "stop music", "next song", "skip", "previous song"]) {
            return await controlMusic(command: lower)
        }

        // --- Screenshot ---
        if lower.matchesAny(["take a screenshot", "screenshot", "capture screen", "screen capture"]) {
            return await takeScreenshot()
        }

        // --- HomeKit control via Shortcuts (silent, no Home.app UI) ---
        if lower.contains("bedroom light") || lower.contains("bedroom lights") {
            if lower.matchesAny(["turn on", "turn the", "switch on", " on", "light on"]) {
                return await controlHomeKitDevice(name: "Bedroom", action: "on")
            } else if lower.matchesAny(["turn off", "switch off", " off", "light off"]) {
                return await controlHomeKitDevice(name: "Bedroom", action: "off")
            }
        }

        // Generic HomeKit control - extract device name and action
        if lower.contains("turn on") || lower.contains("turn off") || lower.contains("switch on") || lower.contains("switch off") {
            if let (device, action) = extractHomeKitIntent(from: lower) {
                return await controlHomeKitDevice(name: device, action: action)
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

    // MARK: - Weather

    private static func getWeather() async -> String {
        // Use wttr.in for quick weather (no API key needed)
        let result = await shell("curl -s 'wttr.in/?format=%l:+%C+%t+%w'")
        if result.exitCode == 0 && !result.stdout.isEmpty {
            return result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return "Couldn't get weather"
    }

    // MARK: - Music Control

    private static func controlMusic(command: String) async -> String {
        let script: String
        if command.contains("play") {
            script = "tell application \"Music\" to play"
        } else if command.contains("pause") || command.contains("stop") {
            script = "tell application \"Music\" to pause"
        } else if command.contains("next") || command.contains("skip") {
            script = "tell application \"Music\" to next track"
        } else if command.contains("previous") {
            script = "tell application \"Music\" to previous track"
        } else {
            return "Music command not recognized"
        }

        let result = await shell("osascript -e '\(script)'")
        return result.exitCode == 0 ? "Done." : "Music isn't running"
    }

    // MARK: - Screenshot

    private static func takeScreenshot() async -> String {
        let timestamp = Int(Date().timeIntervalSince1970)
        let path = "/Users/charlieseay/Desktop/screenshot-\(timestamp).png"
        let result = await shell("screencapture -x '\(path)'")
        return result.exitCode == 0 ? "Screenshot saved to Desktop" : "Couldn't take screenshot"
    }

    // MARK: - HomeKit Control (via Shortcuts, silent - no Home.app opening)

    private static func controlHomeKitDevice(name: String, action: String) async -> String {
        // Use shortcuts command to control HomeKit devices silently
        // This runs in background - Home.app does NOT open
        let command = action == "on" ? "Turn on \(name)" : "Turn off \(name)"
        let result = await shell("shortcuts run '\(command)' 2>&1")

        if result.exitCode == 0 {
            return "Done."
        } else if result.stdout.contains("not found") || result.stdout.contains("doesn't exist") {
            return "I don't see a device named '\(name)' in HomeKit."
        } else {
            return "Couldn't control that device."
        }
    }

    private static func extractHomeKitIntent(from text: String) -> (device: String, action: String)? {
        // Pattern match common device names
        // Map to HomeKit accessory names (customize for your setup)
        let deviceMap: [String: String] = [
            "living room light": "Living Room",
            "kitchen light": "Kitchen",
            "office light": "Office",
            "desk lamp": "Desk"
        ]

        for (keyword, deviceName) in deviceMap {
            if text.contains(keyword) {
                let action = text.contains("turn on") || text.contains("switch on") ? "on" : "off"
                return (deviceName, action)
            }
        }

        return nil
    }
}

private extension String {
    func matchesAny(_ phrases: [String]) -> Bool {
        phrases.contains { self.contains($0) }
    }
}
