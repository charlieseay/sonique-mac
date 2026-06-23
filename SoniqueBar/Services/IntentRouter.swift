import Foundation
import os.log
import EventKit

/// Routes user commands to the appropriate handler.
/// Classifies between conversational queries and infrastructure commands.
struct IntentRouter {

    private static let logger = Logger(subsystem: "com.seayniclabs.soniquebar", category: "IntentRouter")
    enum Intent {
        case conversation(text: String)
        case infrastructure(command: InfrastructureCommand)
        case unknown(text: String)
    }

    enum InfrastructureCommand {
        case restartContainer(name: String)
        case checkStatus(service: String)
        case helmsmanQuery(query: String)
        case mcpTool(tool: String, query: String)
        case shellCommand(command: String)
        case openURL(url: String)
        case screenshot(region: ScreenshotRegion)
        case describeScreen  // What's on screen right now
        case checkEmail(query: String)  // Check Apple Mail
        case checkCalendar(query: String)  // Check Calendar events
        case slackMessage(channel: String, text: String)
        case createTask(description: String)
        case createProject(name: String, description: String)
        case createNote(title: String, content: String)
        case homeControl(action: HomeAction, device: String)
        case stopAction  // Stop current operation
        case readVaultFile(path: String)  // Read Standards/ or other vault files
    }

    enum HomeAction {
        case turnOn
        case turnOff
        case toggle
        case setBrightness(Int)
        case setColor(String)
    }

    enum ScreenshotRegion {
        case fullScreen
        case area(x: Int, y: Int, width: Int, height: Int)
    }

