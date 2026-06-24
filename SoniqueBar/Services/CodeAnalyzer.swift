import Foundation

/// Code understanding - visible code analysis, symbol navigation, git operations
@MainActor
class CodeAnalyzer: ObservableObject {
    static let shared = CodeAnalyzer()

    @Published private(set) var lastAnalysis: String?

    private init() {}

    // MARK: - Visible Code Analysis

    /// Analyze currently visible code in active window
    func analyzeVisibleCode(query: String? = nil) async -> String {
        // Get active window/editor via AppleScript
        guard let activeFile = await getActiveFile() else {
            return "I can't see what code you have open. Make sure Xcode or VSCode is in front."
        }

        // Read the file
        guard let content = try? String(contentsOfFile: activeFile, encoding: .utf8) else {
            return "I couldn't read \(activeFile)"
        }

        // Use ask_claude for code analysis
        let prompt = query ?? "Analyze this code. Explain what it does, identify any issues, and suggest improvements."

        let fullPrompt = """
        \(prompt)

        File: \(activeFile)

        ```
        \(content)
        ```

        Keep your response concise (2-3 sentences for simple queries, 4-5 for complex analysis).
        """

        let result = await InfrastructureExecutor.shell("""
            echo '\(fullPrompt.replacingOccurrences(of: "'", with: "'\\''"))' | ask_claude --model sonnet 2>&1
            """)

        if result.exitCode == 0 && !result.stdout.isEmpty {
            lastAnalysis = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            return lastAnalysis!
        } else {
            return "I couldn't analyze the code: \(result.stderr)"
        }
    }

