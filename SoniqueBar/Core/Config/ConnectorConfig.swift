import Foundation

/// Configuration for all connectors
struct SoniqueBarConfig: Codable {
    var user: UserConfig
    var connectors: ConnectorConfigs

    static let `default` = SoniqueBarConfig(
        user: UserConfig.default,
        connectors: ConnectorConfigs.seaynicLabs
    )
}

/// User preferences
struct UserConfig: Codable {
    var name: String
    var voiceResponseStyle: VoiceStyle
    var defaultLLM: String

    enum VoiceStyle: String, Codable {
        case concise, detailed, casual
    }

    static let `default` = UserConfig(
        name: "User",
        voiceResponseStyle: .concise,
        defaultLLM: "claude"
    )
}

/// All connector configurations
struct ConnectorConfigs: Codable {
    var taskManagement: TaskManagementConfig?
    var communication: CommunicationConfig?
    var knowledge: KnowledgeConfig?
    var containers: ContainerConfig?
    var code: CodeConfig?
    var homeAutomation: HomeAutomationConfig?

    /// Default Seaynic Labs configuration
    static let seaynicLabs = ConnectorConfigs(
        taskManagement: TaskManagementConfig(
            provider: "helmsman",
            enabled: true,
            helmsmanConfig: HelmsmanConfig(
                apiURL: "http://localhost:5682",
                webhookURL: "http://localhost:5680/webhook/task-dispatch",
                autoDispatch: true
            )
        ),
        communication: CommunicationConfig(
            provider: "slack",
            enabled: true,
            slackConfig: SlackConfig(
                defaultChannel: "#cael",
                botTokenPath: "/Volumes/data/secrets/slack_bot_token"
            )
        ),
        knowledge: KnowledgeConfig(
            provider: "obsidian",
            enabled: true,
            obsidianConfig: ObsidianConfig(
                vaultPath: "~/Library/Mobile Documents/iCloud~md~obsidian/Documents/SeaynicNet",
                defaultFolder: "Projects"
            )
        ),
        containers: ContainerConfig(
            provider: "docker",
            enabled: true,
            dockerConfig: DockerConfig(
                socket: "/var/run/docker.sock",
                remoteHosts: []
            )
        ),
        code: CodeConfig(
            provider: "github",
            enabled: true,
            githubConfig: GitHubConfig(
                defaultOrg: "charlieseay",
                watchedRepos: ["sonique-mac", "sonique-ios"]
            )
        ),
        homeAutomation: nil  // Optional
    )
}

// MARK: - Task Management

struct TaskManagementConfig: Codable {
    var provider: String  // "helmsman", "todoist", "linear", "github_issues", "custom"
    var enabled: Bool
    var helmsmanConfig: HelmsmanConfig?
    var todoistConfig: TodoistConfig?
    var linearConfig: LinearConfig?
    var customConfig: CustomAPIConfig?
}

struct HelmsmanConfig: Codable {
    var apiURL: String
    var webhookURL: String
    var autoDispatch: Bool
}

struct TodoistConfig: Codable {
    var apiToken: String
    var defaultProject: String?
}

struct LinearConfig: Codable {
    var apiKey: String
    var teamId: String
    var defaultProject: String?
}

// MARK: - Communication

struct CommunicationConfig: Codable {
    var provider: String  // "slack", "discord", "teams", "telegram"
    var enabled: Bool
    var slackConfig: SlackConfig?
    var discordConfig: DiscordConfig?
}

struct SlackConfig: Codable {
    var defaultChannel: String
    var botTokenPath: String
}

struct DiscordConfig: Codable {
    var botToken: String
    var defaultGuildId: String
    var defaultChannelId: String
}

// MARK: - Knowledge

struct KnowledgeConfig: Codable {
    var provider: String  // "obsidian", "notion", "local"
    var enabled: Bool
    var obsidianConfig: ObsidianConfig?
    var notionConfig: NotionConfig?
}

struct ObsidianConfig: Codable {
    var vaultPath: String
    var defaultFolder: String
}

struct NotionConfig: Codable {
    var apiToken: String
    var databaseId: String
}

// MARK: - Containers

struct ContainerConfig: Codable {
    var provider: String  // "docker", "kubernetes", "podman"
    var enabled: Bool
    var dockerConfig: DockerConfig?
    var kubernetesConfig: KubernetesConfig?
}

struct DockerConfig: Codable {
    var socket: String
    var remoteHosts: [String]
}

struct KubernetesConfig: Codable {
    var context: String
    var namespace: String
}

// MARK: - Code

struct CodeConfig: Codable {
    var provider: String  // "github", "gitlab", "bitbucket"
    var enabled: Bool
    var githubConfig: GitHubConfig?
    var gitlabConfig: GitLabConfig?
}

struct GitHubConfig: Codable {
    var defaultOrg: String
    var watchedRepos: [String]
}

struct GitLabConfig: Codable {
    var baseURL: String
    var apiToken: String
    var defaultGroup: String
}

// MARK: - Home Automation

struct HomeAutomationConfig: Codable {
    var provider: String  // "homeassistant", "homekit"
    var enabled: Bool
    var homeAssistantConfig: HomeAssistantConfig?
}

struct HomeAssistantConfig: Codable {
    var url: String
    var token: String
}

// MARK: - Custom API

struct CustomAPIConfig: Codable {
    var baseURL: String
    var authHeader: String?
    var endpoints: [String: String]
}

// MARK: - Config Manager

@MainActor
class ConfigManager: ObservableObject {
    static let shared = ConfigManager()

    @Published var config: SoniqueBarConfig

    private let configPath: URL

    private init() {
        // Config path: ~/Library/Application Support/SoniqueBar/config.json
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let soniqueDir = appSupport.appendingPathComponent("SoniqueBar")
        self.configPath = soniqueDir.appendingPathComponent("config.json")

        // Create directory if needed
        try? FileManager.default.createDirectory(at: soniqueDir, withIntermediateDirectories: true)

        // Load config or use default
        if let loadedConfig = Self.loadConfig(from: configPath) {
            self.config = loadedConfig
        } else {
            // First run - create default config with Seaynic Labs setup
            self.config = .default
            Self.saveConfig(config, to: configPath)
        }
    }

    /// Load config from disk
    private static func loadConfig(from url: URL) -> SoniqueBarConfig? {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return nil
        }

        do {
            let data = try Data(contentsOf: url)
            let decoder = JSONDecoder()
            decoder.keyDecodingStrategy = .convertFromSnakeCase
            return try decoder.decode(SoniqueBarConfig.self, from: data)
        } catch {
            print("[ConfigManager] Failed to load config: \(error)")
            return nil
        }
    }

    /// Save config to disk
    private static func saveConfig(_ config: SoniqueBarConfig, to url: URL) {
        do {
            let encoder = JSONEncoder()
            encoder.keyEncodingStrategy = .convertToSnakeCase
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(config)
            try data.write(to: url)
            print("[ConfigManager] Config saved to \(url.path)")
        } catch {
            print("[ConfigManager] Failed to save config: \(error)")
        }
    }

    /// Save current config to disk
    func save() {
        Self.saveConfig(config, to: configPath)
    }

    /// Reset to default config
    func resetToDefault() {
        config = .default
        save()
    }
}