    /// Classify the user's text input
    static func classify(_ text: String) -> Intent {
        logger.info("🎯 Classifying input: '\(text)'")
        let lower = text.lowercased()

        // FAST PATH: Pattern-based classification (no LLM, <1ms)
        if let patternIntent = PatternClassifier.classify(text) {
            logger.info("⚡ Pattern matched: \(String(describing: patternIntent))")
            switch patternIntent {
            case .checkCalendar:
                logger.info("➡️ Routing to: checkCalendar")
                return .infrastructure(command: .checkCalendar(query: text))
            case .checkEmail:
                logger.info("➡️ Routing to: checkEmail")
                return .infrastructure(command: .checkEmail(query: text))
            case .describeScreen:
                logger.info("➡️ Routing to: describeScreen")
                return .infrastructure(command: .describeScreen)
            case .currentTime:
                // Handle inline without infrastructure command
                logger.info("➡️ Routing to: fast-path current_time")
                return .conversation(text: "current_time")
            case .systemStatus:
                logger.info("➡️ Routing to: systemStatus")
                return .infrastructure(command: .checkStatus(service: "lab"))
            case .stopAction:
                logger.info("➡️ Routing to: stopAction")
                return .infrastructure(command: .stopAction)
            }
        } else {
            logger.info("🔄 No pattern match, continuing to full classification")
        }

        // Home control (check early - user expects instant response for lights/devices)
        if let homeCommand = classifyHomeControl(text) {
            return .infrastructure(command: homeCommand)
        }

        // Task creation (check first - high priority)
        // Exclude phrases like "the task is already created" or "task is done"
        let isTaskCreationRequest = (lower.contains("create") || lower.contains("add") || lower.contains("new")) &&
                                    (lower.contains("task") || lower.contains("feature") || lower.contains("bug"))
        let isNegation = lower.contains("already") || lower.contains("is created") ||
                        lower.contains("is done") || lower.contains("close") ||
                        lower.contains("delete") || lower.contains("remove")

        if isTaskCreationRequest && !isNegation {
            return .infrastructure(command: .createTask(description: text))
        }

        // Project creation
        if (lower.contains("start") || lower.contains("create") || lower.contains("new")) &&
           lower.contains("project") {
            // Extract project name - simple pattern for now
            let words = text.components(separatedBy: .whitespaces)
            if let projectIndex = words.firstIndex(where: { $0.lowercased() == "project" }),
               projectIndex + 1 < words.count {
                let projectName = words[projectIndex + 1]
                return .infrastructure(command: .createProject(name: projectName, description: text))
            }
        }

        // Slack message to #cael
        if lower.contains("tell the team") || lower.contains("ask the team") {
            let message = text.replacingOccurrences(of: "tell the team", with: "", options: .caseInsensitive)
                             .replacingOccurrences(of: "ask the team", with: "", options: .caseInsensitive)
                             .trimmingCharacters(in: .whitespacesAndNewlines)
            return .infrastructure(command: .slackMessage(channel: "cael", text: message))
        }

        // Docker container operations
        if lower.contains("restart") {
            if let containerName = extractContainerName(from: text) {
                return .infrastructure(command: .restartContainer(name: containerName))
            }
        }

        // Lab status (environment overview)
        if (lower.contains("lab") || lower.contains("environment")) && (lower.contains("status") || lower.contains("state")) {
            return .infrastructure(command: .checkStatus(service: "lab"))
        }

        // Status checks
        if lower.contains("status") || lower.contains("check") {
            if let service = extractServiceName(from: text) {
                return .infrastructure(command: .checkStatus(service: service))
            }
        }

        // Helmsman queries
        if lower.contains("queue") || lower.contains("helmsman") || lower.contains("tasks") {
            return .infrastructure(command: .helmsmanQuery(query: text))
        }

        // Note taking
        // Note creation - only imperative commands, not questions about note-taking
        if (lower.contains("take a note") || lower.contains("create a note") || lower.contains("write a note")) {
            // Skip if this is a question about note-taking rather than an actual command
            let isQuestion = lower.contains("if ") || lower.contains("how ") || lower.contains("where ") ||
                            lower.contains("what ") || lower.contains("when ") || lower.contains("why ") ||
                            lower.contains("?")
            if !isQuestion {
                let noteContent = text.replacingOccurrences(of: "take a note", with: "", options: .caseInsensitive)
                                     .replacingOccurrences(of: "create a note", with: "", options: .caseInsensitive)
                                     .replacingOccurrences(of: "write a note", with: "", options: .caseInsensitive)
                                     .trimmingCharacters(in: .whitespacesAndNewlines)
                return .infrastructure(command: .createNote(title: "Voice Note", content: noteContent))
            }
        }

        // Vault queries (MCP) - only explicit read/search commands
        if (lower.contains("vault") && (lower.contains("search") || lower.contains("find") || lower.contains("read"))) ||
           (lower.contains("read") && lower.contains("note")) ||
           (lower.contains("find") && lower.contains("note")) ||
           (lower.contains("search") && lower.contains("note")) {
            return .infrastructure(command: .mcpTool(tool: "vault", query: text))
        }

        // Shell commands (explicit)
        if lower.starts(with: "run ") || lower.starts(with: "execute ") {
            let cmd = text.replacingOccurrences(of: "run ", with: "")
                          .replacingOccurrences(of: "execute ", with: "")
            return .infrastructure(command: .shellCommand(command: cmd))
        }

        // Open URL in Safari
        if lower.contains("open") && (lower.contains("http") || lower.contains("www.")) {
            if let url = extractURL(from: text) {
                return .infrastructure(command: .openURL(url: url))
            }
        }

        // Email checks - Apple Mail integration
        if (lower.contains("email") || lower.contains("mail")) &&
           (lower.contains("check") || lower.contains("unread") || lower.contains("inbox") ||
            lower.contains("latest") || lower.contains("recent")) {
            return .infrastructure(command: .checkEmail(query: text))
        }

        // Calendar checks
        if (lower.contains("calendar") || lower.contains("meeting") || lower.contains("appointment")) &&
           (lower.contains("check") || lower.contains("today") || lower.contains("tomorrow") ||
            lower.contains("next") || lower.contains("schedule")) {
            return .infrastructure(command: .checkCalendar(query: text))
        }

        // Screen awareness - what's on screen right now
        if lower.contains("what") && (lower.contains("on screen") || lower.contains("on my screen") ||
           lower.contains("see on") || lower.contains("showing")) {
            return .infrastructure(command: .describeScreen)
        }

        // Screenshots intentionally fall through to the agentic/conversational path so it
        // can do SCOPE-AWARE capture (full screen / specific window / region) AND so the
        // artifact-detection in CommandServer can show the image on the device. The old
        // infrastructure .screenshot(fullScreen) path only did full-screen + didn't display.

        // Default: conversational
        return .conversation(text: text)
    }

