// SoniqueBar/Services/PatternClassifier.swift (lines 14-25)

        do {
            // Add a timeout to prevent stalls from complex regex on long transcripts.
            // A short timeout is used as pattern matching should be nearly instant. If it stalls,
            // it's better to fail fast and defer to the LLM.
            return try await withTimeout(seconds: 0.1, label: "PatternClassifier.classify") {
                // The regex matching is synchronous, so we wrap it in a Task to allow the timeout to race it.
                await Task {
                    let lower = transcript.lowercased()

                    // ... regex matching calls ...

                }.value
            }
        } catch {
            logger.warning("⚠️ Pattern classification timed out or failed: \(error.localizedDescription)")
            return nil // Fallback to LLM on timeout
        }
