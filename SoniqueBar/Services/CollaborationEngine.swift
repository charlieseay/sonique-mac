import Foundation
import ScreenCaptureKit

/// Real-time collaboration - screen monitoring, live assistance, autonomous refactoring
@MainActor
class CollaborationEngine: ObservableObject {
    static let shared = CollaborationEngine()

    @Published private(set) var isMonitoring = false
    @Published private(set) var lastSuggestion: String?
    @Published private(set) var autonomousMode = false

    private var monitorTimer: Timer?
    private var lastScreenHash: String?
    private var suggestionQueue: [Suggestion] = []

    private init() {}

    // MARK: - Screen Monitoring

    /// Start monitoring screen for changes
    func startMonitoring(interval: TimeInterval = 5.0) {
        guard !isMonitoring else { return }

        isMonitoring = true
        NSLog("[CollaborationEngine] Starting screen monitoring (interval: \(interval)s)")

        monitorTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                await self?.checkScreen()
            }
        }
    }

    /// Stop monitoring
    func stopMonitoring() {
        isMonitoring = false
        monitorTimer?.invalidate()
        monitorTimer = nil

        NSLog("[CollaborationEngine] Stopped screen monitoring")
    }

    private func checkScreen() async {
        // Capture current screen
        guard let screenshot = try? await ScreenAnalyzer.shared.captureScreen() else {
            return
        }

        // Compute hash to detect changes
        guard let hash = try? screenshot.path.md5Hash(),
              hash != lastScreenHash else {
            return  // No change
        }

        lastScreenHash = hash

        // Analyze screen for issues/opportunities
        await analyzeScreenForAssistance(screenshot)
    }

    private func analyzeScreenForAssistance(_ screenshot: URL) async {
        // Use vision to detect context
        do {
            let analysis = try await ScreenAnalyzer.shared.analyzeScreen(
                query: "Identify any errors, warnings, or opportunities for assistance. Be concise."
            )

            // Check if suggestion is actionable
            if analysis.lowercased().contains("error") ||
               analysis.lowercased().contains("warning") ||
               analysis.lowercased().contains("issue") {

                let suggestion = Suggestion(
                    timestamp: Date(),
                    type: .error,
                    message: analysis,
                    actionable: true
                )

                suggestionQueue.append(suggestion)
                lastSuggestion = analysis

                // If autonomous mode, attempt to fix
                if autonomousMode {
                    await attemptAutonomousFix(suggestion)
                }
            }
        } catch {
            NSLog("[CollaborationEngine] Screen analysis failed: \(error)")
        }
    }

    // MARK: - Live Assistance

    /// Get next suggestion from queue
    func getNextSuggestion() -> String? {
        guard !suggestionQueue.isEmpty else {
            return nil
        }

        let suggestion = suggestionQueue.removeFirst()
        return suggestion.message
    }

    /// Provide contextual assistance for current task
    func provideAssistance(for context: String) async -> String {
        let prompt = """
        Charlie is working on: \(context)

        Provide concise, actionable assistance:
        1. What's the next logical step?
        2. Any potential issues to watch for?
        3. Quick tip or best practice

        Keep response under 100 words.
        """

        let result = await InfrastructureExecutor.shell("""
            echo '\(prompt.replacingOccurrences(of: "'", with: "'\\''"))' | ask_claude --model haiku 2>&1
            """)

        if result.exitCode == 0 && !result.stdout.isEmpty {
            return result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            return "I'm here to help. What do you need?"
        }
    }

    // MARK: - Autonomous Refactoring

    /// Attempt autonomous fix for detected issue
    private func attemptAutonomousFix(_ suggestion: Suggestion) async {
        NSLog("[CollaborationEngine] Attempting autonomous fix: \(suggestion.message)")

        // Get current file
        guard let activeFile = await CodeAnalyzer.shared.getActiveFile() else {
            return
        }

        // Use ask_claude to generate fix
        guard let content = try? String(contentsOfFile: activeFile, encoding: .utf8) else {
            return
        }

        let prompt = """
        Fix this issue autonomously:

        Issue: \(suggestion.message)

        Current code:
        ```
        \(content)
        ```

        Provide ONLY the fixed code with no explanation. Output the complete file.
        """

        let result = await InfrastructureExecutor.shell("""
            echo '\(prompt.replacingOccurrences(of: "'", with: "'\\''"))' | ask_claude --model sonnet 2>&1
            """)

        if result.exitCode == 0 && !result.stdout.isEmpty {
            // Extract code block
            let fixedCode = extractCodeBlock(from: result.stdout)

            if !fixedCode.isEmpty {
                // Write fix to file
                try? fixedCode.write(toFile: activeFile, atomically: true, encoding: .utf8)

                NSLog("[CollaborationEngine] ✅ Autonomous fix applied to \(activeFile)")
                lastSuggestion = "Fixed: \(suggestion.message)"
            }
        }
    }

    private func extractCodeBlock(from text: String) -> String {
        // Extract content between ```...```
        let pattern = "```(?:swift|objc)?\\n?(.+?)```"

        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text) else {
            return ""
        }

        return String(text[range])
    }

    /// Enable autonomous refactoring mode
    func enableAutonomousMode() {
        autonomousMode = true
        NSLog("[CollaborationEngine] Autonomous mode enabled")
    }

    /// Disable autonomous refactoring mode
    func disableAutonomousMode() {
        autonomousMode = false
        NSLog("[CollaborationEngine] Autonomous mode disabled")
    }

    // MARK: - Proactive Suggestions

    /// Check for refactoring opportunities in codebase
    func findRefactoringOpportunities(in directory: String = "~/Projects/sonique-mac") async -> String {
        let expandedDir = NSString(string: directory).expandingTildeInPath

        // Use ripgrep to find common code smells
        let patterns = [
            "func.*\\{[^}]{500,}",  // Long functions
            "class.*\\{[^}]{1000,}",  // Large classes
            "if.*if.*if.*if.*if",  // Deep nesting
            "TODO|FIXME|HACK|XXX"  // Tech debt markers
        ]

        var findings: [String] = []

        for pattern in patterns {
            let result = await InfrastructureExecutor.shell("""
                rg '\(pattern)' '\(expandedDir)' -l --type swift 2>/dev/null | head -5
                """)

            if result.exitCode == 0 && !result.stdout.isEmpty {
                let files = result.stdout.components(separatedBy: "\n").filter { !$0.isEmpty }
                if !files.isEmpty {
                    findings.append("\(files.count) files with pattern: \(pattern)")
                }
            }
        }

        if findings.isEmpty {
            return "No obvious refactoring opportunities found"
        } else {
            return "Found opportunities:\n" + findings.joined(separator: "\n")
        }
    }

    // MARK: - Collaborative Code Review

    /// Real-time code review as you type
    func reviewLiveChanges(file: String) async -> String {
        // Get git diff for this file
        let fileDir = (file as NSString).deletingLastPathComponent
        let fileName = (file as NSString).lastPathComponent

        let result = await InfrastructureExecutor.shell("""
            cd '\(fileDir)' && git diff '\(fileName)' 2>/dev/null
            """)

        guard result.exitCode == 0 && !result.stdout.isEmpty else {
            return "No changes to review"
        }

        // Quick review using haiku (fast)
        let prompt = """
        Quick code review of these changes:

        ```diff
        \(result.stdout)
        ```

        Flag only critical issues (bugs, security, logic errors). Keep response under 50 words.
        """

        let reviewResult = await InfrastructureExecutor.shell("""
            echo '\(prompt.replacingOccurrences(of: "'", with: "'\\''"))' | ask_claude --model haiku 2>&1
            """)

        if reviewResult.exitCode == 0 && !reviewResult.stdout.isEmpty {
            return reviewResult.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            return "Review unavailable"
        }
    }
}

// MARK: - Models

struct Suggestion {
    let timestamp: Date
    let type: SuggestionType
    let message: String
    let actionable: Bool
}

enum SuggestionType {
    case error
    case warning
    case improvement
    case refactoring
}

// MARK: - String Extensions

extension String {
    func md5Hash() -> String? {
        guard let data = self.data(using: .utf8) else { return nil }

        let hash = data.withUnsafeBytes { bytes -> String in
            var digest = [UInt8](repeating: 0, count: Int(CC_MD5_DIGEST_LENGTH))
            CC_MD5(bytes.baseAddress, CC_LONG(data.count), &digest)
            return digest.map { String(format: "%02hhx", $0) }.joined()
        }

        return hash
    }
}

// CommonCrypto import
import CommonCrypto