    private static func extractURL(from text: String) -> String? {
        let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
        let matches = detector?.matches(in: text, range: NSRange(text.startIndex..., in: text))

        if let url = matches?.first?.url?.absoluteString {
            return url
        }

        // Fallback: extract anything starting with http or www
        let words = text.components(separatedBy: .whitespaces)
        for word in words {
            if word.starts(with: "http") || word.starts(with: "www.") {
                return word.starts(with: "www.") ? "https://\(word)" : word
            }
        }

        return nil
    }

    private static func extractContainerName(from text: String) -> String? {
        let lower = text.lowercased()
        let containers = ["n8n", "postgres", "redis", "nginx", "livekit", "kokoro"]

        for container in containers {
            if lower.contains(container) {
                return container
            }
        }

        return nil
    }

    private static func extractServiceName(from text: String) -> String? {
        let lower = text.lowercased()
        let services = ["docker", "n8n", "helmsman", "network", "containers"]

        for service in services {
            if lower.contains(service) {
                return service
            }
        }

        return nil
    }

    private static func classifyHomeControl(_ text: String) -> InfrastructureCommand? {
        let lower = text.lowercased()

        // Check for action keywords
        var action: HomeAction?
        if lower.contains("turn on") || lower.contains("turn the") && lower.contains("on") {
            action = .turnOn
        } else if lower.contains("turn off") || lower.contains("turn the") && lower.contains("off") {
            action = .turnOff
        } else if lower.contains("toggle") {
            action = .toggle
        } else if lower.contains("brightness") || lower.contains("dim") || lower.contains("bright") {
            // Extract percentage if present
            let words = text.components(separatedBy: .whitespaces)
            for word in words {
                if let num = Int(word.trimmingCharacters(in: CharacterSet(charactersIn: "%"))),
                   num >= 0 && num <= 100 {
                    action = .setBrightness(num)
                    break
                }
            }
            if action == nil {
                action = .setBrightness(50) // Default to 50% if no number found
            }
        } else {
            return nil // Not a home control command
        }

        guard let finalAction = action else { return nil }

        // Extract device name (simplified - look for common patterns)
        let devicePatterns = [
            "bedroom light", "bedroom lamp", "bedroom",
            "living room light", "living room lamp", "living room",
            "kitchen light", "kitchen lamp", "kitchen",
            "office light", "office lamp", "office",
            "bathroom light", "bathroom lamp", "bathroom"
        ]

        for pattern in devicePatterns {
            if lower.contains(pattern) {
                // Normalize device name for Home Assistant entity IDs
                let normalized = pattern
                    .replacingOccurrences(of: " light", with: "")
                    .replacingOccurrences(of: " lamp", with: "")
                    .replacingOccurrences(of: " ", with: "_")
                return .homeControl(action: finalAction, device: normalized)
            }
        }

        // Fallback: extract any words that might be a device name
        let words = lower.components(separatedBy: .whitespaces)
            .filter { !["turn", "on", "off", "the", "my", "a", "an", "toggle", "set", "brightness", "to"].contains($0) }
        if !words.isEmpty {
            let device = words.joined(separator: "_")
            return .homeControl(action: finalAction, device: device)
        }

        return nil
    }
}

/// Executes infrastructure commands
struct InfrastructureExecutor {
    /// Execute an infrastructure command and return the result
    static func execute(command: IntentRouter.InfrastructureCommand) async -> String {
        switch command {
        case .restartContainer(let name):
            return await restartDockerContainer(name)

        case .checkStatus(let service):
            return await checkServiceStatus(service)

        case .helmsmanQuery(let query):
            return await queryHelmsman(query)

        case .mcpTool(let tool, let query):
            return await invokeMCPTool(tool, query: query)

        case .shellCommand(let cmd):
            return await runShellCommand(cmd)

        case .openURL(let url):
            return await openInSafari(url)

        case .screenshot(let region):
            return await captureScreenshot(region)

        case .describeScreen:
            return await describeCurrentScreen()

        case .checkEmail(let query):
            return await checkAppleMail(query)

        case .checkCalendar(let query):
            return await checkAppleCalendar(query)

        case .slackMessage(let channel, let text):
            return await sendToSlack(channel, text)

        case .createTask(let description):
            return await createTask(description)

        case .createProject(let name, let description):
            return await createProject(name, description)

        case .createNote(let title, let content):
            return await createNote(title, content)

        case .homeControl(let action, let device):
            return await controlHomeDevice(action: action, device: device)

        case .stopAction:
            return "Okay, I've stopped."

        case .readVaultFile(let path):
            if path.hasPrefix("Standards/") {
                let filename = (path as NSString).lastPathComponent
                if let content = VaultReader.readStandard(filename) {
                    return content
                }
            }
            if let content = VaultReader.readVaultFile(path) {
                return content
            }
            return "File not found: \(path)"
        }
    }

