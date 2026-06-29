import Foundation
import EventKit

/// Native-first intent layer. Handles common local facts and actions directly with
/// macOS native tools BEFORE any LLM is involved — instant, deterministic, free.
/// Returns nil if the request isn't a known native intent (→ falls through to the LLM).
enum NativeIntents {

    /// Try to answer/act on `text` natively. Returns the spoken response, or nil to defer to the LLM.
    static func handle(_ text: String, deviceBattery: (percent: Int, isCharging: Bool)? = nil) async -> String? {
        do {
            // Add a global 10-second timeout as a safety net for all native intent handling.
            return try await withTimeout(seconds: 10.0, label: "handle(_:deviceBattery:)") {
                // By wrapping the entire logic in a Task, we ensure that even synchronous,
                // thread-blocking operations within this block can be timed out. This prevents
                // stalls if a string operation or another synchronous call hangs unexpectedly.
                return await Task { () -> String? in
                    // Guard against excessively long input that could cause performance issues.
                    guard text.count < 2048 else {
                        return "That command is too long for me to process."
                    }

                    let lower = text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)

                    // --- Time ---
                    if lower.matchesAny(["what time", "what's the time", "whats the time", "current time", "the time is", "tell me the time"]) {
                        return await currentTime()
                    }

                    // --- Date / day ---
                    if lower.matchesAny(["what's the date", "whats the date", "what is the date", "today's date", "todays date",
                                         "what day is it", "what's today", "whats today", "what is today"]) {
                        return await currentDate()
                    }

                    // --- Day of week only ---
                    if lower.matchesAny(["what day of the week", "which day is it"]) {
                        return await dayOfWeek()
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

                    // --- Reminders: today's ---
                    if lower.matchesAny(["today's reminders", "todays reminders", "what's due today", "whats due today"]) {
                        return await showReminders(forToday: true)
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
                        return await setMute(enabled: true)
                    }
                    if lower.matchesAny(["unmute", "un-mute"]) {
                        return await setMute(enabled: false)
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
                        // Wrap minute extraction in a short timeout as a safeguard against
                        // potential stalls from complex string processing on unusual input.
                        let minutes = try? await withTimeout(seconds: 1.0, label: "extractMinutes") {
                            await Task { extractMinutes(from: text) }.value
                        }

                        if let minutes = minutes {
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
                    if let result = await calculateMath(from: text) {
                        return result
                    }

                    // --- HomeKit control via Home Assistant ---
                    let onTriggers = ["turn on", "turn the", "switch on", "light on"]
                    let offTriggers = ["turn off", "switch off", "light off"]

                    if lower.matchesAny(onTriggers) || lower.matchesAny(offTriggers) {
                        // Wrap the device extraction in a short timeout as a safeguard against
                        // potential stalls from complex string processing on unusual input.
                        let device = try? await withTimeout(seconds: 1.0, label: "extractHomeKitDevice") {
                            await Task { extractHomeKitDevice(from: lower) }.value
                        }

                        if let device = device {
                            // It's important to check for 'on' triggers first.
                            // The logic assumes if it's not an 'on' trigger, it must be an 'off' trigger,
                            // which is safe because the outer 'if' checks for both.
                            let action = lower.matchesAny(onTriggers) ? "on" : "off"
                            return await controlHomeKitDevice(name: device, action: action)
                        }
                    }

                    // --- Small talk (instant responses, zero LLM) ---
                    // Greetings
                    if lower.matchesAny(["hey", "hello", "hi", "hey sonique", "hey quinn", "are you there", "you there"]) {
                        return ["I'm here. What do you need?", "Hey! What's up?", "I'm listening."].randomElement() ?? "I'm here."
                    }

                    // How are you
                    if lower.matchesAny(["how are you", "how are you doing", "how's it going", "hows it going", "how are things"]) {
                        return ["Running smoothly. You?", "All good here. What do you need?", "I'm good, thanks for asking."].randomElement() ?? "All good."
                    }

                    // Thanks / appreciation
                    if lower.matchesAny(["thanks", "thank you", "thanks sonique", "thank you sonique", "appreciate it", "thanks quinn", "thank you quinn"]) {
                        return ["Happy to help.", "Got it.", "You got it."].randomElement() ?? "Got it."
                    }

                    // Busy / working on something
                    if lower.matchesAny(["are you busy", "you busy", "are you working", "busy right now", "working on something"]) {
                        return ["Just standing by for your commands.", "Ready when you are.", "Not at all, what do you need?"].randomElement() ?? "Always ready for you."
                    }

                    // Acknowledge affirmative
                    if ["yes", "yep", "yeah", "okay", "ok", "got it"].contains(lower) {
                        return "Got it."
                    }

                    // Acknowledge negative
                    if ["no", "nope", "never mind", "cancel", "skip"].contains(lower) {
                        return "Understood."
                    }

                    // Conversational acknowledgments
                    if lower.matchesAny(["i know", "that's right", "thats right", "exactly", "for sure", "definitely"]) {
                        return "Yeah."
                    }

                    // Casual follow-ups and agreements
                    if lower.matchesAny(["sounds good", "sounds great", "perfect", "cool", "awesome", "got it", "understood"]) {
                        return "Great."
                    }

                    // Simple clarifications
                    if ["what", "what is it", "what's this", "whats this"].contains(lower) {
                        return "Need more context. What are you asking about?"
                    }

                    if ["why", "why's that", "whys that"].contains(lower) {
                        return "Can you give me more details?"
                    }

                    if lower.matchesAny(["tell me more", "go on", "continue", "keep going"]) {
                        return "I'm listening."
                    }

                    // Acknowledgments of understanding
                    if lower.matchesAny(["sure", "alright", "fine", "ok then", "will do"]) {
                        return "Got it."
                    }

                    // Expressions of agreement (stronger)
                    if lower.matchesAny(["sounds right", "makes sense", "that makes sense", "of course", "naturally"]) {
                        return "Yeah."
                    }

                    // Light negations
                    if lower.matchesAny(["not really", "not quite", "not exactly", "not necessarily"]) {
                        return "Understood."
                    }

                    // Casual inquiries about help
                    if lower.matchesAny(["can you help", "can you assist", "do you mind", "would you"]) {
                        return "Of course. What do you need?"
                    }

                    // Simple time-related small talk
                    if lower.matchesAny(["in a bit", "in a minute", "soon", "shortly", "in a sec"]) {
                        return "Got it, I'll wait."
                    }

                    // Expressions of urgency or importance
                    if lower.matchesAny(["it's important", "its important", "it's urgent", "its urgent", "asap", "right now"]) {
                        return "I'm ready. What do you need?"
                    }

                    // Casual acknowledgments
                    if lower.matchesAny(["noted", "got that", "copy that", "roger that"]) {
                        return "Got it."
                    }

                    return nil  // not a native intent → defer to LLM
                }.value
            }
        } catch let error as TimeoutError {
            return error.localizedDescription
        } catch {
            return "An unexpected error occurred while handling the command: \(error.localizedDescription)."
        }
    }

    // MARK: - Time / Date (native, no shell needed)

    private static func currentTime() async -> String {
        do {
            return try await withTimeout(seconds: 1.0) {
                // Wrap sync work in a Task to make it cancellable
                await Task {
                    let f = DateFormatter()
                    f.dateFormat = "h:mm a"
                    f.amSymbol = "AM"; f.pmSymbol = "PM"
                    return "It's \(f.string(from: Date()))."
                }.value
            }
        } catch let error as TimeoutError {
            return error.localizedDescription
        } catch {
            return "I couldn't get the current time right now."
        }
    }

    private static func currentDate() async -> String {
        do {
            return try await withTimeout(seconds: 1.0) {
                await Task {
                    let f = DateFormatter()
                    f.dateFormat = "EEEE, MMMM d"
                    return "Today is \(f.string(from: Date()))."
                }.value
            }
        } catch let error as TimeoutError {
            return error.localizedDescription
        } catch {
            return "I couldn't get the current date right now."
        }
    }

    private static func dayOfWeek() async -> String {
        do {
            return try await withTimeout(seconds: 1.0) {
                await Task {
                    let f = DateFormatter()
                    f.dateFormat = "EEEE"
                    return "It's \(f.string(from: Date()))."
                }.value
            }
        } catch let error as TimeoutError {
            return error.localizedDescription
        } catch {
            return "I couldn't get the day of the week right now."
        }
    }

    private static func macBattery() async -> String {
        do {
            return try await withTimeout(seconds: 5.0) {
                // Use a single call to pmset for efficiency and to avoid timeout stacking
                let result = await shell("pmset -g batt", timeout: 4.0)
                if result.exitCode == 124 { throw TimeoutError.timedOut(label: #function) }

                // Wrap synchronous string processing in a Task to make it fully cancellable.
                return await Task {
                    let output = result.stdout

                    // Check if this Mac has a battery
                    if !output.contains("InternalBattery") {
                        return "This Mac doesn't have a battery."
                    }

                    // Extract percentage
                    let percent: String
                    if let range = output.range(of: "\\d+%", options: .regularExpression) {
                        percent = String(output[range])
                    } else {
                        return "Couldn't determine Mac battery percentage."
                    }

                    // Check if charging
                    let isCharging = output.contains("AC Power") || output.contains("charging")
                    let chargingText = isCharging ? ", and it's charging" : ""

                    return "Mac battery is at \(percent)\(chargingText)."
                }.value
            }
        } catch let error as TimeoutError {
            return error.localizedDescription
        } catch {
            return "Couldn't get Mac battery status due to an error."
        }
    }

    // MARK: - Actions (native macOS)

    private static func openTarget(_ target: String) async -> String {
        do {
            return try await withTimeout(seconds: 5.0) {
                // The logic here involves synchronous string processing and a potentially
                // blocking URL initializer. We wrap the entire block in a Task to make it
                // fully cancellable by the outer timeout.
                return await Task {
                    // URL?
                    if target.contains(".") && !target.contains(" ") {
                        let urlString = target.hasPrefix("http") ? target : "https://\(target)"
                        // URL init can stall, so it remains inside this cancellable Task.
                        if URL(string: urlString) != nil {
                            let result = await shell("open '\(urlString.replacingOccurrences(of: "'", with: ""))'", timeout: 4.5)
                            if result.exitCode == 124 { throw TimeoutError.timedOut(label: #function) }
                            return "Opening \(target)."
                        }
                    }
                    // App by name
                    let app = target.replacingOccurrences(of: "'", with: "")
                    let result = await shell("open -a '\(app)'", timeout: 4.5)
                    if result.exitCode == 124 { throw TimeoutError.timedOut(label: #function) }
                    return result.exitCode == 0 ? "Opening \(app)." : "I couldn't find an app called \(app)."
                }.value
            }
        } catch let error as TimeoutError {
            return error.localizedDescription
        } catch {
            return "Couldn't open \(target) due to an error."
        }
    }

    private static func setVolume(delta: Int) async -> String {
        do {
            return try await withTimeout(seconds: 5.0) {
                // Wrap the logic in a Task to make synchronous processing cancellable.
                return await Task {
                    let getCmd = "osascript -e 'output volume of (get volume settings)'"
                    let getResult = await shell(getCmd, timeout: 2.0)
                    if getResult.exitCode == 124 { throw TimeoutError.timedOut(label: #function) }
                    let current = Int(getResult.stdout.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 50
                    let next = max(0, min(100, current + delta))
                    let setResult = await shell("osascript -e 'set volume output volume \(next)'", timeout: 2.0)
                    if setResult.exitCode == 124 { throw TimeoutError.timedOut(label: #function) }
                    return "Volume \(delta > 0 ? "up" : "down") to \(next) percent."
                }.value
            }
        } catch let error as TimeoutError {
            return error.localizedDescription
        } catch {
            return "Couldn't set the volume due to an error."
        }
    }

    private static func setMute(enabled: Bool) async -> String {
        do {
            return try await withTimeout(seconds: 3.0) {
                let result = await shell("osascript -e 'set volume output muted \(enabled)'", timeout: 2.0)
                if result.exitCode == 124 { throw TimeoutError.timedOut(label: #function) }
                return enabled ? "Muted." : "Unmuted."
            }
        } catch let error as TimeoutError {
            return error.localizedDescription
        } catch {
            return "Couldn't change mute status due to an error."
        }
    }

    // MARK: - Calendar & Reminders (native EventKit - no OAuth needed)

    private enum EventKitError: Error, LocalizedError {
        case initializationFailed
        case fetchFailed(String)
        var errorDescription: String? {
            switch self {
            case .initializationFailed: return "The calendar or reminders service failed to initialize. It might be unresponsive."
            case .fetchFailed(let type): return "Failed to fetch \(type)."
            }
        }
    }

    private static func todaysCalendar() async -> String {
        guard #available(macOS 14.0, *) else {
            return "Calendar access requires macOS 14 or later."
        }

        do {
            // Pre-flight check for permissions to avoid stalling on a system prompt.
            // This sync call is wrapped in a timeout in case the backing service is hung.
            let authStatus = try await withTimeout(seconds: 2.0) {
                await Task { EKEventStore.authorizationStatus(for: .event) }.value
            }

            switch authStatus {
            case .notDetermined:
                // Trigger the prompt asynchronously and return immediately to avoid a stall.
                // The request itself is wrapped in a timeout to prevent the detached task from hanging.
                Task.detached {
                    _ = try? await withTimeout(seconds: 60.0) { // Long timeout for user interaction
                        try await Task {
                            _ = try await EKEventStore().requestFullAccessToEvents()
                        }.value
                    }
                }
                return "I need permission to access your calendar. I've triggered the system prompt. Please approve it, then try your command again."
            case .restricted, .denied:
                return "I don't have Calendar permission. Go to System Settings → Privacy & Security → Calendar and enable SoniqueBar."
            case .fullAccess:
                break // Permission granted, proceed.
            @unknown default:
                return "An unknown calendar permission error occurred."
            }

            return try await withTimeout(seconds: 6.0, label: #function) {
                // The synchronous EKEventStore() init can hang. We run the whole operation
                // inside a cancellable Task to allow the timeout to interrupt it.
                return try await Task {
                    let store: EKEventStore
                    do {
                        // Give the initializer its own, shorter timeout to fail faster.
                        store = try await withTimeout(seconds: 2.0) {
                            await Task { EKEventStore() }.value
                        }
                    } catch {
                        throw EventKitError.initializationFailed
                    }

                    let calendar = Calendar.current
                    let startOfDay = calendar.startOfDay(for: Date())
                    let endOfDay = calendar.date(byAdding: .day, value: 1, to: startOfDay)!

                    // This synchronous call can sometimes stall if the calendar service is busy.
                    // Give it its own timeout for faster failure and clearer error reporting.
                    let predicate = try await withTimeout(seconds: 1.0, label: "todaysCalendar.predicate") {
                        await Task {
                            store.predicateForEvents(withStart: startOfDay, end: endOfDay, calendars: nil)
                        }.value
                    }

                    // Using the modern async API, with its own timeout as it can stall.
                    let events = try await withTimeout(seconds: 2.5, label: "todaysCalendar.fetch") {
                        try await Task {
                            try await store.events(matching: predicate)
                        }.value
                    }

                    if events.isEmpty {
                        return "You have no events scheduled for today."
                    }

                    // Wrap potentially slow string processing in its own timeout as a safeguard.
                    let summaryText = try await withTimeout(seconds: 1.0, label: "todaysCalendar.format") {
                        await Task {
                            let formatter = DateFormatter()
                            formatter.timeStyle = .short

                            // Handle large number of events by summarizing to prevent stalls on string processing
                            if events.count > 7, let firstEvent = events.first {
                                let timeStr = firstEvent.isAllDay ? "all day" : formatter.string(from: firstEvent.startDate)
                                return "You have \(events.count) events today, starting with \(firstEvent.title ?? "Untitled") at \(timeStr)."
                            }

                            var summary = events.count == 1 ? "You have 1 event today: " : "You have \(events.count) events today: "
                            let eventList = events.map { event in
                                let timeStr = event.isAllDay ? "all day" : formatter.string(from: event.startDate)
                                return "\(event.title ?? "Untitled") at \(timeStr)"
                            }.joined(separator: ", ")

                            return summary + eventList + "."
                        }.value
                    }
                    return summaryText
                }.value
            }
        } catch let error as TimeoutError {
            return error.localizedDescription
        } catch let error as EventKitError {
            return error.localizedDescription
        } catch {
            return "Couldn't get calendar access: \(error.localizedDescription)."
        }
    }

    private static func showReminders(forToday: Bool = false) async -> String {
        guard #available(macOS 14.0, *) else {
            return "Reminders access requires macOS 14 or later."
        }

        do {
            // Pre-flight check for permissions to avoid stalling on a system prompt.
            // This sync call is wrapped in a timeout in case the backing service is hung.
            let authStatus = try await withTimeout(seconds: 2.0) {
                await Task { EKEventStore.authorizationStatus(for: .reminder) }.value
            }

            switch authStatus {
            case .notDetermined:
                // Trigger the prompt asynchronously and return immediately to avoid a stall.
                // The request itself is wrapped in a timeout to prevent the detached task from hanging.
                Task.detached {
                    _ = try? await withTimeout(seconds: 60.0) { // Long timeout for user interaction
                        try await Task {
                            _ = try await EKEventStore().requestFullAccessToReminders()
                        }.value
                    }
                }
                return "I need permission to access your reminders. I've triggered the system prompt. Please approve it, then try your command again."
            case .restricted, .denied:
                return "I need Reminders permission. Go to System Settings → Privacy & Security → Reminders and enable SoniqueBar."
            case .fullAccess:
                break // Permission granted, proceed.
            @unknown default:
                return "An unknown reminders permission error occurred."
            }

            return try await withTimeout(seconds: 8.0, label: #function) {
                // The synchronous EKEventStore() init can hang. We run the whole operation
                // inside a cancellable Task to allow the timeout to interrupt it.
                return try await Task {
                    let store: EKEventStore
                    do {
                        // Give the initializer its own, shorter timeout to fail faster.
                        store = try await withTimeout(seconds: 2.0) {
                            await Task { EKEventStore() }.value
                        }
                    } catch {
                        throw EventKitError.initializationFailed
                    }

                    let reminders: [EKReminder]
                    let fetchReminders: () async throws -> [EKReminder]
                    if forToday {
                        let calendar = Calendar.current
                        let startOfDay = calendar.startOfDay(for: Date())
                        let endOfDay = calendar.date(byAdding: .day, value: 1, to: startOfDay)!
                        fetchReminders = {
                            try await store.fetchIncompleteReminders(withDueDateStarting: startOfDay, ending: endOfDay, calendars: nil)
                        }
                    } else {
                        fetchReminders = {
                            try await store.fetchIncompleteReminders(withDueDateStarting: nil, ending: nil, calendars: nil)
                        }
                    }

                    // The fetch itself can stall. Give more time when fetching all reminders vs. just today's.
                    let fetchTimeout = forToday ? 3.5 : 5.5
                    reminders = try await withTimeout(seconds: fetchTimeout, label: "showReminders.fetch") {
                        try await Task {
                            try await fetchReminders()
                        }.value
                    }

                    if reminders.isEmpty {
                        return forToday ? "You have no reminders due today." : "You have no reminders."
                    }

                    // Wrap potentially slow string processing in its own timeout as a safeguard.
                    let summaryText = try await withTimeout(seconds: 1.0, label: "showReminders.format") {
                        await Task {
                            let count = reminders.count
                            let todayQualifier = forToday ? " due today" : ""

                            if count == 1 {
                                return "You have 1 reminder\(todayQualifier): \(reminders[0].title ?? "Untitled")."
                            } else if count <= 5 {
                                let list = reminders.map { $0.title ?? "Untitled" }.joined(separator: ", ")
                                return "You have \(count) reminders\(todayQualifier): \(list)."
                            } else {
                                // Many reminders - ask what they want
                                let baseMessage = "You have \(count) reminders\(todayQualifier)."
                                let followUp = forToday ? " Want the list?" : " Want all of them, just today's, or something specific?"
                                return baseMessage + followUp
                            }
                        }.value
                    }
                    return summaryText
                }.value
            }
        } catch let error as TimeoutError {
            return error.localizedDescription
        } catch let error as EventKitError {
            return error.localizedDescription
        } catch {
            return "Couldn't fetch reminders: \(error.localizedDescription)."
        }
    }

    // MARK: - Shell helper

    private static func shell(_ command: String, timeout: TimeInterval = 5.0) async -> (stdout: String, exitCode: Int32) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-c", command]

        let outPipe = Pipe()
        process.standardOutput = outPipe
        let errPipe = Pipe()
        process.standardError = errPipe

        // A lock and flag to prevent the continuation from being resumed more than once,
        // which is crucial for handling the race between process termination and timeout.
        let lock = NSLock()
        var hasResumed = false

        do {
            return try await withTimeout(seconds: timeout) {
                try await withCheckedThrowingContinuation { continuation in
                    // Safely resumes the continuation exactly once.
                    let resumeOnce = { (result: Result<(String, Int32), Error>) in
                        lock.lock()
                        defer { lock.unlock() }
                        if !hasResumed {
                            hasResumed = true
                            continuation.resume(with: result)
                        }
                    }

                    var outputData = Data()
                    let maxOutputSize = 1_000_000 // 1MB limit to prevent memory exhaustion
                    let outputQueue = DispatchQueue(label: "shell-output-queue")

                    outPipe.fileHandleForReading.readabilityHandler = { handle in
                        outputQueue.async {
                            guard outputData.count < maxOutputSize else { return }
                            let availableData = handle.availableData
                            outputData.append(availableData.prefix(maxOutputSize - outputData.count))
                        }
                    }

                    errPipe.fileHandleForReading.readabilityHandler = { handle in
                        // We don't process stderr, but we must read from the pipe to prevent it from filling up and blocking the process.
                        outputQueue.async {
                            _ = handle.availableData
                        }
                    }

                    process.terminationHandler = { p in
                        outPipe.fileHandleForReading.readabilityHandler = nil
                        errPipe.fileHandleForReading.readabilityHandler = nil

                        // The work inside this handler can stall, especially when reading final data from pipes
                        // after a process terminates. We run it in a detached task with its own timeout to
                        // guarantee the continuation is always resumed, preventing the `shell` call from hanging.
                        Task.detached {
                            do {
                                // Increased timeout to 3.0s from 2.0s to more reliably handle
                                // final pipe reads and string conversion for large outputs (up to 1MB)
                                // without losing data due to an overly aggressive timeout.
                                let output = try await withTimeout(seconds: 3.0, label: "shell.terminationHandler") {
                                    // All synchronous work must be inside a cancellable Task.
                                    await Task {
                                        var finalOutputData = outputData

                                        // Read any final data from pipes. These are sync calls that can block.
                                        if finalOutputData.count < maxOutputSize {
                                            let availableData = outPipe.fileHandleForReading.availableData
                                            finalOutputData.append(availableData.prefix(maxOutputSize - finalOutputData.count))
                                        }

                                        // The string conversion can also stall on large/malformed data.
                                        return String(data: finalOutputData, encoding: .utf8) ?? ""
                                    }.value
                                }
                                resumeOnce(.success((output, p.terminationStatus)))
                            } catch {
                                // On timeout or other error within the handler, resume with an empty string
                                // and the original exit code to ensure the caller does not hang.
                                resumeOnce(.success(("", p.terminationStatus)))
                            }
                        }
                    }

                    do {
                        try process.run()
                    } catch {
                        // On failure to launch, handlers are still set. Clean them up to prevent a leak.
                        outPipe.fileHandleForReading.readabilityHandler = nil
                        errPipe.fileHandleForReading.readabilityHandler = nil
                        resumeOnce(.failure(error))
                    }
                }
            }
        } catch {
            // On timeout, the continuation is cancelled. We must prevent the terminationHandler
            // from trying to resume it later. We acquire the lock and mark it as resumed.
            lock.lock()
            hasResumed = true
            lock.unlock()

            // Clean up handlers and terminate the process.
            outPipe.fileHandleForReading.readabilityHandler = nil
            errPipe.fileHandleForReading.readabilityHandler = nil

            if process.isRunning {
                process.terminate()
            }

            if error is TimeoutError || error is CancellationError {
                return ("", 124) // Standard timeout exit code
            } else {
                return ("Failed to launch command.", -1)
            }
        }
    }

    // MARK: - Weather

    private static func getWeather() async -> String {
        do {
            return try await withTimeout(seconds: 5.0, label: #function) {
                guard let url = URL(string: "https://wttr.in/?format=%l:+%C+%t+%w") else {
                    return "Internal error: could not create weather URL."
                }

                var request = URLRequest(url: url)
                // wttr.in checks User-Agent to avoid sending HTML to browsers
                request.setValue("curl/8.6.0", forHTTPHeaderField: "User-Agent")
                request.timeoutInterval = 4.0

                // Give the network request its own timeout within the overall function timeout.
                let (data, response) = try await withTimeout(seconds: 4.5, label: "getWeather.network") {
                    try await URLSession.shared.data(for: request)
                }

                guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
                    return "Couldn't get the weather right now."
                }

                // Wrap potentially slow string processing in a Task to make it cancellable
                // and give it its own timeout as a safeguard, consistent with other helpers.
                let weatherString = try await withTimeout(seconds: 1.0, label: "getWeather.stringConversion") {
                    await Task {
                        String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
                    }.value
                }
                return weatherString ?? "Couldn't parse the weather response."
            }
        } catch let error as TimeoutError {
            return error.localizedDescription
        } catch {
            return "Couldn't get the weather due to an error: \(error.localizedDescription)."
        }
    }

    // MARK: - Music Control

    private static func controlMusic(command: String) async -> String {
        do {
            return try await withTimeout(seconds: 4.0) {
                // Wrap logic in a Task to make synchronous processing cancellable.
                return await Task {
                    let action: String
                    if command.contains("play") {
                        action = "play"
                    } else if command.contains("pause") || command.contains("stop") {
                        action = "pause"
                    } else if command.contains("next") || command.contains("skip") {
                        action = "next track"
                    } else if command.contains("previous") {
                        action = "previous track"
                    } else {
                        return "Music command not recognized"
                    }

                    let script = """
                    tell application "Music"
                        try
                            with timeout of 3 seconds
                                \(action)
                            end timeout
                        on error
                            error "Music app is not responding."
                        end try
                    end tell
                    """

                    let result = await shell("osascript -e '\(script)'", timeout: 3.5)
                    if result.exitCode == 124 { throw TimeoutError.timedOut(label: #function) }
                    return result.exitCode == 0 ? "Done." : "Music isn't running or is unresponsive."
                }.value
            }
        } catch let error as TimeoutError {
            return error.localizedDescription
        } catch {
            return "Couldn't control music due to an error."
        }
    }

    // MARK: - Screenshot

    private static func takeScreenshot() async -> String {
        do {
            return try await withTimeout(seconds: 4.0) {
                let timestamp = Int(Date().timeIntervalSince1970)
                let path = "/Users/charlieseay/Desktop/screenshot-\(timestamp).png"
                let result = await shell("screencapture -x '\(path)'", timeout: 3.0)
                if result.exitCode == 124 { throw TimeoutError.timedOut(label: #function) }
                return result.exitCode == 0 ? "Screenshot saved to Desktop" : "Couldn't take screenshot"
            }
        } catch let error as TimeoutError {
            return error.localizedDescription
        } catch {
            return "Couldn't take screenshot due to an error."
        }
    }

    // MARK: - HomeKit Control (via Home Assistant)

    private static func controlHomeKitDevice(name: String, action: String) async -> String {
        do {
            return try await withTimeout(seconds: 7.0) {
                // By wrapping the entire logic in a Task, we ensure that even synchronous,
                // thread-blocking operations within this block can be timed out.
                return try await Task {
                    // Map common names to Home Assistant entities
                    let entityMap: [String: String] = [
                        "bedroom": "light.bedroom_3",
                        "living room": "light.living_room",
                        "kitchen": "light.kitchen",
                        "office": "light.office",
                        "desk": "light.desk_lamp"
                    ]

                    guard let entity = entityMap[name] else {
                        return "I don't see a device named '\(name.capitalized)'."
                    }

                    // Read token with a timeout to prevent stalls on network volumes.
                    // The URL init itself can stall if the volume is unresponsive, so it's wrapped in a Task.
                    guard let tokenURL = await Task({ URL(fileURLWithPath: "/Volumes/data/secrets/homepage_ha_token") }).value else {
                        return "Internal error: could not create token URL."
                    }
                    let token = await readFileWithTimeout(url: tokenURL, timeout: 2.0)?
                        .trimmingCharacters(in: .whitespacesAndNewlines)

                    guard let token, !token.isEmpty else {
                        return "Home control isn't configured or the token is missing."
                    }

                    let domain = entity.components(separatedBy: ".").first ?? "light"
                    let service = action == "on" ? "turn_on" : "turn_off"

                    // The URL init with a .local address can sometimes stall on mDNS resolution.
                    // We wrap it in a Task to make it cancellable by the outer timeout.
                    let urlString = "http://homeassistant.local:8123/api/services/\(domain)/\(service)"
                    guard let url: URL = await Task({ URL(string: urlString) }).value else {
                        return "Internal error: could not create HomeKit URL."
                    }

                    var request = URLRequest(url: url)
                    request.httpMethod = "POST"
                    request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
                    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    request.timeoutInterval = 4.5 // Set a request-specific timeout

                    let body = ["entity_id": entity]
                    request.httpBody = try? JSONSerialization.data(withJSONObject: body)

                    let (_, response) = try await withTimeout(seconds: 5.0, label: "controlHomeKitDevice.urlSession") {
                        try await URLSession.shared.data(for: request)
                    }

                    if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 {
                        return "Done."
                    } else {
                        return "Couldn't control that device."
                    }
                }.value
            }
        } catch let error as TimeoutError {
            return error.localizedDescription
        } catch {
            return "Home control isn't responding due to an error."
        }
    }

    private static func extractHomeKitDevice(from text: String) -> String? {
        // Pattern match common device names to their entity map keys.
        // Order is important: more specific phrases must come first.
        let deviceMap: [(phrase: String, key: String)] = [
            ("bedroom lights", "bedroom"),
            ("bedroom light", "bedroom"),
            ("living room light", "living room"),
            ("kitchen light", "kitchen"),
            ("office light", "office"),
            ("desk lamp", "desk"),
            ("bedroom", "bedroom"),
            ("living room", "living room"),
            ("kitchen", "kitchen"),
            ("office", "office"),
            ("desk", "desk")
        ]

        for (phrase, key) in deviceMap {
            if text.contains(phrase) {
                return key
            }
        }

        return nil
    }

    // MARK: - Music Info

    private static func getCurrentSong() async -> String {
        do {
            return try await withTimeout(seconds: 4.0) {
                // Wrap logic in a Task to make synchronous processing cancellable.
                return await Task {
                    let script = """
                    tell application "Music"
                        try
                            with timeout of 3 seconds
                                if player state is playing then
                                    set trackName to name of current track
                                    set artistName to artist of current track
                                    return trackName & " by " & artistName
                                else
                                    return "not playing"
                                end if
                            end timeout
                        on error
                            return "error"
                        end try
                    end tell
                    """
                    let result = await shell("osascript -e '\(script)'", timeout: 3.5)
                    if result.exitCode == 124 { throw TimeoutError.timedOut(label: #function) }
                    if result.exitCode == 0 {
                        let output = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
                        if output.isEmpty || output == "not playing" || output == "error" {
                            return "Nothing's playing right now."
                        }
                        return output
                    }
                    return "Music isn't running or is unresponsive."
                }.value
            }
        } catch let error as TimeoutError {
            return error.localizedDescription
        } catch {
            return "Couldn't get the current song due to an error."
        }
    }

    // MARK: - Timer

    private static var timerTask: Task<Void, Never>?

    private static func setTimer(minutes: Int) async -> String {
        do {
            return try await withTimeout(seconds: 1.0) {
                // Cancel existing timer
                timerTask?.cancel()

                timerTask = Task {
                    try? await Task.sleep(nanoseconds: UInt64(minutes) * 60 * 1_000_000_000)
                    if !Task.isCancelled {
                        // Trigger notification/alert
                        _ = await shell("osascript -e 'display notification \"Timer finished\" with title \"Sonique Timer\"'", timeout: 2.0)
                        _ = await shell("afplay /System/Library/Sounds/Glass.aiff", timeout: 2.0)
                    }
                }

                return "Timer set for \(minutes) minute\(minutes == 1 ? "" : "s")."
            }
        } catch let error as TimeoutError {
            return error.localizedDescription
        } catch {
            return "Setting the timer failed due to an error."
        }
    }

    private static func cancelTimer() async -> String {
        do {
            return try await withTimeout(seconds: 1.0) {
                if timerTask != nil {
                    timerTask?.cancel()
                    timerTask = nil
                    return "Timer cancelled."
                }
                return "No active timer."
            }
        } catch let error as TimeoutError {
            return error.localizedDescription
        } catch {
            return "Cancelling the timer failed due to an error."
        }
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
        do {
            return try await withTimeout(seconds: 4.0) {
                let action = enabled ? "on" : "off"
                let result = await shell("shortcuts run 'Set Focus \(action.capitalized)'", timeout: 3.0)
                if result.exitCode == 124 { throw TimeoutError.timedOut(label: #function) }
                return result.exitCode == 0 ? "Focus mode \(action)." : "Couldn't change focus mode."
            }
        } catch let error as TimeoutError {
            return error.localizedDescription
        } catch {
            return "Couldn't change focus mode due to an error."
        }
    }

    private static func setDoNotDisturb(enabled: Bool) async -> String {
        do {
            return try await withTimeout(seconds: 4.0) {
                let action = enabled ? "on" : "off"
                let result = await shell("shortcuts run 'Set Do Not Disturb \(action.capitalized)'", timeout: 3.0)
                if result.exitCode == 124 { throw TimeoutError.timedOut(label: #function) }
                return result.exitCode == 0 ? "Do Not Disturb \(action)." : "Couldn't change Do Not Disturb."
            }
        } catch let error as TimeoutError {
            return error.localizedDescription
        } catch {
            return "Couldn't change Do Not Disturb due to an error."
        }
    }

    // MARK: - Screen Brightness

    private static func adjustBrightness(direction: String) async -> String {
        do {
            return try await withTimeout(seconds: 3.0) {
                let delta = direction == "up" ? "+0.1" : "-0.1"
                let result = await shell("brightness \(delta)", timeout: 2.0)
                if result.exitCode == 124 { throw TimeoutError.timedOut(label: #function) }
                return result.exitCode == 0 ? "Done." : "Couldn't adjust brightness."
            }
        } catch let error as TimeoutError {
            return error.localizedDescription
        } catch {
            return "Couldn't adjust brightness due to an error."
        }
    }

    // MARK: - Dark Mode

    private static func setDarkMode(enabled: Bool) async -> String {
        do {
            return try await withTimeout(seconds: 3.0) {
                let script = "tell application \"System Events\" to tell appearance preferences to set dark mode to \(enabled)"
                let result = await shell("osascript -e '\(script)'", timeout: 2.0)
                if result.exitCode == 124 { throw TimeoutError.timedOut(label: #function) }
                return result.exitCode == 0 ? "Dark mode \(enabled ? "on" : "off")." : "Couldn't change appearance."
            }
        } catch let error as TimeoutError {
            return error.localizedDescription
        } catch {
            return "Couldn't change appearance due to an error."
        }
    }

    // MARK: - System Control

    private static func lockScreen() async -> String {
        do {
            return try await withTimeout(seconds: 3.0) {
                let result = await shell("pmset displaysleepnow", timeout: 2.0)
                if result.exitCode == 124 { throw TimeoutError.timedOut(label: #function) }
                return result.exitCode == 0 ? "Screen locked." : "Couldn't lock screen."
            }
        } catch let error as TimeoutError {
            return error.localizedDescription
        } catch {
            return "Couldn't lock screen due to an error."
        }
    }

    private static func sleepMac() async -> String {
        do {
            return try await withTimeout(seconds: 3.0) {
                let result = await shell("pmset sleepnow", timeout: 2.0)
                if result.exitCode == 124 { throw TimeoutError.timedOut(label: #function) }
                return result.exitCode == 0 ? "Going to sleep." : "Couldn't sleep Mac."
            }
        } catch let error as TimeoutError {
            return error.localizedDescription
        } catch {
            return "Couldn't sleep Mac due to an error."
        }
    }

    // MARK: - Wi-Fi & Bluetooth

    private static func setWiFi(enabled: Bool) async -> String {
        do {
            return try await withTimeout(seconds: 6.0) {
                let action = enabled ? "on" : "off"
                let result = await shell("networksetup -setairportpower en0 \(action)", timeout: 5.0)
                if result.exitCode == 124 { throw TimeoutError.timedOut(label: #function) }
                return result.exitCode == 0 ? "Wi-Fi \(action)." : "Couldn't change Wi-Fi."
            }
        } catch let error as TimeoutError {
            return error.localizedDescription
        } catch {
            return "Couldn't change Wi-Fi due to an error."
        }
    }

    private static func setBluetooth(enabled: Bool) async -> String {
        do {
            return try await withTimeout(seconds: 4.0) {
                // Requires blueutil: brew install blueutil
                let action = enabled ? "--power 1" : "--power 0"
                let result = await shell("blueutil \(action)", timeout: 3.0)
                if result.exitCode == 124 { throw TimeoutError.timedOut(label: #function) }
                return result.exitCode == 0 ? "Bluetooth \(enabled ? "on" : "off")." : "Couldn't change Bluetooth."
            }
        } catch let error as TimeoutError {
            return error.localizedDescription
        } catch {
            return "Couldn't change Bluetooth due to an error."
        }
    }

    // MARK: - System Info

    private static func getDiskSpace() async -> String {
        do {
            return try await withTimeout(seconds: 3.0) {
                // Wrap logic in a Task to make synchronous processing cancellable.
                return await Task {
                    let result = await shell("df -h / | tail -1 | awk '{print $4\" available out of \"$2}'", timeout: 2.0)
                    if result.exitCode == 124 { throw TimeoutError.timedOut(label: #function) }
                    if result.exitCode == 0 && !result.stdout.isEmpty {
                        return result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
                    }
                    return "Couldn't get disk space."
                }.value
            }
        } catch let error as TimeoutError {
            return error.localizedDescription
        } catch {
            return "Couldn't get disk space due to an error."
        }
    }

    private static func getSystemStats() async -> String {
        do {
            return try await withTimeout(seconds: 3.0) {
                // Wrap logic in a Task to make synchronous processing cancellable.
                return await Task {
                    let result = await shell("top -l 1 | grep -E '^CPU|^PhysMem' | sed 's/CPU usage: //' | sed 's/PhysMem: /Memory: /'", timeout: 2.5)
                    if result.exitCode == 124 { throw TimeoutError.timedOut(label: #function) }
                    if result.exitCode == 0 && !result.stdout.isEmpty {
                        return result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
                    }
                    return "Couldn't get system stats."
                }.value
            }
        } catch let error as TimeoutError {
            return error.localizedDescription
        } catch {
            return "Couldn't get system stats due to an error."
        }
    }

    // MARK: - File Helper

    private static func readFileWithTimeout(url: URL, timeout: TimeInterval = 2.0) async -> String? {
        // Accessing properties like `isFileURL` or `path` on a URL pointing to an
        // unresponsive network volume can stall synchronously. The entire operation is
        // wrapped in a timeout, and property accesses are done in cancellable Tasks.
        do {
            return try await withTimeout(seconds: timeout, label: "readFileWithTimeout(url:timeout:)") {
                let isFileURL = await Task { url.isFileURL }.value

                if isFileURL {
                    // For file URLs on network volumes, `cat` is more robust than other methods.
                    let path = await Task { url.path }.value
                    let escapedPath = path.replacingOccurrences(of: "'", with: "'\\''")
                    let result = await shell("cat '\(escapedPath)'", timeout: timeout)

                    if result.exitCode == 0 {
                        return result.stdout
                    } else {
                        return nil
                    }
                } else {
                    // For non-file URLs, use URLSession with a request-specific timeout.
                    var request = URLRequest(url: url)
                    request.timeoutInterval = timeout
                    let (data, _) = try await withTimeout(seconds: timeout, label: "readFileWithTimeout.urlSession") {
                        try await URLSession.shared.data(for: request)
                    }
                    // The String conversion can be slow for large outputs. We wrap it in a
                    // timeout as a final safeguard against stalls from malformed/huge buffers,
                    // consistent with the pattern used in the shell helper.
                    return try await withTimeout(seconds: 1.0) {
                        await Task { String(data: data, encoding: .utf8) }.value
                    }
                }
            }
        } catch {
            // Catches timeouts from withTimeout or errors from URLSession.
            return nil
        }
    }

    // MARK: - Note Operations

    private static func readLastNote() async -> String {
        do {
            return try await withTimeout(seconds: 5.0, label: #function) {
                // Wrap synchronous FileManager call in a background task with a timeout to prevent stalls
                let vaultPath = try await withTimeout(seconds: 2.0, label: "readLastNote.vaultPath") {
                    await Task {
                        FileManager.default.homeDirectoryForCurrentUser
                            .appendingPathComponent("Library/Mobile Documents/iCloud~md~obsidian/Documents/SeaynicNet/Daily Notes")
                    }.value
                }

                // Find most recent daily note
                let dateFormatter = DateFormatter()
                dateFormatter.dateFormat = "yyyy-MM-dd"

                for daysAgo in 0..<7 {
                    let date = Calendar.current.date(byAdding: .day, value: -daysAgo, to: Date())!
                    let fileName = "\(dateFormatter.string(from: date)).md"
                    let filePath = vaultPath.appendingPathComponent(fileName)

                    if let content = await readFileWithTimeout(url: filePath) {
                        // Wrap potentially slow string processing in a Task to make it cancellable.
                        let result: String? = await Task {
                            let sections = content.components(separatedBy: "## Voice Note")
                            if let lastSection = sections.last, sections.count > 1 {
                                let noteContent = lastSection.components(separatedBy: "---").first ?? lastSection
                                return "Last note: \(noteContent.trimmingCharacters(in: .whitespacesAndNewlines).prefix(200))"
                            }
                            return nil
                        }.value

                        if let result = result {
                            return result // Found it, return from the whole function
                        }
                    }
                }

                return "No recent notes found."
            }
        } catch let error as TimeoutError {
            return error.localizedDescription
        } catch {
            return "Couldn't read notes due to an error."
        }
    }

    private static func readTodaysNotes() async -> String {
        do {
            return try await withTimeout(seconds: 5.0, label: #function) {
                // Wrap synchronous FileManager call in a background task with a timeout to prevent stalls
                let vaultPath = try await withTimeout(seconds: 2.0, label: "readTodaysNotes.vaultPath") {
                    await Task {
                        FileManager.default.homeDirectoryForCurrentUser
                            .appendingPathComponent("Library/Mobile Documents/iCloud~md~obsidian/Documents/SeaynicNet/Daily Notes")
                    }.value
                }

                let dateFormatter = DateFormatter()
                dateFormatter.dateFormat = "yyyy-MM-dd"
                let fileName = "\(dateFormatter.string(from: Date())).md"
                let filePath = vaultPath.appendingPathComponent(fileName)

                if let content = await readFileWithTimeout(url: filePath) {
                    // Wrap potentially slow string processing in a Task to make it cancellable.
                    let result: String? = await Task {
                        let sections = content.components(separatedBy: "## Voice Note")
                        if sections.count > 1 {
                            let notes = sections.dropFirst().map { section in
                                section.components(separatedBy: "---").first?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                            }
                            let fullNotes = notes.joined(separator: ". ")
                            // Truncate long output to prevent stalls and overly verbose responses
                            if fullNotes.count > 1000 {
                                return "You have \(notes.count) notes today. Here's the beginning: \(fullNotes.prefix(500))..."
                            }
                            return "Today's notes: \(fullNotes)"
                        }
                        return nil
                    }.value

                    return result ?? "No notes today yet."
                }

                return "No notes today yet."
            }
        } catch let error as TimeoutError {
            return error.localizedDescription
        } catch {
            return "Couldn't read today's notes due to an error."
        }
    }

    // MARK: - Math Calculations

    private static func calculateMath(from text: String) async -> String? {
        do {
            // Wrap in a short timeout as a safeguard against calculation stalls.
            // NSExpression is generally safe, but this prevents any edge cases with
            // complex string processing from hanging the intent layer.
            return try await withTimeout(seconds: 2.0, label: #function) {
                // By wrapping the entire logic in a Task, we ensure that even synchronous,
                // thread-blocking operations within this block can be timed out.
                return await Task {
                    // Convert natural language to a mathematical expression string.
                    let expressionString = text
                        .lowercased()
                        .replacingOccurrences(of: "what is", with: "")
                        .replacingOccurrences(of: "what's", with: "")
                        .replacingOccurrences(of: "plus", with: "+")
                        .replacingOccurrences(of: "add", with: "+")
                        .replacingOccurrences(of: "minus", with: "-")
                        .replacingOccurrences(of: "subtract", with: "-")
                        .replacingOccurrences(of: "times", with: "*")
                        .replacingOccurrences(of: "multiplied by", with: "*")
                        .replacingOccurrences(of: "divided by", with: "/")
                        .replacingOccurrences(of: "percent of", with: "* 0.01 *")
                        .replacingOccurrences(of: "% of", with: "* 0.01 *")
                        .replacingOccurrences(of: " is ", with: " ") // remove noise word
                        .trimmingCharacters(in: .whitespacesAndNewlines)

                    // A simple check to see if the string looks like a plausible math expression.
                    // This helps filter out non-math queries before passing them to NSExpression.
                    guard expressionString.contains(where: { $0.isNumber }) else {
                        return nil
                    }

                    do {
                        // NSExpression is a safe, sandboxed way to evaluate mathematical strings.
                        let expression = NSExpression(format: expressionString)
                        if let result = expression.expressionValue(with: nil, context: nil) as? NSNumber {
                            return formatNumber(result.doubleValue)
                        }
                    } catch {
                        // NSExpression parsing failed, likely not a valid math expression.
                        return nil
                    }
                    return nil
                }.value
            }
        } catch let error as TimeoutError {
            return error.localizedDescription
        } catch {
            // This catches errors from withTimeout, not from NSExpression.
            return "The calculation failed due to an error."
        }
    }

    private static func formatNumber(_ num: Double) -> String {
        if num.truncatingRemainder(dividingBy: 1) == 0 {
            return String(Int(num))
        } else {
            // Format to a reasonable number of decimal places, removing trailing zeros.
            let formatted = String(format: "%.4f", num)
                .replacingOccurrences(of: "\\.?0+$", with: "", options: .regularExpression)
            return formatted
        }
    }
}

private extension String {
    func matchesAny(_ phrases: [String]) -> Bool {
        phrases.contains { self.contains($0) }
    }
}
