import Foundation
import SwiftUI

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

    /// Register all built-in connectors
    private func registerBuiltInConnectors() async {
        // Task Management
        register(HelmsmanConnector())

        // Development
        register(DockerConnector())

        // Communication
        register(SlackConnector())

        // TODO: Add more built-in connectors as they're implemented
        // Development
        // register(GitHubConnector())

        // Home Automation
        // register(HomeKitConnector())

        // Knowledge
        // register(ObsidianConnector())

        print("[ConnectorRegistry] Built-in connectors registered: \(connectors.count) total")
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
