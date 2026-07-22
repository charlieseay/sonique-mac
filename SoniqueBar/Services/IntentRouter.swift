import Foundation
import EventKit
#if os(macOS)
import IOKit.ps
#endif

/// Routes queries to native system capabilities before hitting LLM.
/// Handles time, date, calendar, weather, and other macOS/iOS-native intents.
@MainActor
final class IntentRouter {
    static let shared = IntentRouter()

    private let eventStore = EKEventStore()
    private let calendar = Calendar.current
    private let dateFormatter = DateFormatter()
    private let fallbackLogPath = "/Library/Logs/SoniqueBar/fallback.jsonl"

    private init() {
        dateFormatter.dateStyle = .medium
        dateFormatter.timeStyle = .short

        // Ensure log directory exists (Quinn's observability architecture!)
        let logDir = "/Library/Logs/SoniqueBar"
        try? FileManager.default.createDirectory(atPath: logDir, withIntermediateDirectories: true)
    }

    /// Attempts to handle query with native intent.
    /// Returns response if handled, nil if should route to LLM.
    func route(_ query: String) async -> String? {
        let lower = query.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)

        // Greetings - instant responses (no LLM)
        if matchesPattern(lower, patterns: [
            "good morning",
            "morning",
            "good afternoon",
            "afternoon",
            "good evening",
            "evening",
            "hello",
            "hi",
            "hey"
        ]) {
            return handleGreeting(query: lower)
        }

        // Combined day + date queries
        if matchesPattern(lower, patterns: [
            "day and date",
            "the day and date"
        ]) {
            let formatter = DateFormatter()
            formatter.dateFormat = "EEEE, MMMM d, yyyy"
            let fullDate = formatter.string(from: Date())
            return "Today is \(fullDate)."
        }

        // Time in specific timezone/city (CHECK THIS BEFORE generic "what time is it")
        if matchesPattern(lower, patterns: [
            "what time is it in ",
            "time in ",
            "what's the time in "
        ]) {
            // Skip multi-city queries (contain "and") - route to LLM for complex time comparisons
            if lower.contains(" and ") {
                return nil  // Route to LLM instead
            }
            let location = extractCity(from: lower)
            if !location.isEmpty {
                return getTimeInLocation(location)
            }
        }

        // Time queries (generic, check AFTER location-specific)
        if matchesPattern(lower, patterns: [
            "what time is it",
            "what's the time",
            "current time",
            "tell me the time"
        ]) {
            return handleTimeQuery()
        }

        // Date queries
        if matchesPattern(lower, patterns: [
            "what's the date",
            "what date is it",
            "what's today's date",
            "current date"
        ]) {
            return handleDateQuery()
        }

        // Day of week
        if matchesPattern(lower, patterns: [
            "what day is it",
            "what's today",
            "day of the week",
            "what day"
        ]) {
            return handleDayQuery()
        }

        // Next meeting queries (check before general calendar)
        if matchesPattern(lower, patterns: [
            "when's my next meeting",
            "when is my next meeting",
            "next meeting",
            "what's my next meeting",
            "what's next on my calendar"
        ]) {
            return await handleNextMeetingQuery()
        }

        // Calendar queries
        if matchesPattern(lower, patterns: [
            "what's on my calendar",
            "what's on my calendar today",
            "whats on my calendar today",
            "my calendar today",
            "today's calendar",
            "calendar events",
            "my schedule",
            "what's scheduled",
            "what's on my schedule",
            "calendar for today",
            "do i have any meetings",
            "what meetings do i have",
            "am i free"
        ]) {
            return await handleCalendarQuery()
        }

        // Tomorrow's calendar
        if matchesPattern(lower, patterns: [
            "calendar tomorrow",
            "what's on my calendar tomorrow",
            "tomorrow's calendar",
            "tomorrow's schedule",
            "meetings tomorrow",
            "schedule for tomorrow"
        ]) {
            return await handleCalendarQuery(daysFromToday: 1)
        }

        // This week's calendar
        if matchesPattern(lower, patterns: [
            "calendar this week",
            "this week's calendar",
            "schedule this week",
            "meetings this week"
        ]) {
            return await handleWeekCalendarQuery()
        }

        // Weather - city-specific or current location
        if matchesPattern(lower, patterns: [
            "what's the weather",
            "weather forecast",
            "how's the weather",
            "weather like",
            "what is the weather",
            "weather in ",
            "how's the weather in "
        ]) {
            // Check if city specified
            if lower.contains(" in ") {
                let city = extractCity(from: lower)
                if !city.isEmpty {
                    return await WeatherService.shared.getWeatherForCity(city)
                }
            }
            return await WeatherService.shared.getCurrentWeather()
        }

        // iOS Shortcuts - Timer
        if matchesPattern(lower, patterns: [
            "set timer for",
            "timer for",
            "set a timer"
        ]) {
            return handleShortcutIntent(.setTimer(parseMinutes(from: query)))
        }

