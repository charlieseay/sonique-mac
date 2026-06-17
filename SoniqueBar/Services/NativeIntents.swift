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

        // --- Music info (what's playing) ---
        if lower.matchesAny(["what's playing", "whats playing", "what song", "current song", "what's this song", "who's the artist", "whos the artist"]) {
            return await getCurrentSong()
        }

        // --- Screenshot ---
        if lower.matchesAny(["take a screenshot", "screenshot", "capture screen", "screen capture"]) {
            return await takeScreenshot()
        }

        // --- Timer / countdown ---
        if lower.matchesAny(["set timer", "start timer", "timer for"]) {
            if let minutes = extractMinutes(from: text) {
                return await setTimer(minutes: minutes)
            }
        }
        if lower.matchesAny(["cancel timer", "stop timer", "clear timer"]) {
            return await cancelTimer()
        }

        // --- Focus mode / Do Not Disturb ---
        if lower.matchesAny(["focus mode on", "turn on focus", "enable focus", "start focus"]) {
            return await setFocusMode(enabled: true)
        }
        if lower.matchesAny(["focus mode off", "turn off focus", "disable focus", "stop focus"]) {
            return await setFocusMode(enabled: false)
        }
        if lower.matchesAny(["do not disturb on", "turn on do not disturb", "dnd on"]) {
            return await setDoNotDisturb(enabled: true)
        }
        if lower.matchesAny(["do not disturb off", "turn off do not disturb", "dnd off"]) {
            return await setDoNotDisturb(enabled: false)
        }

        // --- Screen brightness ---
        if lower.matchesAny(["brightness up", "brighter", "increase brightness"]) {
            return await adjustBrightness(direction: "up")
        }
        if lower.matchesAny(["brightness down", "dimmer", "decrease brightness", "dim screen"]) {
            return await adjustBrightness(direction: "down")
        }

        // --- Dark mode ---
        if lower.matchesAny(["dark mode on", "enable dark mode", "turn on dark mode"]) {
            return await setDarkMode(enabled: true)
        }
        if lower.matchesAny(["dark mode off", "disable dark mode", "turn off dark mode", "light mode"]) {
            return await setDarkMode(enabled: false)
        }

        // --- System control ---
        if lower.matchesAny(["lock screen", "lock my screen", "lock mac"]) {
            return await lockScreen()
        }
        if lower.matchesAny(["sleep", "put mac to sleep", "go to sleep"]) {
            return await sleepMac()
        }

        // --- Wi-Fi / Bluetooth ---
        if lower.matchesAny(["wifi on", "turn on wifi", "enable wifi"]) {
            return await setWiFi(enabled: true)
        }
        if lower.matchesAny(["wifi off", "turn off wifi", "disable wifi"]) {
            return await setWiFi(enabled: false)
        }
        if lower.matchesAny(["bluetooth on", "turn on bluetooth"]) {
            return await setBluetooth(enabled: true)
        }
        if lower.matchesAny(["bluetooth off", "turn off bluetooth"]) {
            return await setBluetooth(enabled: false)
        }

        // --- System info ---
        if lower.matchesAny(["disk space", "how much space", "storage", "free space"]) {
            return await getDiskSpace()
        }
        if lower.matchesAny(["cpu usage", "memory usage", "ram usage", "system stats"]) {
            return await getSystemStats()
        }

        // --- Note operations ---
        if lower.matchesAny(["read my last note", "last note", "recent note"]) {
            return await readLastNote()
        }
        if lower.matchesAny(["read today's notes", "read todays notes", "today's notes", "todays notes"]) {
            return await readTodaysNotes()
        }

        // --- Math calculations ---
        if let result = calculateMath(from: text) {
            return result
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
        // Map common names to Home Assistant entities
        // Home Assistant acts as HomeKit bridge and has REST API
        let entityMap: [String: String] = [
            "bedroom": "light.bedroom_3",
            "living room": "light.living_room",
            "kitchen": "light.kitchen",
            "office": "light.office"
        ]

        let nameLower = name.lowercased()
        guard let entity = entityMap[nameLower] else {
            return "I don't see a device named '\(name)'."
        }

        // Use Home Assistant REST API (silent, no UI)
        guard let tokenData = try? Data(contentsOf: URL(fileURLWithPath: "/Volumes/data/secrets/homepage_ha_token")),
              let token = String(data: tokenData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) else {
            return "Home control isn't configured."
        }

        let domain = entity.components(separatedBy: ".").first ?? "light"
        let service = action == "on" ? "turn_on" : "turn_off"
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
            return "Home control isn't responding."
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

    // MARK: - Music Info

    private static func getCurrentSong() async -> String {
        let script = """
        tell application "Music"
            if player state is playing then
                set trackName to name of current track
                set artistName to artist of current track
                return trackName & " by " & artistName
            else
                return "not playing"
            end if
        end tell
        """
        let result = await shell("osascript -e '\(script)'")
        if result.exitCode == 0 {
            return result.stdout.isEmpty || result.stdout.contains("not playing") ? "Nothing's playing right now." : result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return "Music isn't running"
    }

    // MARK: - Timer

    private static var timerTask: Task<Void, Never>?

    private static func setTimer(minutes: Int) async -> String {
        // Cancel existing timer
        timerTask?.cancel()

        timerTask = Task {
            try? await Task.sleep(nanoseconds: UInt64(minutes) * 60 * 1_000_000_000)
            if !Task.isCancelled {
                // Trigger notification/alert
                await shell("osascript -e 'display notification \"Timer finished\" with title \"Sonique Timer\"'")
                await shell("afplay /System/Library/Sounds/Glass.aiff")
            }
        }

        return "Timer set for \(minutes) minute\(minutes == 1 ? "" : "s")."
    }

    private static func cancelTimer() async -> String {
        if timerTask != nil {
            timerTask?.cancel()
            timerTask = nil
            return "Timer cancelled."
        }
        return "No active timer."
    }

    private static func extractMinutes(from text: String) -> Int? {
        let words = text.lowercased().components(separatedBy: .whitespaces)
        for (i, word) in words.enumerated() {
            if let num = Int(word), i + 1 < words.count {
                if words[i + 1].contains("minute") || words[i + 1].contains("min") {
                    return num
                }
            }
        }
        return nil
    }

    // MARK: - Focus Mode & Do Not Disturb

    private static func setFocusMode(enabled: Bool) async -> String {
        let action = enabled ? "on" : "off"
        let result = await shell("shortcuts run 'Set Focus \(action.capitalized)'")
        return result.exitCode == 0 ? "Focus mode \(action)." : "Couldn't change focus mode."
    }

    private static func setDoNotDisturb(enabled: Bool) async -> String {
        let action = enabled ? "on" : "off"
        let result = await shell("shortcuts run 'Set Do Not Disturb \(action.capitalized)'")
        return result.exitCode == 0 ? "Do Not Disturb \(action)." : "Couldn't change Do Not Disturb."
    }

    // MARK: - Screen Brightness

    private static func adjustBrightness(direction: String) async -> String {
        let delta = direction == "up" ? "+0.1" : "-0.1"
        let result = await shell("brightness \(delta)")
        return result.exitCode == 0 ? "Done." : "Couldn't adjust brightness."
    }

    // MARK: - Dark Mode

    private static func setDarkMode(enabled: Bool) async -> String {
        let mode = enabled ? "dark" : "light"
        let script = "tell application \"System Events\" to tell appearance preferences to set dark mode to \(enabled)"
        let result = await shell("osascript -e '\(script)'")
        return result.exitCode == 0 ? "Dark mode \(enabled ? "on" : "off")." : "Couldn't change appearance."
    }

    // MARK: - System Control

    private static func lockScreen() async -> String {
        let result = await shell("pmset displaysleepnow")
        return result.exitCode == 0 ? "Screen locked." : "Couldn't lock screen."
    }

    private static func sleepMac() async -> String {
        let result = await shell("pmset sleepnow")
        return result.exitCode == 0 ? "Going to sleep." : "Couldn't sleep Mac."
    }

    // MARK: - Wi-Fi & Bluetooth

    private static func setWiFi(enabled: Bool) async -> String {
        let action = enabled ? "on" : "off"
        let result = await shell("networksetup -setairportpower en0 \(action)")
        return result.exitCode == 0 ? "Wi-Fi \(action)." : "Couldn't change Wi-Fi."
    }

    private static func setBluetooth(enabled: Bool) async -> String {
        // Requires blueutil: brew install blueutil
        let action = enabled ? "--power 1" : "--power 0"
        let result = await shell("blueutil \(action)")
        return result.exitCode == 0 ? "Bluetooth \(enabled ? "on" : "off")." : "Couldn't change Bluetooth."
    }

    // MARK: - System Info

    private static func getDiskSpace() async -> String {
        let result = await shell("df -h / | tail -1 | awk '{print $4\" available out of \"$2}'")
        return result.exitCode == 0 && !result.stdout.isEmpty ? result.stdout.trimmingCharacters(in: .whitespacesAndNewlines) : "Couldn't get disk space."
    }

    private static func getSystemStats() async -> String {
        let result = await shell("top -l 1 | grep -E '^CPU|^PhysMem' | sed 's/CPU usage: //' | sed 's/PhysMem: /Memory: /'")
        return result.exitCode == 0 && !result.stdout.isEmpty ? result.stdout.trimmingCharacters(in: .whitespacesAndNewlines) : "Couldn't get system stats."
    }

    // MARK: - Note Operations

    private static func readLastNote() async -> String {
        let vaultPath = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Mobile Documents/iCloud~md~obsidian/Documents/SeaynicNet/Daily Notes")

        // Find most recent daily note
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd"

        for daysAgo in 0..<7 {
            let date = Calendar.current.date(byAdding: .day, value: -daysAgo, to: Date())!
            let fileName = "\(dateFormatter.string(from: date)).md"
            let filePath = vaultPath.appendingPathComponent(fileName)

            if FileManager.default.fileExists(atPath: filePath.path),
               let content = try? String(contentsOf: filePath) {
                // Extract last voice note section
                let sections = content.components(separatedBy: "## Voice Note")
                if let lastSection = sections.last, sections.count > 1 {
                    let noteContent = lastSection.components(separatedBy: "---").first ?? lastSection
                    return "Last note: \(noteContent.trimmingCharacters(in: .whitespacesAndNewlines).prefix(200))"
                }
            }
        }

        return "No recent notes found."
    }

    private static func readTodaysNotes() async -> String {
        let vaultPath = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Mobile Documents/iCloud~md~obsidian/Documents/SeaynicNet/Daily Notes")

        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd"
        let fileName = "\(dateFormatter.string(from: Date())).md"
        let filePath = vaultPath.appendingPathComponent(fileName)

        if FileManager.default.fileExists(atPath: filePath.path),
           let content = try? String(contentsOf: filePath) {
            // Extract all voice note sections
            let sections = content.components(separatedBy: "## Voice Note")
            if sections.count > 1 {
                let notes = sections.dropFirst().map { section in
                    section.components(separatedBy: "---").first?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                }
                return "Today's notes: \(notes.joined(separator: ". "))"
            }
        }

        return "No notes today yet."
    }

    // MARK: - Math Calculations

    private static func calculateMath(from text: String) -> String? {
        let lower = text.lowercased()

        // Simple arithmetic patterns
        if let result = evaluateSimpleArithmetic(from: lower) {
            return result
        }

        // Percentage calculations
        if lower.contains("percent") || lower.contains("%") {
            if let result = calculatePercentage(from: lower) {
                return result
            }
        }

        return nil
    }

    private static func evaluateSimpleArithmetic(from text: String) -> String? {
        // Pattern: "what's X plus/minus/times/divided by Y"
        let patterns: [(String, String)] = [
            ("plus", "+"), ("add", "+"),
            ("minus", "-"), ("subtract", "-"),
            ("times", "*"), ("multiplied by", "*"),
            ("divided by", "/")
        ]

        for (keyword, op) in patterns {
            if text.contains(keyword) {
                let components = text.components(separatedBy: keyword)
                if components.count == 2,
                   let num1 = extractNumber(from: components[0]),
                   let num2 = extractNumber(from: components[1]) {
                    let result: Double
                    switch op {
                    case "+": result = num1 + num2
                    case "-": result = num1 - num2
                    case "*": result = num1 * num2
                    case "/": result = num2 != 0 ? num1 / num2 : 0
                    default: return nil
                    }
                    return formatNumber(result)
                }
            }
        }

        return nil
    }

    private static func calculatePercentage(from text: String) -> String? {
        // Pattern: "what's X% of Y" or "X percent of Y"
        if text.contains(" of ") {
            let parts = text.components(separatedBy: " of ")
            if parts.count == 2,
               let percent = extractNumber(from: parts[0]),
               let base = extractNumber(from: parts[1]) {
                let result = (percent / 100.0) * base
                return formatNumber(result)
            }
        }
        return nil
    }

    private static func extractNumber(from text: String) -> Double? {
        let cleaned = text.components(separatedBy: .whitespaces).joined()
        let numbers = cleaned.components(separatedBy: .decimalDigits.inverted).joined()
        return Double(numbers)
    }

    private static func formatNumber(_ num: Double) -> String {
        if num.truncatingRemainder(dividingBy: 1) == 0 {
            return String(Int(num))
        } else {
            return String(format: "%.2f", num)
        }
    }
}

private extension String {
    func matchesAny(_ phrases: [String]) -> Bool {
        phrases.contains { self.contains($0) }
    }
}