    /// Get the currently active file path
    func getActiveFile() async -> String? {
        // Try Xcode first
        let xcodeScript = """
        tell application "System Events"
            if exists (process "Xcode") then
                tell process "Xcode"
                    if frontmost then
                        tell application "Xcode"
                            set activeDoc to active workspace document
                            if activeDoc is not missing value then
                                return path of activeDoc
                            end if
                        end tell
                    end if
                end tell
            end if
        end tell
        """

        let xcodeResult = await InfrastructureExecutor.shell(
            "osascript -e '\(xcodeScript.replacingOccurrences(of: "\n", with: " "))' 2>/dev/null"
        )

        if xcodeResult.exitCode == 0 && !xcodeResult.stdout.isEmpty {
            return xcodeResult.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        // Try VSCode
        let vscodeScript = """
        tell application "Visual Studio Code"
            if frontmost then
                tell front window
                    set activeDoc to active document
                    if activeDoc is not missing value then
                        return path of activeDoc
                    end if
                end tell
            end if
        end tell
        """

        let vscodeResult = await InfrastructureExecutor.shell(
            "osascript -e '\(vscodeScript.replacingOccurrences(of: "\n", with: " "))' 2>/dev/null"
        )

        if vscodeResult.exitCode == 0 && !vscodeResult.stdout.isEmpty {
            return vscodeResult.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        return nil
    }

    // MARK: - Symbol Navigation

    /// Find definition of a symbol in the codebase
    func findSymbol(_ symbol: String, in directory: String = "~/Projects") async -> String {
        let expandedDir = NSString(string: directory).expandingTildeInPath

        // Use ripgrep for fast symbol search
        let result = await InfrastructureExecutor.shell("""
            rg --type swift --type-add 'objc:*.{h,m}' --type objc \
               '(func|class|struct|enum|protocol|var|let)\\s+\(symbol)\\b' \
               '\(expandedDir)' \
               -n --heading --color never | head -20
            """)

        if result.exitCode == 0 && !result.stdout.isEmpty {
            let lines = result.stdout.components(separatedBy: "\n").filter { !$0.isEmpty }
            if lines.count > 10 {
                return "Found \(lines.count) definitions. Top matches:\n\(lines.prefix(5).joined(separator: "\n"))"
            } else {
                return lines.joined(separator: "\n")
            }
        } else {
            return "Symbol '\(symbol)' not found in \(directory)"
        }
    }

    /// Find usages of a symbol
    func findUsages(_ symbol: String, in directory: String = "~/Projects") async -> String {
        let expandedDir = NSString(string: directory).expandingTildeInPath

        let result = await InfrastructureExecutor.shell("""
            rg --type swift --type-add 'objc:*.{h,m}' --type objc '\(symbol)' '\(expandedDir)' \
               -n --heading --color never | head -30
            """)

        if result.exitCode == 0 && !result.stdout.isEmpty {
            let lines = result.stdout.components(separatedBy: "\n").filter { !$0.isEmpty }
            let fileCount = Set(lines.compactMap { $0.split(separator: ":").first }).count

            return "Found \(lines.count) usages in \(fileCount) files. Top matches:\n\(lines.prefix(10).joined(separator: "\n"))"
        } else {
            return "No usages of '\(symbol)' found in \(directory)"
        }
    }

    // MARK: - Git Operations

    /// Get current git branch
    func getCurrentBranch(in directory: String = "~/Projects/sonique-mac") async -> String {
        let expandedDir = NSString(string: directory).expandingTildeInPath

        let result = await InfrastructureExecutor.shell(
            "cd '\(expandedDir)' && git branch --show-current 2>/dev/null"
        )

        if result.exitCode == 0 && !result.stdout.isEmpty {
            return result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            return "unknown"
        }
    }

    /// Get uncommitted changes summary
    func getUncommittedChanges(in directory: String = "~/Projects/sonique-mac") async -> String {
        let expandedDir = NSString(string: directory).expandingTildeInPath

        let result = await InfrastructureExecutor.shell(
            "cd '\(expandedDir)' && git status --porcelain 2>/dev/null"
        )

        if result.exitCode == 0 {
            let lines = result.stdout.components(separatedBy: "\n").filter { !$0.isEmpty }
            if lines.isEmpty {
                return "No uncommitted changes"
            } else {
                return "\(lines.count) uncommitted changes"
            }
        } else {
            return "Not a git repository"
        }
    }

    /// Review git diff of uncommitted changes
    func reviewDiff(in directory: String = "~/Projects/sonique-mac") async -> String {
        let expandedDir = NSString(string: directory).expandingTildeInPath

        // Get diff
        let diffResult = await InfrastructureExecutor.shell(
            "cd '\(expandedDir)' && git diff HEAD 2>/dev/null"
        )

        guard diffResult.exitCode == 0 && !diffResult.stdout.isEmpty else {
            return "No uncommitted changes to review"
        }

        // Use ask_claude to review the diff
        let prompt = """
        Review this git diff and provide feedback on:
        1. Code quality and potential issues
        2. Whether it's ready to commit
        3. Suggested improvements (if any)

        Keep your response concise (3-4 sentences).

        ```diff
        \(diffResult.stdout)
        ```
        """

        let result = await InfrastructureExecutor.shell("""
            echo '\(prompt.replacingOccurrences(of: "'", with: "'\\''"))' | ask_claude --model sonnet 2>&1
            """)

        if result.exitCode == 0 && !result.stdout.isEmpty {
            return result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            return "I couldn't review the diff: \(result.stderr)"
        }
    }

    /// Get recent commits
    func getRecentCommits(count: Int = 5, in directory: String = "~/Projects/sonique-mac") async -> String {
        let expandedDir = NSString(string: directory).expandingTildeInPath

        let result = await InfrastructureExecutor.shell(
            "cd '\(expandedDir)' && git log --oneline -\(count) 2>/dev/null"
        )

        if result.exitCode == 0 && !result.stdout.isEmpty {
            return result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            return "No recent commits"
        }
    }

    // MARK: - Contextual Help

    /// Provide contextual help based on visible code
    func getContextualHelp() async -> String {
        guard let activeFile = await getActiveFile() else {
            return "I can't see what you're working on. Make sure Xcode or VSCode is in front."
        }

        // Determine file type and provide relevant tips
        let fileName = (activeFile as NSString).lastPathComponent
        let fileExtension = (activeFile as NSString).pathExtension

        switch fileExtension.lowercased() {
        case "swift":
            return "You're working on \(fileName). I can help with: code analysis, symbol navigation, git operations. Just ask!"

        case "md", "markdown":
            return "You're editing \(fileName). I can help with: formatting, structure, git status. Just ask!"

        case "json", "yaml", "yml":
            return "You're editing \(fileName). I can help with: validation, structure analysis, git diff. Just ask!"

        default:
            return "You're working on \(fileName). I can help with code analysis and git operations. Just ask!"
        }
    }
}