        // iOS Shortcuts - Do Not Disturb
        if matchesPattern(lower, patterns: [
            "turn on do not disturb",
            "enable do not disturb",
            "turn on dnd",
            "enable dnd"
        ]) {
            return handleShortcutIntent(.toggleDND(true))
        }

        if matchesPattern(lower, patterns: [
            "turn off do not disturb",
            "disable do not disturb",
            "turn off dnd",
            "disable dnd"
        ]) {
            return handleShortcutIntent(.toggleDND(false))
        }

        // iOS Shortcuts - Reminders
        if matchesPattern(lower, patterns: [
            "remind me to",
            "create reminder",
            "add reminder"
        ]) {
            let reminderText = extractReminderText(from: query)
            return handleShortcutIntent(.createReminder(reminderText))
        }

        // System info
        if matchesPattern(lower, patterns: [
            "battery level",
            "battery status",
            "how's my battery"
        ]) {
            return handleBatteryQuery()
        }

        // Lab infrastructure queries
        if matchesPattern(lower, patterns: [
            "check helmsman",
            "helmsman tasks",
            "helmsman queue",
            "pending tasks",
            "how many tasks"
        ]) {
            return await handleHelmsmanQuery()
        }

        // MVP Task Dispatch - special command format
        // Format: "dispatch task: <description> to <owner> effort <S/M/L/XL>"
        if lower.contains("dispatch task:") {
            return await handleTaskDispatch(query)
        }

        if matchesPattern(lower, patterns: [
            "list files in",
            "what files are in",
            "show files in",
            "files in memory"
        ]) {
            return await handleListFilesQuery(query)
        }

        if matchesPattern(lower, patterns: [
            "read handoff",
            "sonique handoff",
            "project status"
        ]) {
            return await handleVaultReadQuery("Projects/Sonique/HANDOFF.md")
        }

        // NotebookLM vault queries - projects notebook
        if matchesPattern(lower, patterns: [
            "status of",
            "what's happening with",
            "progress on",
            "recent work on",
            "what projects",
            "project activity",
            "blockers on"
        ]) {
            return await handleNotebookQuery(query, notebook: "projects")
        }

        // NotebookLM vault queries - team knowledge base
        if matchesPattern(lower, patterns: [
            "how do i deploy",
            "where is running",
            "infrastructure",
            "security checklist",
            "api standard",
            "vault schema"
        ]) {
            return await handleNotebookQuery(query, notebook: "team-kb")
        }

        // NotebookLM vault queries - tech stack knowledge base (NEW!)
        if matchesPattern(lower, patterns: [
            "how does",
            "how to use",
            "api documentation",
            "framework documentation",
            "library reference",
            "tech stack",
            "claude api",
            "docker compose",
            "swift syntax",
            "python async"
        ]) {
            return await handleNotebookQuery(query, notebook: "tech-kb")
        }

