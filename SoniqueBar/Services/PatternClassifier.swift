import Foundation

/// Fast pattern-based intent classification — no LLM needed for common queries
struct PatternClassifier {

    /// Classify intent using regex patterns (fallback to LLM if no match)
    static func classify(_ transcript: String) -> Intent? {
        let lower = transcript.lowercased()

        // Calendar queries
        if lower.matches(pattern: "(calendar|schedule|meeting|appointment|today|tomorrow)") {
            return .checkCalendar
        }

        // Email queries
        if lower.matches(pattern: "(email|inbox|unread|mail|message)") {
            return .checkEmail
        }

        // Screen awareness
        if lower.matches(pattern: "(screen|display|showing|what.s on|what is on)") {
            return .describeScreen
        }

        // Time/date queries
        if lower.matches(pattern: "(time|date|day|what.s the|what is the)") {
            return .currentTime
        }

        // System status
        if lower.matches(pattern: "(status|health|docker|helmsman|queue)") {
            return .systemStatus
        }

        // Task creation (needs more context, defer to LLM)
        if lower.matches(pattern: "(create|add|make|new).*(task|reminder|todo)") {
            return nil  // Let LLM handle context
        }

        // Stop/cancel commands
        if lower.matches(pattern: "^(stop|cancel|nevermind|forget it)") {
            return .stopAction
        }

        // No pattern match — needs LLM classification
        return nil
    }

    enum Intent {
        case checkCalendar
        case checkEmail
        case describeScreen
        case currentTime
        case systemStatus
        case stopAction
    }
}

// MARK: - String Regex Extension
extension String {
    func matches(pattern: String) -> Bool {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else {
            return false
        }
        let range = NSRange(location: 0, length: self.utf16.count)
        return regex.firstMatch(in: self, options: [], range: range) != nil
    }
}
