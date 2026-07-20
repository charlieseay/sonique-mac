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

    private init() {
        dateFormatter.dateStyle = .medium
        dateFormatter.timeStyle = .short
    }

    /// Attempts to handle query with native intent.
    /// Returns response if handled, nil if should route to LLM.
    func route(_ query: String) async -> String? {
        let lower = query.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)

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

        // Time queries
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

        // Calendar queries
        if matchesPattern(lower, patterns: [
            "what's on my calendar",
            "my calendar today",
            "today's calendar",
            "calendar events",
            "my schedule",
            "what's scheduled"
        ]) {
            return await handleCalendarQuery()
        }

        // Weather (can be extended with native Weather framework on iOS 16+)
        if matchesPattern(lower, patterns: [
            "what's the weather",
            "weather forecast",
            "how's the weather",
            "weather like",
            "what is the weather"
        ]) {
            return "I don't have real-time weather access yet. You can check weather.com or ask me to look it up online if you'd like."
        }

        // System info
        if matchesPattern(lower, patterns: [
            "battery level",
            "battery status",
            "how's my battery"
        ]) {
            return handleBatteryQuery()
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

    private func handleCalendarQuery() async -> String {
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

        // Get today's events
        let startOfDay = calendar.startOfDay(for: Date())
        let endOfDay = calendar.date(byAdding: .day, value: 1, to: startOfDay)!

        let predicate = eventStore.predicateForEvents(
            withStart: startOfDay,
            end: endOfDay,
            calendars: nil
        )
        let events = eventStore.events(matching: predicate)

        if events.isEmpty {
            return "You have no events scheduled for today."
        }

        if events.count == 1 {
            let event = events[0]
            let timeFormatter = DateFormatter()
            timeFormatter.timeStyle = .short
            let time = timeFormatter.string(from: event.startDate)
            return "You have 1 event today: \(event.title ?? "Untitled") at \(time)."
        }

        // Multiple events - summarize
        let eventList = events.prefix(3).map { event in
            let timeFormatter = DateFormatter()
            timeFormatter.timeStyle = .short
            let time = timeFormatter.string(from: event.startDate)
            return "\(event.title ?? "Untitled") at \(time)"
        }.joined(separator: ", ")

        let suffix = events.count > 3 ? ", and \(events.count - 3) more" : ""
        return "You have \(events.count) events today: \(eventList)\(suffix)."
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

    // MARK: - Pattern Matching

    private func matchesPattern(_ query: String, patterns: [String]) -> Bool {
        for pattern in patterns {
            if query.contains(pattern) {
                return true
            }
        }
        return false
    }
}
