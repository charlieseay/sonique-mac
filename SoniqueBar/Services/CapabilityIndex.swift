import Foundation

/// Capability Index - Quinn's self-awareness of what she can do
/// This is the source of truth for available tools, native intents, and project mappings
struct CapabilityIndex {

    // MARK: - Native Intents (iOS/macOS local handlers)

    static let nativeIntents: [String: String] = [
        "time": "Current time (local device)",
        "date": "Current date (local device)",
        "day_of_week": "Day of week (local device)",
        "battery": "Battery level (iOS only)",
        "storage": "Storage space (device-specific)",
        "calendar_next": "Next calendar event (iOS EventKit)",
        "weather": "Current weather (iOS WeatherKit - needs location)"
    ]

    // MARK: - MCP Tools (via Claude CLI)

    static let mcpTools: [String: [String]] = [
        "slack": [
            "slack_send_message",
            "slack_read_channel",
            "slack_search_channels",
            "slack_search_users",
            "slack_add_reaction",
            "slack_create_canvas",
            "slack_read_canvas"
        ],
        "google_drive": [
            "search_files",
            "read_file_content",
            "create_file",
            "download_file_content",
            "get_file_metadata",
            "list_recent_files"
        ],
        "canva": [
            "generate_design",
            "create_design_from_brand_template",
            "export_design",
            "get_design_content",
            "search_designs"
        ],
        "chrome_devtools": [
            "navigate_page",
            "take_screenshot",
            "click",
            "fill_form",
            "evaluate_script",
            "get_console_message"
        ]
    ]

    // MARK: - Native Lab Tools (via Claude CLI built-ins)

    static let labTools: [String: String] = [
        "helmsman": "Task queue API at localhost:5682 (query, create, update tasks)",
        "vault": "Read/write Obsidian vault via Read/Write/Bash tools",
        "docker": "Container management via Bash tool (ps, logs, restart)",
        "github": "Repository operations via gh CLI",
        "bash": "Shell command execution (sandboxed)",
        "filesystem": "Read/Write files in trusted paths"
    ]

    // MARK: - System Capabilities (macOS SoniqueBar)

    static let systemCapabilities: [String: String] = [
        "screenshot": "Capture Mac screen via screencapture command",
        "volume": "Control system volume",
        "open_app": "Launch macOS applications",
        "vision": "Analyze screenshots with Claude Vision API"
    ]

    // MARK: - Project → Vault Path Mapping

    static let projectPaths: [String: String] = [
        "Sonique": "Projects/Sonique/",
        "Quinn": "Projects/Sonique/",  // Alias
        "Bridge": "Projects/Bridge/",
        "Hone": "Projects/Hone/",
        "StdOut": "Projects/StdOut/",
        "Helmsman": "Projects/Lab/Apps/n8n-control/",
        "Enchapter": "Projects/Enchapter/",
        "StoryChat": "Projects/Enchapter/",  // Alias
        "charlieseay.com": "Projects/charlieseay.com/",
        "REACT Pro": "Projects/REACT Pro/",
        "Talos": "Projects/Talos/"
    ]

    // MARK: - Query Methods

    /// Generate a natural language summary of available capabilities
    static func generateCapabilitySummary() -> String {
        var summary = "# Quinn's Capabilities\n\n"

        summary += "## Native Intents (Device-Local)\n"
        for (intent, description) in nativeIntents.sorted(by: { $0.key < $1.key }) {
            summary += "- **\(intent)**: \(description)\n"
        }

        summary += "\n## MCP Tools (via Claude CLI)\n"
        for (server, tools) in mcpTools.sorted(by: { $0.key < $1.key }) {
            summary += "- **\(server)**: \(tools.count) tools\n"
        }

        summary += "\n## Lab Tools\n"
        for (tool, description) in labTools.sorted(by: { $0.key < $1.key }) {
            summary += "- **\(tool)**: \(description)\n"
        }

        summary += "\n## System Capabilities\n"
        for (capability, description) in systemCapabilities.sorted(by: { $0.key < $1.key }) {
            summary += "- **\(capability)**: \(description)\n"
        }

        summary += "\n## Known Projects\n"
        for (project, path) in projectPaths.sorted(by: { $0.key < $1.key }) {
            summary += "- **\(project)**: `\(path)`\n"
        }

        return summary
    }

    /// Check if a project is known and return its vault path
    static func vaultPath(for projectName: String) -> String? {
        // Case-insensitive lookup
        let normalized = projectName.lowercased()
        return projectPaths.first { $0.key.lowercased() == normalized }?.value
    }

    /// Detect if a query is asking about capabilities
    static func isCapabilityQuery(_ text: String) -> Bool {
        let lower = text.lowercased()
        let patterns = [
            "what can you do",
            "what tools",
            "what capabilities",
            "what are you able to",
            "list your tools",
            "what do you have access to"
        ]
        return patterns.contains { lower.contains($0) }
    }

    /// Detect if a query is asking about a specific project
    static func detectProject(in text: String) -> String? {
        let lower = text.lowercased()

        // Check for explicit project mentions
        for projectName in projectPaths.keys {
            if lower.contains(projectName.lowercased()) {
                return projectName
            }
        }

        return nil
    }
}
