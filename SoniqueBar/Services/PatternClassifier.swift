import Foundation
import os.log

/// Fast pattern-based intent classification — no LLM needed for common queries
struct PatternClassifier {

    private static let logger = Logger(subsystem: "com.seayniclabs.soniquebar", category: "PatternClassifier")

    /// Classify intent using regex patterns (fallback to LLM if no match)
    static func classify(_ transcript: String) -> Intent? {
        logger.info("🔍 classify called with: '\(transcript)'")
        let lower = transcript.lowercased()
        logger.info("🔍 lowercased: '\(lower)'")

        // Calendar queries
        if lower.matches(pattern: "(calendar|schedule|meeting|appointment|today|tomorrow)") {
            logger.info("✅ Matched: checkCalendar")
            return .checkCalendar
        }

        // Email queries
        if lower.matches(pattern: "(email|inbox|unread|mail|message)") {
            logger.info("✅ Matched: checkEmail")
            return .checkEmail
        }

        // Screen awareness
        if lower.matches(pattern: "(screen|display|showing|what.s on|what is on)") {
            logger.info("✅ Matched: describeScreen")
            return .describeScreen
        }

        // Time/date queries
        if lower.matches(pattern: "(time|date|day|what.s the|what is the)") {
            logger.info("✅ Matched: currentTime")
            return .currentTime
        }

        // System status
        if lower.matches(pattern: "(status|health|docker|helmsman|queue)") {
            logger.info("✅ Matched: systemStatus")
            return .systemStatus
        }

        // Task creation (needs more context, defer to LLM)
        if lower.matches(pattern: "(create|add|make|new).*(task|reminder|todo)") {
            logger.info("ℹ️ Task creation detected, deferring to LLM")
            return nil  // Let LLM handle context
        }

        // Stop/cancel commands
        if lower.matches(pattern: "^(stop|cancel|nevermind|forget it)") {
            logger.info("✅ Matched: stopAction")
            return .stopAction
        }

        // No pattern match — needs LLM classification
        logger.info("❌ No pattern matched, needs LLM")
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
