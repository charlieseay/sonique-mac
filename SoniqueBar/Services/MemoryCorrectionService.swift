import Foundation
import os.log

/// Detects and corrects errors in conversation memory, extracting lessons learned
@MainActor
final class MemoryCorrectionService {
    static let shared = MemoryCorrectionService()

    private let logger = Logger(subsystem: "com.seayniclabs.soniquebar", category: "MemoryCorrection")
    private let fm = FileManager.default

    // Paths
    private var conversationsFile: URL {
        let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return appSupport.appendingPathComponent("SoniqueBar/memory/conversations.jsonl")
    }

    private var lessonsDir: URL {
        let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return appSupport.appendingPathComponent("SoniqueBar/memory/lessons")
    }

    private init() {
        try? fm.createDirectory(at: lessonsDir, withIntermediateDirectories: true)
    }

    // MARK: - Detection Patterns

    /// Keywords that indicate Quinn made a factual error
    private let errorIndicators = [
        "actually", "correction:", "that's wrong", "that's incorrect", "mistake",
        "not quite", "that's not right", "incorrect", "my apologies",
        "I was wrong", "let me correct that"
    ]

    /// Keywords that indicate identity/capability errors
    private let identityErrorPatterns = [
        "you are not", "you don't have", "that doesn't exist",
        "that's hallucinated", "that's fabricated", "that's not real"
    ]

    // MARK: - Self-Correction Detection

    /// Check if current response corrects a previous error
    /// Returns: (needsCorrection: Bool, errorContext: String?)
    func detectSelfCorrection(userMessage: String, assistantResponse: String) -> (needsCorrection: Bool, errorContext: String?) {
        let userLower = userMessage.lowercased()
        let responseLower = assistantResponse.lowercased()

        // Check if user is pointing out an error
        let userIndicatesError = errorIndicators.contains { userLower.contains($0) }
        let userIndicatesIdentityError = identityErrorPatterns.contains { userLower.contains($0) }

        // Check if Quinn acknowledges the error
        let quinnAcknowledges = errorIndicators.contains { responseLower.contains($0) }

        if userIndicatesError || userIndicatesIdentityError || quinnAcknowledges {
            // Extract what was wrong
            let context = extractErrorContext(user: userMessage, assistant: assistantResponse)
            return (true, context)
        }

        return (false, nil)
    }

    private func extractErrorContext(user: String, assistant: String) -> String {
        // Simple extraction - look for quoted text or specific claims
        var context = "User correction: \(user.prefix(200))"

        // Try to find what Quinn said that was wrong by looking at recent conversations
        if let wrongStatement = findRecentWrongStatement(correctionHint: user) {
            context += "\nWrong statement: \(wrongStatement)"
        }

        return context
    }

    private func findRecentWrongStatement(correctionHint: String) -> String? {
        // Read last 5 exchanges from conversations.jsonl
        guard let data = try? Data(contentsOf: conversationsFile),
              let content = String(data: data, encoding: .utf8) else {
            return nil
        }

        let lines = content.components(separatedBy: .newlines).filter { !$0.isEmpty }
        let recentLines = lines.suffix(10)  // Last 5 exchanges (user + assistant)

        // Look for assistant responses that might contain the error
        for line in recentLines.reversed() {
            guard let jsonData = line.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
                  let assistant = json["assistant"] as? String else {
                continue
            }

            // Check if this response relates to the correction
            // (simple heuristic: if correction mentions a keyword from the response)
            let correctionLower = correctionHint.lowercased()
            let assistantLower = assistant.lowercased()

            if correctionLower.contains("model") && assistantLower.contains("model") {
                return assistant
            }
            if correctionLower.contains("cli") && assistantLower.contains("cli") {
                return assistant
            }
            if correctionLower.contains("tool") && assistantLower.contains("tool") {
                return assistant
            }
        }

        return nil
    }

    // MARK: - Memory Correction

    /// Redact incorrect information from conversation history
    func redactIncorrectExchange(errorContext: String) {
        guard let data = try? Data(contentsOf: conversationsFile),
              var content = String(data: data, encoding: .utf8) else {
            logger.error("[MemoryCorrection] Could not read conversations.jsonl")
            return
        }

        var lines = content.components(separatedBy: .newlines)
        var redactedCount = 0

        // Find and mark incorrect exchanges
        for i in 0..<lines.count {
            guard !lines[i].isEmpty,
                  let jsonData = lines[i].data(using: .utf8),
                  var json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
                  let assistant = json["assistant"] as? String else {
                continue
            }

            // Check if this exchange contains the error
            if shouldRedact(assistant: assistant, errorContext: errorContext) {
                // Add redaction marker
                json["redacted"] = true
                json["redaction_reason"] = "Self-correction: \(errorContext.prefix(100))"

                if let newJsonData = try? JSONSerialization.data(withJSONObject: json),
                   let newJsonString = String(data: newJsonData, encoding: .utf8) {
                    lines[i] = newJsonString
                    redactedCount += 1
                    logger.info("[MemoryCorrection] Redacted exchange \(i)")
                }
            }
        }

        if redactedCount > 0 {
            // Write back corrected history
            content = lines.joined(separator: "\n")
            try? content.data(using: .utf8)?.write(to: conversationsFile)
            logger.info("[MemoryCorrection] Redacted \(redactedCount) incorrect exchanges")
        }
    }

