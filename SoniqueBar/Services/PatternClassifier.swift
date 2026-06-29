import Foundation
import os.log

/// Fast pattern-based intent classification — no LLM needed for common queries
struct PatternClassifier {

    private static let logger = Logger(subsystem: "com.seayniclabs.soniquebar", category: "PatternClassifier")

    /// Classify intent using regex patterns (fallback to LLM if no match)
    /// IMPORTANT: Only match VERY specific patterns. Let LLM handle ambiguity and context.
    static func classify(_ transcript: String) -> Intent? {
        logger.info("🔍 classify called with: '\(transcript)'")
        let lower = transcript.lowercased()

        // Time/date queries (very specific phrases only)
        if lower.matches(pattern: "^what.s the (time|date)|^what is the (time|date)|^(time|date)$") {
            logger.info("✅ Matched: currentTime")
            return .currentTime
        }

        // Explicit stop commands (clear user intent to cancel)
        if lower.matches(pattern: "^(stop|cancel|nevermind|forget it)$") {
            logger.info("✅ Matched: stopAction")
            return .stopAction
        }

        // Everything else falls through to LLM for contextual understanding
        // This includes:
        // - "your status" vs "lab status" - let LLM disambiguate based on conversation
        // - Calendar/email - "what's on my calendar" vs "tell me about calendar features"
        // - Screen queries - could be asking about capabilities vs actual screen content
        // - Task creation - needs full context and natural response

        logger.info("❌ No pattern matched, deferring to LLM for context")
        return nil
    }

    enum Intent {
        case currentTime         // "What's the time?" only
        case stopAction          // "Stop" / "Cancel" only
        // Everything else goes to LLM for contextual understanding
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
