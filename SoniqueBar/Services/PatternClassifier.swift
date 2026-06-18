import Foundation

/// Fast pattern-based intent classification — no LLM needed for common queries
struct PatternClassifier {

    /// Classify intent using regex patterns (fallback to LLM if no match)
    static func classify(_ transcript: String) -> Intent? {
        let lower = transcript.lowercased()

        // Calendar queries
        if lower.contains(regex: /(calendar|schedule|meeting|appointment|today|tomorrow)/) {
            return .checkCalendar
        }

        // Email queries
        if lower.contains(regex: /(email|inbox|unread|mail|message)/) {
            return .checkEmail
        }

        // Screen awareness
        if lower.contains(regex: /(screen|display|showing|what('s| is) on)/) {
            return .describeScreen
        }

        // Time/date queries
        if lower.contains(regex: /(time|date|day|what('s| is) the)/) {
            return .currentTime
        }

        // System status
        if lower.contains(regex: /(status|health|docker|helmsman|queue)/) {
            return .systemStatus
        }

        // Task creation (needs more context, defer to LLM)
        if lower.contains(regex: /(create|add|make|new) .* (task|reminder|todo)/) {
            return nil  // Let LLM handle context
        }

        // Stop/cancel commands
        if lower.contains(regex: /^(stop|cancel|nevermind|forget it)/) {
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
    func contains(regex pattern: Regex<Substring>) -> Bool {
        return self.firstMatch(of: pattern) != nil
    }
}