    private func shouldRedact(assistant: String, errorContext: String) -> Bool {
        let assistantLower = assistant.lowercased()
        let contextLower = errorContext.lowercased()

        // Redact if assistant response contains known false claims
        let falseClaims = [
            "llama3.2", "meta llama", "bart architecture",
            "quinn-native", "no llm capabilities"
        ]

        for claim in falseClaims {
            if assistantLower.contains(claim) {
                logger.info("[MemoryCorrection] Found false claim: \(claim)")
                return true
            }
        }

        return false
    }

    // MARK: - Lesson Extraction

    /// Extract a lesson from the correction and save it
    func extractAndSaveLesson(errorContext: String, correction: String) {
        let lesson = buildLesson(errorContext: errorContext, correction: correction)

        let timestamp = ISO8601DateFormatter().string(from: Date())
        let filename = "self-correction-\(Date().timeIntervalSince1970).md"
        let lessonFile = lessonsDir.appendingPathComponent(filename)

        let markdown = """
        ---
        date: \(timestamp)
        type: self_correction
        category: memory_quality
        ---

        # Self-Correction Lesson

        ## What Went Wrong

        \(errorContext)

        ## Correction

        \(correction)

        ## Root Cause

        \(lesson.rootCause)

        ## Lesson Learned

        \(lesson.learned)

        ## Prevention Strategy

        \(lesson.prevention)

        """

        do {
            try markdown.write(to: lessonFile, atomically: true, encoding: .utf8)
            logger.info("[MemoryCorrection] Saved lesson: \(filename)")

            // Also dispatch to Helmsman for team visibility
            dispatchLessonToHelmsman(lesson: lesson, file: filename)
        } catch {
            logger.error("[MemoryCorrection] Failed to save lesson: \(error.localizedDescription)")
        }
    }

    private func buildLesson(errorContext: String, correction: String) -> (rootCause: String, learned: String, prevention: String) {
        // Analyze what type of error this was
        let contextLower = errorContext.lowercased()

        if contextLower.contains("model") || contextLower.contains("llama") || contextLower.contains("qwen") {
            return (
                rootCause: "Conversation history contained incorrect model identity from previous session using llama3.2:3b. When that history was loaded as context, it poisoned subsequent responses.",
                learned: "Conversation memory can become self-reinforcing if errors aren't corrected. Once Quinn states incorrect information, that incorrect statement gets loaded into future prompts as 'recent conversation', causing her to repeat the error.",
                prevention: "1. Detect when user corrects Quinn's statement\n2. Redact incorrect exchanges from conversations.jsonl\n3. Add explicit identity constraints to IDENTITY.md\n4. Periodically audit conversations.jsonl for known false claims\n5. Clear conversation history when switching models or major config changes"
            )
        } else if contextLower.contains("cli") || contextLower.contains("native") || contextLower.contains("tool") {
            return (
                rootCause: "Quinn hallucinated a tool (quinn-native CLI) that doesn't exist. This false claim then appeared in conversation history, reinforcing the hallucination.",
                learned: "Small local models (llama3.2:3b) tend to fabricate plausible-sounding tools and commands. These hallucinations persist in conversation memory unless explicitly corrected.",
                prevention: "1. Use larger, more accurate models (qwen2.5:14b minimum)\n2. Add explicit 'You do NOT have X' constraints to IDENTITY.md\n3. Detect fabrications by checking tool claims against actual capabilities\n4. Redact fabricated tool references from conversation history"
            )
        } else {
            return (
                rootCause: "General factual error in conversation history.",
                learned: "Quinn's responses can contain errors that persist in memory if not corrected.",
                prevention: "1. Detect user corrections and flag them\n2. Redact incorrect exchanges\n3. Extract lessons from corrections\n4. Update IDENTITY.md/CAPABILITIES.md with explicit constraints"
            )
        }
    }

    private func dispatchLessonToHelmsman(lesson: (rootCause: String, learned: String, prevention: String), file: String) {
        // Create task in Helmsman to review and integrate the lesson
        let taskPayload: [String: Any] = [
            "task": "Review self-correction lesson: \(file)",
            "owner": "CHARLIE",
            "project": "Sonique",
            "effort": "XS",
            "priority": "P3",
            "lane": "research",
            "brief_text": """
            ## Context
            Quinn detected and corrected an error in her own conversation memory.

            ## What Happened
            \(lesson.rootCause)

            ## Lesson
            \(lesson.learned)

            ## Action Taken
            - Redacted incorrect exchanges from conversations.jsonl
            - Saved lesson to memory/lessons/\(file)

            ## Recommended
            \(lesson.prevention)

            ## Next Steps
            Review this lesson and decide if any code changes are needed to prevent similar errors.
            """
        ]

        guard let jsonData = try? JSONSerialization.data(withJSONObject: taskPayload),
              let url = URL(string: "http://localhost:5682/tasks") else {
            logger.error("[MemoryCorrection] Failed to create task payload")
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = jsonData

        URLSession.shared.dataTask(with: request) { data, response, error in
            if let error = error {
                self.logger.error("[MemoryCorrection] Failed to dispatch lesson: \(error.localizedDescription)")
            } else {
                self.logger.info("[MemoryCorrection] Dispatched lesson to Helmsman")
            }
        }.resume()
    }
}
