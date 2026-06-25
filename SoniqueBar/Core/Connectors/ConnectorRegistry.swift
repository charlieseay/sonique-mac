import Foundation
import SwiftUI

// MARK: - Configuration System

/// Complete SoniqueBar configuration
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
    var ttsProvider: TTSProvider
    var elevenLabsVoiceID: String?
    var kokoroVoice: String?

    enum VoiceStyle: String, Codable {
        case concise, detailed, casual
    }

    enum TTSProvider: String, Codable {
        case elevenlabs
        case kokoro
        case system
    }

    static let `default` = UserConfig(
        name: "User",
        voiceResponseStyle: .concise,
        defaultLLM: "claude",
        ttsProvider: .kokoro,  // Default to Kokoro (local, fast, free)
        elevenLabsVoiceID: "cgSgspJ2msm6clMCkdW9",  // Jessica (fallback)
        kokoroVoice: "af_bella"  // Best match to Jessica
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

    /// Default Seaynic Labs configuration (backward compatible)
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

// MARK: - Task Management Config

struct TaskManagementConfig: Codable {
    var provider: String
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

// MARK: - Communication Config

struct CommunicationConfig: Codable {
    var provider: String
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

// MARK: - Knowledge Config

struct KnowledgeConfig: Codable {
    var provider: String
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

// MARK: - Container Config

struct ContainerConfig: Codable {
    var provider: String
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

// MARK: - Code Config

struct CodeConfig: Codable {
    var provider: String
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

// MARK: - Home Automation Config

struct HomeAutomationConfig: Codable {
    var provider: String
    var enabled: Bool
    var homeAssistantConfig: HomeAssistantConfig?
}

struct HomeAssistantConfig: Codable {
    var url: String
    var token: String
}

// MARK: - Custom API Config

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
            print("[ConfigManager] Loaded config from \(configPath.path)")
        } else {
            // First run - create default config with Seaynic Labs setup
            self.config = .default
            Self.saveConfig(config, to: configPath)
            print("[ConfigManager] Created default config at \(configPath.path)")
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

    /// Reload config from disk
    func reload() {
        if let loadedConfig = Self.loadConfig(from: configPath) {
            config = loadedConfig
            print("[ConfigManager] Config reloaded")
        }
    }
}

// MARK: - Connector Registry

/// Central registry for all action connectors
/// Manages connector lifecycle, discovery, and execution routing
@MainActor
class ConnectorRegistry: ObservableObject {
    static let shared = ConnectorRegistry()

    /// All registered connectors
    @Published private(set) var connectors: [any ActionConnector] = []

    /// Connectors organized by category
    var connectorsByCategory: [ConnectorCategory: [any ActionConnector]] {
        Dictionary(grouping: connectors, by: { $0.category })
    }

    /// Enabled connectors only
    var enabledConnectors: [any ActionConnector] {
        connectors.filter { $0.isEnabled }
    }

    private init() {
        // Register built-in connectors
        Task {
            await registerBuiltInConnectors()
            await loadUserConnectors()
        }
    }

    // MARK: - Registration

    /// Register a new connector
    func register<T: ActionConnector>(_ connector: T) {
        // Prevent duplicates
        if connectors.contains(where: { $0.id == connector.id }) {
            print("[ConnectorRegistry] Connector already registered: \(connector.name)")
            return
        }

        // Type-erased storage
        connectors.append(connector)
        print("[ConnectorRegistry] Registered connector: \(connector.name) v\(connector.version)")

        // Persist to UserDefaults
        Task {
            await saveConnectors()
        }
    }

    /// Unregister a connector by ID
    func unregister(id: UUID) {
        connectors.removeAll { $0.id == id }

        Task {
            await saveConnectors()
        }
    }

    /// Enable/disable a connector
    func setEnabled(id: UUID, enabled: Bool) {
        if let index = connectors.firstIndex(where: { $0.id == id }) {
            connectors[index].isEnabled = enabled

            Task {
                await saveConnectors()
            }
        }
    }

    // MARK: - Discovery

    /// Find all connectors that provide a specific capability
    /// - Parameter capability: Capability name to search for
    /// - Returns: Array of connectors that provide this capability
    func findByCapability(_ capability: String) -> [any ActionConnector] {
        enabledConnectors.filter { connector in
            connector.capabilities.contains { $0.name == capability }
        }
    }

    /// Find connector by ID
    func findByID(_ id: UUID) -> (any ActionConnector)? {
        connectors.first { $0.id == id }
    }

    /// Find connector by name
    func findByName(_ name: String) -> (any ActionConnector)? {
        connectors.first { $0.name == name }
    }

    /// Get all available capabilities across all connectors
    var allCapabilities: [String] {
        Set(connectors.flatMap { $0.capabilities.map { $0.name } }).sorted()
    }

    // MARK: - Execution

    /// Execute a capability using the first available connector
    /// - Parameters:
    ///   - capability: Capability name
    ///   - parameters: Parameters for the capability
    /// - Returns: Result of the operation
    func execute(capability: String, parameters: [String: Any]) async throws -> ConnectorResult {
        guard let connector = findByCapability(capability).first else {
            throw ConnectorError.unknownCapability(capability)
        }

        // Validate parameters
        let validation = connector.validate(capability: capability, parameters: parameters)
        guard validation.valid else {
            let errors = validation.errors.joined(separator: ", ")
            throw ConnectorError.invalidParameter(capability, expected: "valid parameters", got: errors)
        }

        // Execute
        return try await connector.execute(capability, parameters: parameters)
    }

    /// Execute a capability using a specific connector
    /// - Parameters:
    ///   - capability: Capability name
    ///   - connectorID: ID of the connector to use
    ///   - parameters: Parameters for the capability
    /// - Returns: Result of the operation
    func execute(capability: String, using connectorID: UUID, parameters: [String: Any]) async throws -> ConnectorResult {
        guard let connector = findByID(connectorID) else {
            throw ConnectorError.serviceUnavailable
        }

        guard connector.isEnabled else {
            throw ConnectorError.serviceUnavailable
        }

        return try await connector.execute(capability, parameters: parameters)
    }

    // MARK: - Health Checks

    /// Run health checks on all connectors
    /// - Returns: Dictionary of connector ID to health status
    func healthCheckAll() async -> [UUID: Bool] {
        var results: [UUID: Bool] = [:]

        for connector in connectors {
            let healthy = await connector.healthCheck()
            results[connector.id] = healthy
        }

        return results
    }

    /// Check if a specific connector is healthy
    func healthCheck(id: UUID) async -> Bool {
        guard let connector = findByID(id) else {
            return false
        }

        return await connector.healthCheck()
    }

    // MARK: - Persistence

    /// Save connector configuration to UserDefaults
    private func saveConnectors() async {
        // For now, just save enabled states
        // Full connector serialization would require Codable conformance
        let enabledStates = connectors.reduce(into: [String: Bool]()) { result, connector in
            result[connector.id.uuidString] = connector.isEnabled
        }

        UserDefaults.standard.set(enabledStates, forKey: "connectorEnabledStates")
    }

    /// Load connector configuration from UserDefaults
    private func loadUserConnectors() async {
        guard let enabledStates = UserDefaults.standard.dictionary(forKey: "connectorEnabledStates") as? [String: Bool] else {
            return
        }

        for (idString, enabled) in enabledStates {
            if let id = UUID(uuidString: idString),
               let index = connectors.firstIndex(where: { $0.id == id }) {
                connectors[index].isEnabled = enabled
            }
        }
    }

    // MARK: - Built-in Connectors

    /// Register all built-in connectors using config
    private func registerBuiltInConnectors() async {
        let config = await ConfigManager.shared.config.connectors

        // Task Management
        if let taskConfig = config.taskManagement, taskConfig.enabled {
            if let helmsmanConfig = taskConfig.helmsmanConfig {
                register(HelmsmanConnector(config: helmsmanConfig, enabled: true))
            } else {
                // Fallback to legacy if no config
                register(HelmsmanConnector())
            }
        }

        // Communication
        if let commConfig = config.communication, commConfig.enabled {
            if let slackConfig = commConfig.slackConfig {
                register(SlackConnector(config: slackConfig, enabled: true))
            } else {
                register(SlackConnector())
            }
        }

        // Knowledge
        if let knowledgeConfig = config.knowledge, knowledgeConfig.enabled {
            if let obsidianConfig = knowledgeConfig.obsidianConfig {
                register(ObsidianConnector(config: obsidianConfig, enabled: true))
            } else {
                register(ObsidianConnector())
            }
        }

        // Containers
        if let containerConfig = config.containers, containerConfig.enabled {
            if let dockerConfig = containerConfig.dockerConfig {
                register(DockerConnector(config: dockerConfig, enabled: true))
            } else {
                register(DockerConnector())
            }
        }

        // Code
        if let codeConfig = config.code, codeConfig.enabled {
            if let githubConfig = codeConfig.githubConfig {
                register(GitHubConnector(config: githubConfig, enabled: true))
            } else {
                register(GitHubConnector())
            }
        }

        print("[ConnectorRegistry] Built-in connectors registered: \(connectors.count) total (from config)")
    }

    /// Reload all connectors from config
    func reload() async {
        // Clear current connectors
        connectors.removeAll()

        // Reload config
        await ConfigManager.shared.reload()

        // Re-register from fresh config
        await registerBuiltInConnectors()

        print("[ConnectorRegistry] Reloaded \(connectors.count) connectors from config")
    }
}

// MARK: - Helper Extensions

extension ConnectorCategory {
    /// Icon for this category
    var icon: String {
        switch self {
        case .taskManagement: return "checklist"
        case .homeAutomation: return "homekit"
        case .communication: return "message"
        case .development: return "hammer"
        case .knowledge: return "book"
        case .system: return "gearshape"
        case .custom: return "puzzlepiece"
        }
    }
}