        // No native intent matched - route to LLM
        return nil
    }

    // MARK: - Intent Handlers

    private func handleTimeQuery() -> String {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        let time = formatter.string(from: Date())
        return "It's \(time)."
    }

    private func handleDateQuery() -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .full
        let date = formatter.string(from: Date())
        return "Today is \(date)."
    }

    private func handleDayQuery() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEEE"
        let day = formatter.string(from: Date())
        return "Today is \(day)."
    }

    private func handleGreeting(query: String) -> String {
        let hour = Calendar.current.component(.hour, from: Date())

        // Time-appropriate greeting
        if query.contains("morning") || (hour >= 5 && hour < 12) {
            return ["Good morning!", "Morning!", "Hello! Good morning."].randomElement()!
        } else if query.contains("afternoon") || (hour >= 12 && hour < 17) {
            return ["Good afternoon!", "Afternoon!", "Hello! Good afternoon."].randomElement()!
        } else if query.contains("evening") || (hour >= 17 && hour < 22) {
            return ["Good evening!", "Evening!", "Hello! Good evening."].randomElement()!
        } else {
            // Generic greetings for "hello", "hi", "hey" or late night
            return ["Hello!", "Hi there!", "Hey!", "Hello! How can I help?"].randomElement()!
        }
    }

    private func handleCalendarQuery(daysFromToday: Int = 0) async -> String {
        // Request calendar access (compatible with macOS 13+)
        if #available(macOS 14.0, *) {
            do {
                let granted = try await eventStore.requestFullAccessToEvents()
                guard granted else {
                    return "I don't have calendar access. Please grant permission in System Settings."
                }
            } catch {
                return "I couldn't access your calendar: \(error.localizedDescription)"
            }
        } else {
            // Fallback for macOS 13
            let granted = await withCheckedContinuation { continuation in
                eventStore.requestAccess(to: .event) { granted, _ in
                    continuation.resume(returning: granted)
                }
            }
            guard granted else {
                return "I don't have calendar access. Please grant permission in System Settings."
            }
        }

        // Calculate target day
        let targetDate = calendar.date(byAdding: .day, value: daysFromToday, to: Date()) ?? Date()
        let startOfDay = calendar.startOfDay(for: targetDate)
        let endOfDay = calendar.date(byAdding: .day, value: 1, to: startOfDay)!

        let predicate = eventStore.predicateForEvents(
            withStart: startOfDay,
            end: endOfDay,
            calendars: nil
        )
        let events = eventStore.events(matching: predicate)

        let dayLabel = daysFromToday == 0 ? "today" : daysFromToday == 1 ? "tomorrow" : "that day"

        if events.isEmpty {
            return "You have no events scheduled for \(dayLabel)."
        }

        if events.count == 1 {
            let event = events[0]
            let timeFormatter = DateFormatter()
            timeFormatter.timeStyle = .short
            let time = timeFormatter.string(from: event.startDate)
            return "You have 1 event \(dayLabel): \(event.title ?? "Untitled") at \(time)."
        }

        // Multiple events - summarize
        let eventList = events.prefix(3).map { event in
            let timeFormatter = DateFormatter()
            timeFormatter.timeStyle = .short
            let time = timeFormatter.string(from: event.startDate)
            return "\(event.title ?? "Untitled") at \(time)"
        }.joined(separator: ", ")

        let suffix = events.count > 3 ? ", and \(events.count - 3) more" : ""
        return "You have \(events.count) events \(dayLabel): \(eventList)\(suffix)."
    }

    private func handleWeekCalendarQuery() async -> String {
        // Request calendar access
        if #available(macOS 14.0, *) {
            do {
                let granted = try await eventStore.requestFullAccessToEvents()
                guard granted else {
                    return "I don't have calendar access. Please grant permission in System Settings."
                }
            } catch {
                return "I couldn't access your calendar: \(error.localizedDescription)"
            }
        } else {
            let granted = await withCheckedContinuation { continuation in
                eventStore.requestAccess(to: .event) { granted, _ in
                    continuation.resume(returning: granted)
                }
            }
            guard granted else {
                return "I don't have calendar access. Please grant permission in System Settings."
            }
        }

        // Get events for the next 7 days
        let now = Date()
        let startOfToday = calendar.startOfDay(for: now)
        let endOfWeek = calendar.date(byAdding: .day, value: 7, to: startOfToday)!

        let predicate = eventStore.predicateForEvents(
            withStart: startOfToday,
            end: endOfWeek,
            calendars: nil
        )
        let events = eventStore.events(matching: predicate)

        if events.isEmpty {
            return "You have no events scheduled this week."
        }

        // Group by day
        var eventsByDay: [String: [EKEvent]] = [:]
        let dayFormatter = DateFormatter()
        dayFormatter.dateFormat = "EEEE"  // "Monday", "Tuesday", etc.

        for event in events {
            let dayKey = dayFormatter.string(from: event.startDate)
            eventsByDay[dayKey, default: []].append(event)
        }

        let totalCount = events.count
        let dayCount = eventsByDay.count

        // Summarize by day
        let summary = eventsByDay.keys.sorted().prefix(3).map { day in
            let count = eventsByDay[day]?.count ?? 0
            return "\(day): \(count) event\(count == 1 ? "" : "s")"
        }.joined(separator: ", ")

        let suffix = eventsByDay.count > 3 ? ", and more" : ""
        return "You have \(totalCount) events across \(dayCount) days this week: \(summary)\(suffix)."
    }

    private func handleNextMeetingQuery() async -> String {
        // Request calendar access
        if #available(macOS 14.0, *) {
            do {
                let granted = try await eventStore.requestFullAccessToEvents()
                guard granted else {
                    return "I don't have calendar access. Please grant permission in System Settings."
                }
            } catch {
                return "I couldn't access your calendar: \(error.localizedDescription)"
            }
        } else {
            let granted = await withCheckedContinuation { continuation in
                eventStore.requestAccess(to: .event) { granted, _ in
                    continuation.resume(returning: granted)
                }
            }
            guard granted else {
                return "I don't have calendar access. Please grant permission in System Settings."
            }
        }

        // Find next event starting from now
        let now = Date()
        let endOfWeek = calendar.date(byAdding: .day, value: 7, to: now)!

        let predicate = eventStore.predicateForEvents(
            withStart: now,
            end: endOfWeek,
            calendars: nil
        )
        let events = eventStore.events(matching: predicate)
            .filter { $0.startDate > now }  // Only future events
            .sorted { $0.startDate < $1.startDate }  // Sort by start time

        guard let nextEvent = events.first else {
            return "You have no upcoming meetings in the next 7 days."
        }

        let timeFormatter = DateFormatter()
        timeFormatter.timeStyle = .short
        let time = timeFormatter.string(from: nextEvent.startDate)

        // Calculate time until meeting
        let timeUntil = nextEvent.startDate.timeIntervalSince(now)
        let hoursUntil = Int(timeUntil / 3600)
        let minutesUntil = Int((timeUntil.truncatingRemainder(dividingBy: 3600)) / 60)

        let timeUntilString: String
        if hoursUntil >= 24 {
            let dayFormatter = DateFormatter()
            dayFormatter.dateFormat = "EEEE"
            let day = dayFormatter.string(from: nextEvent.startDate)
            timeUntilString = " on \(day) at \(time)"
        } else if hoursUntil >= 1 {
            timeUntilString = " in \(hoursUntil) hour\(hoursUntil == 1 ? "" : "s")"
        } else if minutesUntil >= 1 {
            timeUntilString = " in \(minutesUntil) minute\(minutesUntil == 1 ? "" : "s")"
        } else {
            timeUntilString = " starting now"
        }

        return "Your next meeting is \(nextEvent.title ?? "Untitled")\(timeUntilString)."
    }

    private func handleBatteryQuery() -> String {
        #if os(macOS)
        // macOS battery info via IOKit
        let snapshot = IOPSCopyPowerSourcesInfo().takeRetainedValue()
        let sources = IOPSCopyPowerSourcesList(snapshot).takeRetainedValue() as Array

        if let source = sources.first {
            if let info = IOPSGetPowerSourceDescription(snapshot, source).takeUnretainedValue() as? [String: Any],
               let current = info[kIOPSCurrentCapacityKey] as? Int {
                return "Your battery is at \(current)%."
            }
        }

        return "I couldn't read your battery status."
        #else
        // iOS battery (if needed)
        UIDevice.current.isBatteryMonitoringEnabled = true
        let level = UIDevice.current.batteryLevel
        if level >= 0 {
            return "Your battery is at \(Int(level * 100))%."
        }
        return "I couldn't read your battery status."
        #endif
    }

    // MARK: - Lab Infrastructure Handlers

    private func handleHelmsmanQuery() async -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
        process.arguments = ["-sf", "http://localhost:5682/tasks?status=pending"]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        do {
            try process.run()
            process.waitUntilExit()

            // BUG FIX #9: Close pipe handle after reading to prevent file handle leak
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            try? pipe.fileHandleForReading.close()

            guard let json = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
                return "Failed to parse Helmsman response."
            }

            if json.isEmpty {
                return "Helmsman queue is empty - no pending tasks."
            }

            let taskCount = json.count
            let preview = json.prefix(3).compactMap { task -> String? in
                guard let num = task["num"] as? Int,
                      let owner = task["owner"] as? String,
                      let taskText = task["task"] as? String else { return nil }
                return "#\(num) [\(owner)] \(taskText.prefix(50))"
            }.joined(separator: "\n")

            return "Helmsman has \(taskCount) pending tasks:\n\(preview)" + (taskCount > 3 ? "\n... and \(taskCount - 3) more" : "")
        } catch {
            return "Failed to query Helmsman: \(error.localizedDescription)"
        }
    }

    /// Parse and handle task dispatch command
    /// Format: "dispatch task: <description> to <owner> effort <S/M/L/XL>"
    private func handleTaskDispatch(_ query: String) async -> String {
        // Parse from RIGHT to LEFT to handle "to" in task description
        let lower = query.lowercased()

        // Find "effort" first (rightmost)
        guard let effortIndex = lower.range(of: " effort ")?.lowerBound else {
            return "Missing ' effort '. Format: dispatch task: <desc> to <owner> effort <S/M/L/XL>"
        }

        let effortStart = query.index(after: query.index(effortIndex, offsetBy: 7))
        let effortStr = String(query[effortStart...]).trimmingCharacters(in: .whitespaces).uppercased()

        // Everything before "effort" - now find LAST "to" before effort
        let beforeEffort = String(query[..<effortIndex])
        let beforeEffortLower = beforeEffort.lowercased()

        guard let lastToIndex = beforeEffortLower.range(of: " to ", options: .backwards)?.lowerBound else {
            return "Missing ' to '. Format: dispatch task: <desc> to <owner> effort <S/M/L/XL>"
        }

        let toEnd = beforeEffort.index(after: beforeEffort.index(lastToIndex, offsetBy: 3))
        let ownerStr = String(beforeEffort[toEnd...]).trimmingCharacters(in: .whitespaces).uppercased()

        // Everything before the last "to" is the task (after "dispatch task:")
        let beforeTo = String(beforeEffort[..<lastToIndex])
        guard let taskStart = beforeTo.lowercased().range(of: "dispatch task:")?.upperBound else {
            return "Missing 'dispatch task:'. Format: dispatch task: <desc> to <owner> effort <S/M/L/XL>"
        }

        let taskDesc = String(beforeTo[taskStart...]).trimmingCharacters(in: .whitespaces)

        // Security: Sanitize logging to prevent injection
        let sanitizedTask = taskDesc
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .prefix(100)
        NSLog("[TaskDispatch] Parsed - Task: '\(sanitizedTask)', Owner: '\(ownerStr)', Effort: '\(effortStr)'")

        // Validate task description
        guard !taskDesc.isEmpty else {
            return "Task description cannot be empty"
        }

        guard taskDesc.count <= 500 else {
            return "Task description too long (max 500 chars)"
        }

        // Security: Validate owner field to prevent injection
        let validOwners = ["CHARLIE", "AIDER-GEM", "NVIDIA-AGENT", "CURSOR", "CLAUDE"]
        guard validOwners.contains(ownerStr) else {
            return "Invalid owner '\(ownerStr)'. Must be one of: \(validOwners.joined(separator: ", "))"
        }

        // Security: Validate effort field
        let validEfforts = ["S", "M", "L", "XL"]
        guard validEfforts.contains(effortStr) else {
            return "Invalid effort '\(effortStr)'. Must be one of: \(validEfforts.joined(separator: ", "))"
        }

        // Create the task
        return await createHelmsmanTask(
            task: taskDesc,
            owner: ownerStr,
            effort: effortStr,
            summary: "MVP task dispatch from Quinn"
        )
    }

    /// Create a task in helmsman.db (MVP task dispatch!)
    private func createHelmsmanTask(task: String, owner: String, effort: String, summary: String) async -> String {
        let taskData: [String: Any] = [
            "task": task,
            "owner": owner,
            "effort": effort,
            "summary": summary,
            "status": "pending",
            "lane": "default",
            "skip_brief_requirement": 1  // MVP mode - no brief required
        ]

        guard let jsonData = try? JSONSerialization.data(withJSONObject: taskData),
              let jsonString = String(data: jsonData, encoding: .utf8) else {
            return "Failed to create task JSON"
        }

        NSLog("[TaskDispatch] Sending JSON: \(jsonString)")

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
        process.arguments = [
            "-s",  // Silent but don't fail on HTTP errors
            "-X", "POST",
            "-H", "Content-Type: application/json",
            "-d", jsonString,
            "http://localhost:5682/tasks"
        ]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        do {
            try process.run()
            process.waitUntilExit()

            // BUG FIX #12: Close pipe handle after reading to prevent file handle leak
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            try? pipe.fileHandleForReading.close()

            guard let responseStr = String(data: data, encoding: .utf8) else {
                return "Failed to decode response"
            }

            NSLog("[TaskDispatch] Response: \(responseStr)")

            guard let response = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return "Task API response: \(responseStr)"
            }

            // Try both "num" and "task_num" fields
            let taskNum = (response["task_num"] as? Int) ?? (response["num"] as? Int) ?? 0

            if taskNum > 0 {
                return "✓ Created task #\(taskNum) assigned to \(owner)"
            } else {
                return "Task created but couldn't get task number"
            }
        } catch {
            return "Failed to create task: \(error.localizedDescription)"
        }
    }

    // MARK: - NotebookLM Vault Query Handler

    private func handleNotebookQuery(_ query: String, notebook: String) async -> String {
        let notebookId: String
        switch notebook {
        case "projects":
            notebookId = "201885bd-9c21-4d6d-ad7d-bb69e72d11df"
        case "team-kb":
            notebookId = "d45f4666-0a50-4986-9f53-abe7d92107c1"
        case "tech-kb":
            notebookId = "60211d85-ad2b-46a1-b2a4-4dd40294dbb1"
        default:
            return "Unknown notebook: \(notebook)"
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/Users/charlieseay/.local/bin/nlm")
        process.arguments = ["notebook", "query", notebookId, query]

        var env = ProcessInfo.processInfo.environment
        env["HOME"] = env["HOME"] ?? "/Users/charlieseay"
        process.environment = env

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        do {
            try process.run()

            // BUG FIX #4: Wait for process with timeout AND cancellation support
            // (NotebookLM can take 20-30s) — must handle task cancellation gracefully
            let maxWaitTime: TimeInterval = 45.0
            let checkInterval: TimeInterval = 0.5
            var elapsed: TimeInterval = 0

            while process.isRunning && elapsed < maxWaitTime {
                // Check for cancellation before sleeping
                try Task.checkCancellation()
                try await Task.sleep(nanoseconds: UInt64(checkInterval * 1_000_000_000))
                elapsed += checkInterval
            }

            // If still running, terminate it
            if process.isRunning {
                process.terminate()
                return await fallbackToDirectFileAccess(
                    query: query,
                    notebook: notebook,
                    reason: "timeout",
                    timeoutMs: Int(maxWaitTime * 1000)
                )
            }

            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            guard let output = String(data: data, encoding: .utf8) else {
                return "Failed to decode NotebookLM response."
            }

            if process.terminationStatus != 0 {
                // Fallback to direct file access when NotebookLM fails
                NSLog("[IntentRouter] NotebookLM failed, falling back to direct file access")
                return await fallbackToDirectFileAccess(
                    query: query,
                    notebook: notebook,
                    reason: "error",
                    timeoutMs: Int(maxWaitTime * 1000)
                )
            }

            let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                return "NotebookLM returned no results for this query."
            }

            // Parse JSON response to extract answer field
            if let jsonData = trimmed.data(using: .utf8),
               let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
               let answer = json["answer"] as? String {
                return "Based on the vault:\n\n\(answer)"
            }

            // Fallback to raw output if not JSON
            return "Based on the vault:\n\n\(trimmed)"
        } catch {
            // Fallback to direct file access when NotebookLM is unavailable
            NSLog("[IntentRouter] NotebookLM unavailable, falling back to direct file access")
            return await fallbackToDirectFileAccess(
                query: query,
                notebook: notebook,
                reason: "unreachable",
                timeoutMs: 45000
            )
        }
    }

    private func fallbackToDirectFileAccess(query: String, notebook: String, reason: String, timeoutMs: Int) async -> String {
        NSLog("[IntentRouter] Using direct file access fallback for: \(query)")

        let fallbackStart = Date()

        // Determine which vault area to search based on notebook
        let vaultPath = "/Users/charlieseay/Library/Mobile Documents/iCloud~md~obsidian/Documents/SeaynicNet"
        let searchPath: String

        switch notebook {
        case "projects":
            searchPath = "\(vaultPath)/Projects"
        case "team-kb":
            searchPath = vaultPath  // Broader search for infrastructure
        case "tech-kb":
            searchPath = vaultPath  // Tech docs could be anywhere
        default:
            // Log failed fallback
            logFallback(
                reason: reason,
                query: query,
                timeoutMs: timeoutMs,
                fallbackDurationMs: 0,
                success: false,
                resultsCount: 0,
                searchTerms: []
            )
            return "NotebookLM unavailable and unknown fallback path for: \(notebook)"
        }

        // Use grep to search vault files WITH CONTEXT (Quinn's suggestion!)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/grep")

        // Extract key terms from query for grep
        let searchTerms = extractSearchTerms(from: query)
        if searchTerms.isEmpty {
            // Log failed fallback
            logFallback(
                reason: reason,
                query: query,
                timeoutMs: timeoutMs,
                fallbackDurationMs: Int(Date().timeIntervalSince(fallbackStart) * 1000),
                success: false,
                resultsCount: 0,
                searchTerms: []
            )
            return "NotebookLM unavailable. Please try a more specific query or check NotebookLM status."
        }

        // PERF OPT #5: Use -E for extended regex with anchored patterns to reduce matches
        // Single simple term → -F (literal, fastest); multiple/complex → -E (with anchors)
        if searchTerms.count == 1 && !searchTerms[0].contains("[^a-zA-Z0-9]") {
            // Single simple term - use -F (fixed string) for maximum speed
            process.arguments = ["-r", "-i", "-n", "-C", "2", "-F", searchTerms[0], searchPath]
        } else {
            // Multiple terms or special chars - use -E (extended regex) with word boundaries
            let anchoredTerms = searchTerms.map { "\\<\($0)\\>" }
            let pattern = anchoredTerms.joined(separator: "|")
            process.arguments = ["-r", "-i", "-n", "-C", "2", "-E", pattern, searchPath]
        }

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        do {
            try process.run()
            process.waitUntilExit()

            // BUG FIX #11: Close pipe handle after reading to prevent file handle leak
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            try? pipe.fileHandleForReading.close()

            guard let output = String(data: data, encoding: .utf8) else {
                // Log failed fallback
                logFallback(
                    reason: reason,
                    query: query,
                    timeoutMs: timeoutMs,
                    fallbackDurationMs: Int(Date().timeIntervalSince(fallbackStart) * 1000),
                    success: false,
                    resultsCount: 0,
                    searchTerms: searchTerms
                )
                return "NotebookLM unavailable and direct search failed."
            }

            if output.isEmpty {
                // Log failed fallback (no results)
                logFallback(
                    reason: reason,
                    query: query,
                    timeoutMs: timeoutMs,
                    fallbackDurationMs: Int(Date().timeIntervalSince(fallbackStart) * 1000),
                    success: false,
                    resultsCount: 0,
                    searchTerms: searchTerms
                )
                return "NotebookLM unavailable. No matching content found in vault for: \(query)"
            }

            // Parse grep output to extract file excerpts
            let excerpts = parseGrepOutput(output)
            if excerpts.isEmpty {
                // Log failed fallback (parse failed)
                logFallback(
                    reason: reason,
                    query: query,
                    timeoutMs: timeoutMs,
                    fallbackDurationMs: Int(Date().timeIntervalSince(fallbackStart) * 1000),
                    success: false,
                    resultsCount: 0,
                    searchTerms: searchTerms
                )
                return "NotebookLM unavailable. No matching content found in vault for: \(query)"
            }

            // Build response with excerpts (Quinn's suggestion: show content, not just paths!)
            var response = "⚠️ NotebookLM unavailable - showing vault excerpts:\n\n"
            for (idx, excerpt) in excerpts.prefix(3).enumerated() {
                response += "[\(idx + 1)] \(excerpt.file)\n\(excerpt.content)\n\n"
            }

            if excerpts.count > 3 {
                response += "... and \(excerpts.count - 3) more matches.\n"
            }

            // Log successful fallback!
            logFallback(
                reason: reason,
                query: query,
                timeoutMs: timeoutMs,
                fallbackDurationMs: Int(Date().timeIntervalSince(fallbackStart) * 1000),
                success: true,
                resultsCount: excerpts.count,
                searchTerms: searchTerms
            )

            return response

        } catch {
            // Log failed fallback (exception)
            logFallback(
                reason: reason,
                query: query,
                timeoutMs: timeoutMs,
                fallbackDurationMs: Int(Date().timeIntervalSince(fallbackStart) * 1000),
                success: false,
                resultsCount: 0,
                searchTerms: searchTerms
            )
            return "NotebookLM unavailable and direct file access failed: \(error.localizedDescription)"
        }
    }

    private struct GrepExcerpt {
        let file: String
        let content: String
    }

    private func parseGrepOutput(_ output: String) -> [GrepExcerpt] {
        var excerpts: [GrepExcerpt] = []
        var currentFile: String?
        var currentLines: [String] = []

        for line in output.components(separatedBy: "\n") {
            // Grep format: path/to/file:123:content or path/to/file-123-context
            if let colonRange = line.range(of: ":"),
               let dashRange = line.range(of: "-") {
                // New file or continuation
                let filePath = String(line[..<min(colonRange.lowerBound, dashRange.lowerBound)])
                if currentFile != filePath {
                    // Save previous excerpt
                    if let file = currentFile, !currentLines.isEmpty {
                        excerpts.append(GrepExcerpt(
                            file: file,
                            content: currentLines.joined(separator: "\n")
                        ))
                    }
                    currentFile = filePath
                    currentLines = []
                }
                // Extract content after line number
                if let contentStart = line.firstIndex(of: ":") {
                    currentLines.append(String(line[line.index(after: contentStart)...]))
                }
            }
        }

        // Save last excerpt
        if let file = currentFile, !currentLines.isEmpty {
            excerpts.append(GrepExcerpt(
                file: file,
                content: currentLines.joined(separator: "\n")
            ))
        }

        return excerpts
    }

    private func extractSearchTerms(from query: String) -> [String] {
        // Improved stopword filtering (Quinn's suggestion!)
        let stopwords = Set([
            // Question words
            "what", "when", "where", "which", "who", "whom", "whose", "why", "how",
            // Auxiliary verbs
            "have", "has", "had", "does", "did", "do", "will", "would", "should", "could", "can",
            "may", "might", "must", "shall",
            // Common verbs
            "is", "are", "was", "were", "been", "being", "am",
            // Prepositions & conjunctions
            "about", "from", "with", "into", "onto", "through", "between", "among",
            "and", "or", "but", "for", "nor", "yet", "so",
            // Articles & pronouns
            "the", "a", "an", "this", "that", "these", "those",
            "it", "its", "they", "them", "their"
        ])

        let words = query.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count > 2 && !stopwords.contains($0) }  // Lowered from >3 to >2 for "api", "db", etc

        return Array(words.prefix(5))  // Top 5 terms (increased from 3 for better matches)
    }

    private func handleListFilesQuery(_ query: String) async -> String {
        // Extract path from query
        var path = "~/Library/Application Support/SoniqueBar/memory/"

        // Try to extract path from query
        if let pathMatch = query.range(of: "in\\s+([~\\/.\\w\\s]+)", options: .regularExpression) {
            path = String(query[pathMatch]).replacingOccurrences(of: "in ", with: "").trimmingCharacters(in: .whitespaces)
        }

        // Expand tilde
        let expandedPath = NSString(string: path).expandingTildeInPath

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ls")
        process.arguments = ["-lah", expandedPath]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        do {
            try process.run()
            process.waitUntilExit()

            // BUG FIX #10: Close pipe handle after reading to prevent file handle leak
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            try? pipe.fileHandleForReading.close()

            guard let output = String(data: data, encoding: .utf8) else {
                return "Failed to list files."
            }

            return "Files in \(expandedPath):\n\(output)"
        } catch {
            return "Failed to list files: \(error.localizedDescription)"
        }
    }

    private func handleVaultReadQuery(_ relativePath: String) async -> String {
        let vaultRoot = NSString(string: "~/Library/Mobile Documents/iCloud~md~obsidian/Documents/SeaynicNet").expandingTildeInPath
        let fullPath = "\(vaultRoot)/\(relativePath)"

        do {
            let content = try String(contentsOfFile: fullPath, encoding: .utf8)
            // Return first 500 chars to avoid overwhelming TTS
            if content.count > 500 {
                return String(content.prefix(500)) + "...\n\n(truncated - full file is \(content.count) characters)"
            }
            return content
        } catch {
            return "Failed to read vault file: \(error.localizedDescription)"
        }
    }

    // MARK: - Pattern Matching

    private func matchesPattern(_ query: String, patterns: [String]) -> Bool {
        for pattern in patterns {
            if query.contains(pattern) {
                return true
            }
        }
        return false
    }

    // MARK: - Observability (Quinn's architecture!)

    private func logFallback(
        reason: String,
        query: String,
        timeoutMs: Int,
        fallbackDurationMs: Int,
        success: Bool,
        resultsCount: Int,
        searchTerms: [String]
    ) {
        let logEntry: [String: Any] = [
            "timestamp": ISO8601DateFormatter().string(from: Date()),
            "event": "notebooklm_fallback",
            "reason": reason,
            "query": query,
            "timeout_ms": timeoutMs,
            "fallback_duration_ms": fallbackDurationMs,
            "fallback_success": success,
            "results_returned": resultsCount,
            "search_terms": searchTerms
        ]

        do {
            let jsonData = try JSONSerialization.data(withJSONObject: logEntry)
            if let jsonString = String(data: jsonData, encoding: .utf8) {
                // Append to JSONL file
                let logLine = jsonString + "\n"
                if let logData = logLine.data(using: .utf8) {
                    if FileManager.default.fileExists(atPath: fallbackLogPath) {
                        if let fileHandle = try? FileHandle(forWritingTo: URL(fileURLWithPath: fallbackLogPath)) {
                            fileHandle.seekToEndOfFile()
                            fileHandle.write(logData)
                            fileHandle.closeFile()
                        }
                    } else {
                        try? logData.write(to: URL(fileURLWithPath: fallbackLogPath))
                    }
                }

                // Also NSLog in debug builds
                #if DEBUG
                NSLog("[Fallback] \(reason): \(query) → \(resultsCount) results in \(fallbackDurationMs)ms")
                #endif
            }
        } catch {
            NSLog("[IntentRouter] Failed to log fallback: \(error)")
        }
    }

    // MARK: - Shortcut Intent Handling

    private enum ShortcutIntent {
        case setTimer(Int)  // minutes
        case toggleDND(Bool)  // enable/disable
        case createReminder(String)  // text
    }

    private func handleShortcutIntent(_ intent: ShortcutIntent) -> String {
        // Return JSON instruction for iOS to execute
        // iOS VoiceLoop will parse this and call ShortcutsManager
        switch intent {
        case .setTimer(let minutes):
            return "[SHORTCUT:SET_TIMER:\(minutes)]"
        case .toggleDND(let enable):
            return "[SHORTCUT:TOGGLE_DND:\(enable)]"
        case .createReminder(let text):
            let sanitized = text.replacingOccurrences(of: "]", with: "")
            return "[SHORTCUT:CREATE_REMINDER:\(sanitized)]"
        }
    }

    private func parseMinutes(from text: String) -> Int {
        // Extract number from "set timer for 10 minutes"
        let words = text.split(separator: " ")
        for (index, word) in words.enumerated() {
            if let num = Int(word) {
                return num
            }
        }
        return 5  // default to 5 minutes
    }

    private func extractReminderText(from text: String) -> String {
        // Extract "pick up milk" from "remind me to pick up milk"
        let lower = text.lowercased()
        if let range = lower.range(of: "remind me to ") {
            return String(text[range.upperBound...])
        }
        if let range = lower.range(of: "create reminder ") {
            return String(text[range.upperBound...])
        }
        if let range = lower.range(of: "add reminder ") {
            return String(text[range.upperBound...])
        }
        return text
    }

    private func extractCity(from text: String) -> String {
        // Extract "Chicago" from "weather in Chicago"
        if let range = text.range(of: " in ") {
            return String(text[range.upperBound...]).trimmingCharacters(in: .whitespaces)
        }
        return ""
    }

    private func getTimeInLocation(_ location: String) -> String {
        // Map common city names to timezone identifiers
        let timezoneMap: [String: String] = [
            "london": "Europe/London",
            "paris": "Europe/Paris",
            "tokyo": "Asia/Tokyo",
            "new york": "America/New_York",
            "los angeles": "America/Los_Angeles",
            "chicago": "America/Chicago",
            "denver": "America/Denver",
            "sydney": "Australia/Sydney",
            "mumbai": "Asia/Kolkata",
            "beijing": "Asia/Shanghai",
            "dubai": "Asia/Dubai",
            "toronto": "America/Toronto",
            "vancouver": "America/Vancouver",
            "berlin": "Europe/Berlin",
            "moscow": "Europe/Moscow",
            "seoul": "Asia/Seoul",
            "hong kong": "Asia/Hong_Kong",
            "singapore": "Asia/Singapore",
            "bangkok": "Asia/Bangkok"
        ]

        let locationLower = location.lowercased().trimmingCharacters(in: .whitespaces)

        guard let tzIdentifier = timezoneMap[locationLower],
              let timezone = TimeZone(identifier: tzIdentifier) else {
            return "I'm not sure what timezone \(location) is in. Try major cities like London, Tokyo, or New York."
        }

        let formatter = DateFormatter()
        formatter.timeZone = timezone
        formatter.timeStyle = .short
        let time = formatter.string(from: Date())

        return "It's \(time) in \(location)."
    }
}