    // MARK: - Docker Operations

    private static func restartDockerContainer(_ name: String) async -> String {
        let result = await shell("docker restart \(name)")

        if result.exitCode == 0 {
            return "Container '\(name)' restarted successfully."
        } else {
            return "Failed to restart '\(name)': \(result.stderr)"
        }
    }

    // MARK: - Status Checks

    private static func checkServiceStatus(_ service: String) async -> String {
        switch service.lowercased() {
        case "lab", "environment":
            return await LabStatusService.shared.getStatus()

        case "docker", "containers":
            let result = await shell("docker ps --format 'table {{.Names}}\t{{.Status}}'")
            return result.exitCode == 0 ? result.stdout : "Failed to check Docker status"

        case "n8n":
            let result = await shell("docker ps --filter name=n8n --format '{{.Status}}'")
            return result.exitCode == 0 ? "n8n: \(result.stdout)" : "n8n is not running"

        case "helmsman":
            // Check Helmsman REST service health
            let result = await shell("curl -s http://localhost:5682/health")
            if result.exitCode == 0, result.stdout.contains("ok") {
                // Get pending count
                let tasks = await shell("curl -s 'http://localhost:5682/tasks?status=pending'")
                if let data = tasks.stdout.data(using: .utf8),
                   let json = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
                    return "Helmsman is running with \(json.count) pending tasks."
                }
                return "Helmsman is running."
            } else {
                return "Helmsman REST service is not reachable."
            }

        default:
            return "Unknown service: \(service)"
        }
    }

    // MARK: - Helmsman Integration

    private static func queryHelmsman(_ query: String) async -> String {
        // Query Helmsman's queue via REST API directly
        if query.lowercased().contains("queue") {
            let result = await shell("curl -s 'http://localhost:5682/tasks?status=pending'")

            if result.exitCode == 0, let data = result.stdout.data(using: .utf8) {
                do {
                    let json = try JSONSerialization.jsonObject(with: data) as? [[String: Any]]
                    let count = json?.count ?? 0

                    if count == 0 {
                        return "Helmsman's queue is empty."
                    } else {
                        let taskList = json?.prefix(5).map { task in
                            let num = task["num"] as? Int ?? 0
                            let title = task["task"] as? String ?? "Unknown"
                            return "#\(num): \(title)"
                        }.joined(separator: "\n") ?? ""

                        return "Helmsman has \(count) pending tasks:\n\(taskList)"
                    }
                } catch {
                    return "Failed to parse queue response: \(error.localizedDescription)"
                }
            } else {
                return "Failed to reach Helmsman REST API (exit code: \(result.exitCode))"
            }
        }

        // For non-queue queries, use ask_helmsman if available
        let which = await shell("which ask_helmsman")
        guard which.exitCode == 0 else {
            return "ask_helmsman not available for this query"
        }

        let result = await shell("ask_helmsman '\(query)'")
        return result.exitCode == 0 ? result.stdout : "Helmsman query failed"
    }

    // MARK: - MCP Tool Integration

    private static func invokeMCPTool(_ tool: String, query: String) async -> String {
        // Native vault search - just grep the markdown files directly
        if tool == "vault" {
            let searchQuery = extractSearchQuery(from: query)
            return await searchVault(query: searchQuery)
        }

        return "MCP tool '\(tool)' not yet implemented"
    }

    private static func searchVault(query: String) async -> String {
        let vaultPath = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Mobile Documents/iCloud~md~obsidian/Documents/SeaynicNet")

        // Use grep to search all markdown files
        let command = """
        grep -ri '\(query)' '\(vaultPath.path)' --include='*.md' | head -5
        """

        let result = await shell(command)

        if result.exitCode == 0 && !result.stdout.isEmpty {
            // Parse results - show file path and matching line
            let lines = result.stdout.components(separatedBy: "\n").filter { !$0.isEmpty }
            var response = "Found \(lines.count) matches:\n\n"

            for (index, line) in lines.prefix(3).enumerated() {
                if let colonIndex = line.firstIndex(of: ":") {
                    let filePath = String(line[..<colonIndex])
                    let fileName = (filePath as NSString).lastPathComponent
                    let content = String(line[line.index(after: colonIndex)...])
                    response += "\(index + 1). \(fileName): \(content.prefix(100))\n"
                }
            }

            return response
        }

        return "No notes found matching '\(query)'"
    }

    private static func extractSearchQuery(from query: String) -> String {
        // Extract search query from queries like "search vault for X" or "find notes about X"
        var cleaned = query.lowercased()

        // Remove common command phrases
        let phrases = ["search", "vault", "for", "find", "notes", "about", "in my", "from"]
        for phrase in phrases {
            cleaned = cleaned.replacingOccurrences(of: phrase, with: "")
        }

        return cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Shell Execution

    private static func runShellCommand(_ command: String) async -> String {
        let result = await shell(command)

        if result.exitCode == 0 {
            return result.stdout.isEmpty ? "Command executed successfully" : result.stdout
        } else {
            return "Command failed: \(result.stderr)"
        }
    }

    // MARK: - Safari Automation

    private static func openInSafari(_ url: String) async -> String {
        let result = await shell("open -a Safari '\(url)'")

        if result.exitCode == 0 {
            return "Opened \(url) in Safari"
        } else {
            return "Failed to open Safari: \(result.stderr)"
        }
    }

    // MARK: - Screenshot Capture

    // MARK: - Calendar Integration

    private static func checkAppleCalendar(_ query: String) async -> String {
        let lower = query.lowercased()

        // Determine timeframe for AppleScript
        let timeframe: String
        if lower.contains("tomorrow") {
            timeframe = "tomorrow"
        } else if lower.contains("week") {
            timeframe = "this week"
        } else {
            timeframe = "today"
        }

        // Use AppleScript to query Calendar (doesn't require explicit Calendar permission with Full Disk Access)
        let script = """
        tell application "Calendar"
            set theDate to current date
            set hours of theDate to 0
            set minutes of theDate to 0
            set seconds of theDate to 0

            set startDate to theDate
            set endDate to theDate + (1 * days)

            if "\(timeframe)" is "tomorrow" then
                set startDate to theDate + (1 * days)
                set endDate to theDate + (2 * days)
            else if "\(timeframe)" is "this week" then
                set endDate to theDate + (7 * days)
            end if

            set eventList to {}
            repeat with cal in calendars
                set calEvents to (every event of cal whose start date ≥ startDate and start date < endDate)
                set eventList to eventList & calEvents
            end repeat

            if (count of eventList) is 0 then
                return "No events"
            end if

            set output to ""
            repeat with evt in eventList
                set eventTitle to summary of evt
                set eventStart to start date of evt
                set eventStartTime to time string of eventStart
                set output to output & eventTitle & " at " & eventStartTime & "\\n"
            end repeat

            return output
        end tell
        """

        let result = await shell("osascript -e '\(script.replacingOccurrences(of: "'", with: "\\'"))'")

        if result.exitCode != 0 {
            return "I couldn't access your calendar: \(result.stderr)"
        }

        let output = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        if output == "No events" {
            return "You have no events \(timeframe)."
        }

        let events = output.components(separatedBy: "\n").filter { !$0.isEmpty }

        let eventCount = events.count
        var summary = eventCount == 1 ? "You have 1 event \(timeframe): " : "You have \(eventCount) events \(timeframe): "

        // Events are already formatted as "Title at Time" from AppleScript
        for event in events.prefix(5) {
            summary += "\(event), "
        }

        if eventCount > 5 {
            summary += "and \(eventCount - 5) more."
        } else {
            summary = String(summary.dropLast(2))  // Remove trailing ", "
        }

        return summary
    }

    // MARK: - Email Integration

    private static func checkAppleMail(_ query: String) async -> String {
        // Use AppleScript to access Apple Mail
        // Optimized: get count first, then only fetch 5 messages
        let script = """
        tell application "Mail"
            set unreadCount to count of (messages of inbox whose read status is false)
            set recentMessages to ""

            if unreadCount > 0 then
                -- Get first 5 unread messages (more efficient than looping all)
                set unreadList to (messages of inbox whose read status is false)
                set msgLimit to 5
                if (count of unreadList) < msgLimit then
                    set msgLimit to (count of unreadList)
                end if

                repeat with i from 1 to msgLimit
                    set msg to item i of unreadList
                    set msgSubject to subject of msg
                    set msgSender to sender of msg
                    set recentMessages to recentMessages & msgSubject & " from " & msgSender & "; "
                end repeat
            end if

            return unreadCount & "|" & recentMessages
        end tell
        """

        let result = await shell("timeout 5 osascript -e '\(script.replacingOccurrences(of: "'", with: "'\\''"))'")

        if result.exitCode == 0 {
            let output = result.stdout
            let parts = output.components(separatedBy: "|")
            if parts.count == 2 {
                let count = parts[0].trimmingCharacters(in: .whitespacesAndNewlines)
                let messages = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)

                if count == "0" {
                    return "You have no unread email."
                } else if messages.isEmpty {
                    return "You have \(count) unread messages."
                } else {
                    return "You have \(count) unread messages. Recent: \(messages)"
                }
            }
            return "Mail check complete: \(output)"
        } else {
            return "Couldn't check Mail: \(result.stderr)"
        }
    }

    // MARK: - Screen Awareness

    @MainActor
    private static func describeCurrentScreen() async -> String {
        // Use live screen capture if available (macOS 12.3+)
        if #available(macOS 12.3, *) {
            // Start capture if not already running
            if !LiveScreenCapture.shared.isCapturing {
                do {
                    try await LiveScreenCapture.shared.startCapture()
                    // Give it a moment to capture first frame
                    try? await Task.sleep(nanoseconds: 600_000_000) // 600ms
                } catch {
                    return "I can't start screen capture right now: \(error.localizedDescription)"
                }
            }

            // Get latest frame
            guard let framePath = LiveScreenCapture.shared.getLatestFrame() else {
                return "Screen capture is running but no frames are available yet. Try again in a moment."
            }

            // Send frame to vision model via vision-describe
            let result = await shell("ANTHROPIC_API_KEY=$(cat /Volumes/data/secrets/anthropic_api_key) ~/.local/bin/vision-describe '\(framePath)' 'Describe what you see on this screen in 2-3 sentences. Focus on the most important content.'")

            if result.exitCode == 0 {
                return result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            } else {
                return "I can see the screen but couldn't analyze it: \(result.stderr)"
            }
        } else {
            // Fallback for older macOS versions
            let timestamp = Int(Date().timeIntervalSince1970)
            let path = "/tmp/sonique-screen-\(timestamp).png"
            let result = await shell("screencapture -x '\(path)' && ANTHROPIC_API_KEY=$(cat /Volumes/data/secrets/anthropic_api_key) ~/.local/bin/vision-describe '\(path)' 'Describe what you see on this screen in 2-3 sentences.'")

            if result.exitCode == 0 {
                return result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            } else {
                return "I can't capture the screen right now: \(result.stderr)"
            }
        }
    }

    private static func captureScreenshot(_ region: IntentRouter.ScreenshotRegion) async -> String {
        // Use screencapture to save screenshot to temp location
        let timestamp = Int(Date().timeIntervalSince1970)
        let path = "/tmp/sonique-screenshot-\(timestamp).png"

        let command: String
        switch region {
        case .fullScreen:
            command = "screencapture -x '\(path)'"
        case .area(let x, let y, let width, let height):
            command = "screencapture -x -R\(x),\(y),\(width),\(height) '\(path)'"
        }

        let result = await shell(command)

        if result.exitCode == 0 {
            // TODO: Send screenshot to iOS app via HTTP POST
            return "Screenshot saved to \(path)"
        } else {
            return "Screenshot failed: \(result.stderr)"
        }
    }

    // MARK: - Slack Integration

    private static func sendToSlack(_ channel: String, _ text: String) async -> String {
        // Post to #cael channel as if Charlie asked
        let message = "Charlie (via Sonique): \(text)".replacingOccurrences(of: "\"", with: "\\\"")
        let command = """
        curl -s -X POST https://slack.com/api/chat.postMessage \
          -H 'Authorization: Bearer '$(cat /Volumes/data/secrets/slack_bot_token) \
          -H 'Content-Type: application/json' \
          -d '{"channel":"\(channel)","text":"\(message)"}'
        """

        let result = await shell(command)

        if result.exitCode == 0, result.stdout.contains("\"ok\":true") {
            return "Posted to #\(channel)"
        } else {
            return "Slack post failed: \(result.stdout)"
        }
    }

    // MARK: - Task Creation

    private static func createTask(_ description: String) async -> String {
        // Extract metadata
        guard let metadata = await TaskDispatcher.extractTaskMetadata(from: description) else {
            return "I couldn't extract task details from that. Can you be more specific about the project, effort level, and what needs to be done?"
        }

        // Generate brief
        let context = await MemoryService.shared.getContextForLLM()
        let brief = TaskDispatcher.generateBrief(from: metadata, context: description)

        // Dispatch
        do {
            let project = metadata.project ?? "General"
            let owner = metadata.owner ?? "AIDER-GEM"

            let taskNum = try await TaskDispatcher.dispatch(
                task: metadata.description,
                owner: owner,
                project: project,
                effort: metadata.effort,
                brief: brief
            )

            return "Created task #\(taskNum): \(metadata.description), \(metadata.effort) effort, assigned to \(owner)"
        } catch {
            return "Failed to create task: \(error.localizedDescription)"
        }
    }

    private static func createProject(_ name: String, _ description: String) async -> String {
        // Create vault folder
        let vaultPath = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Mobile Documents/iCloud~md~obsidian/Documents/SeaynicNet/Projects")
            .appendingPathComponent(name)

        do {
            try FileManager.default.createDirectory(at: vaultPath, withIntermediateDirectories: true)

            // Create initial note
            let dateFormatter = DateFormatter()
            dateFormatter.dateFormat = "yyyy-MM-dd"
            let dateString = dateFormatter.string(from: Date())

            let noteContent = """
            ---
            tags: [projects, \(name.lowercased())]
            created: \(dateString)
            status: planning
            ---

            # \(name)

            \(description)

            ## Status

            Planning phase

            ## Next Steps

            [To be determined]
            """

            let notePath = vaultPath.appendingPathComponent("\(name).md")
            try noteContent.write(to: notePath, atomically: true, encoding: .utf8)

            return "Created project \(name) at \(vaultPath.path). Vault note created."
        } catch {
            return "Failed to create project: \(error.localizedDescription)"
        }
    }

    private static func createNote(_ title: String, _ content: String) async -> String {
        // Create note in Daily Notes or general Notes folder
        let notesPath = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Mobile Documents/iCloud~md~obsidian/Documents/SeaynicNet/Daily Notes")

        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd"
        let dateString = dateFormatter.string(from: Date())

        let timestamp = ISO8601DateFormatter().string(from: Date())

        let noteContent = """
        ## \(title) (\(timestamp))

        \(content)

        ---

        """

        // Append to today's daily note
        let dailyNotePath = notesPath.appendingPathComponent("\(dateString).md")

        do {
            if FileManager.default.fileExists(atPath: dailyNotePath.path) {
                // Append to existing note
                let existingContent = try String(contentsOf: dailyNotePath)
                let updatedContent = existingContent + "\n" + noteContent
                try updatedContent.write(to: dailyNotePath, atomically: true, encoding: .utf8)
            } else {
                // Create new daily note
                let header = """
                ---
                tags: [daily-notes]
                created: \(dateString)
                ---

                # \(dateString)

                """
                try (header + noteContent).write(to: dailyNotePath, atomically: true, encoding: .utf8)
            }

            return "Note added to today's daily note: \(dateString).md"
        } catch {
            return "Failed to create note: \(error.localizedDescription)"
        }
    }

    // MARK: - Home Assistant Control

    private static func controlHomeDevice(action: IntentRouter.HomeAction, device: String) async -> String {
        // Load Home Assistant token
        guard let tokenData = try? Data(contentsOf: URL(fileURLWithPath: "/Volumes/data/secrets/ha_token")),
              let token = String(data: tokenData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) else {
            return "Home Assistant not configured (token missing)"
        }

        // Query Home Assistant for all light entities to fuzzy match the device name
        let entityId: String
        if let matchedEntity = await findMatchingEntity(device: device, token: token) {
            entityId = matchedEntity
            print("[HomeControl] Matched '\(device)' to '\(entityId)'")
        } else {
            // Fallback: try the normalized name directly
            entityId = "light.\(device)"
            print("[HomeControl] No match for '\(device)', using '\(entityId)'")
        }

        print("[HomeControl] Action: \(action), Entity: \(entityId)")

        // Determine service and data payload
        let (service, data): (String, String)
        switch action {
        case .turnOn:
            service = "light/turn_on"
            data = "{\"entity_id\":\"\(entityId)\"}"
        case .turnOff:
            service = "light/turn_off"
            data = "{\"entity_id\":\"\(entityId)\"}"
        case .toggle:
            service = "light/toggle"
            data = "{\"entity_id\":\"\(entityId)\"}"
        case .setBrightness(let pct):
            // Home Assistant brightness is 0-255
            let brightness = Int(Double(pct) / 100.0 * 255.0)
            service = "light/turn_on"
            data = "{\"entity_id\":\"\(entityId)\",\"brightness\":\(brightness)}"
        case .setColor(let color):
            service = "light/turn_on"
            data = "{\"entity_id\":\"\(entityId)\",\"color_name\":\"\(color)\"}"
        }

        // Call Home Assistant REST API
        let url = "http://homeassistant.local:8123/api/services/\(service)"
        let command = """
        curl -s -X POST '\(url)' \
          -H 'Authorization: Bearer \(token)' \
          -H 'Content-Type: application/json' \
          -d '\(data)'
        """

        let result = await shell(command)

        if result.exitCode == 0 {
            // Check if response indicates success (Home Assistant returns array of affected entities)
            if result.stdout.contains("entity_id") || result.stdout.contains("[") {
                return "Done"
            } else {
                return "Home Assistant responded but device may not exist: \(entityId)"
            }
        } else {
            return "Failed to control device: \(result.stderr)"
        }
    }

    private static func findMatchingEntity(device: String, token: String) async -> String? {
        // Query all light entities from Home Assistant with timeout
        let url = "http://homeassistant.local:8123/api/states"
        let command = """
        timeout 2 curl -s -H 'Authorization: Bearer \(token)' '\(url)'
        """

        let result = await shell(command)
        guard result.exitCode == 0,
              let data = result.stdout.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return nil
        }

        // Extract all light entity IDs
        let lights = json.compactMap { state -> String? in
            guard let entityId = state["entity_id"] as? String,
                  entityId.starts(with: "light.") else {
                return nil
            }
            return entityId
        }

        // Fuzzy match: find entity that contains the device keyword
        let deviceLower = device.lowercased()
        for light in lights {
            if light.lowercased().contains(deviceLower) {
                return light
            }
        }

        return nil
    }

    // MARK: - Shell Helper

    static func shell(_ command: String) async -> (stdout: String, stderr: String, exitCode: Int32) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-c", command]

        // Set PATH to include ~/.local/bin and Homebrew for ask_helmsman and other tools
        let homeDir = FileManager.default.homeDirectoryForCurrentUser.path
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "\(homeDir)/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        process.environment = env

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        do {
            try process.run()
            process.waitUntilExit()

            let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
            let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()

            let stdout = String(data: stdoutData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let stderr = String(data: stderrData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

            return (stdout, stderr, process.terminationStatus)
        } catch {
            return ("", error.localizedDescription, -1)
        }
    }
}
