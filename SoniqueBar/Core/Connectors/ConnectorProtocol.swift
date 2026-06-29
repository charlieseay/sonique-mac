import Foundation

/// Protocol for external service connectors (task management, home automation, communication, etc.)
/// Connectors are plugins that extend Quinn's capabilities without modifying core code.
protocol ActionConnector: Identifiable, Sendable {
    /// Unique identifier for this connector instance
    var id: UUID { get }

    /// Display name (e.g., "Helmsman Task Dispatch", "Slack", "Docker")
    var name: String { get }

    /// Semantic version
    var version: String { get }

    /// Short description of what this connector does
    var description: String { get }

    /// List of capabilities this connector provides
    var capabilities: [ConnectorCapability] { get }

    /// Category for UI grouping
    var category: ConnectorCategory { get }

    /// Whether this connector is currently enabled
    var isEnabled: Bool { get set }

    /// Execute a capability with the given parameters
    /// - Parameters:
    ///   - capability: Name of the capability to execute
    ///   - parameters: Dictionary of parameters for the capability
    /// - Returns: Result of the operation
    func execute(_ capability: String, parameters: [String: Any]) async -> ConnectorResult

    /// Check if the connector's backend is healthy/reachable
    /// - Returns: True if the connector can currently execute operations
    func healthCheck() async -> Bool

    /// Optional: Validate parameters before execution
    /// - Parameters:
    ///   - capability: Capability to validate for
    ///   - parameters: Parameters to validate
    /// - Returns: Validation result
    func validate(capability: String, parameters: [String: Any]) -> ValidationResult
}

// MARK: - Connector Capability

/// Describes a single capability that a connector provides
struct ConnectorCapability: Identifiable, Codable, Sendable {
    let id: UUID

    /// Capability identifier (e.g., "create_task", "post_message", "restart_container")
    let name: String

    /// Human-readable description
    let description: String

    /// Required parameters for this capability
    let parameters: [CapabilityParameter]

    /// Authentication required to execute this capability
    let requiredAuth: AuthType

    /// Whether this capability modifies state (vs read-only)
    let mutates: Bool

    init(
        name: String,
        description: String,
        parameters: [CapabilityParameter] = [],
        requiredAuth: AuthType = .none,
        mutates: Bool = false
    ) {
        self.id = UUID()
        self.name = name
        self.description = description
        self.parameters = parameters
        self.requiredAuth = requiredAuth
        self.mutates = mutates
    }
}

// MARK: - Capability Parameter

/// Parameter definition for a capability
struct CapabilityParameter: Codable, Sendable {
    /// Parameter name
    let name: String

    /// Parameter type
    let type: ParameterType

    /// Whether this parameter is required
    let required: Bool

    /// Default value (if not required)
    let defaultValue: String?

    /// Description of what this parameter does
    let description: String

    init(
        name: String,
        type: ParameterType,
        required: Bool,
        defaultValue: String? = nil,
        description: String
    ) {
        self.name = name
        self.type = type
        self.required = required
        self.defaultValue = defaultValue
        self.description = description
    }
}

/// Parameter type system
enum ParameterType: Codable, Sendable {
    case string
    case integer
    case boolean
    case enumeration([String])  // List of allowed values
    case url
    case json  // Arbitrary JSON object

    var displayName: String {
        switch self {
        case .string: return "Text"
        case .integer: return "Number"
        case .boolean: return "True/False"
        case .enumeration(let values): return "One of: \(values.joined(separator: ", "))"
        case .url: return "URL"
        case .json: return "JSON Object"
        }
    }
}

// MARK: - Authentication

/// Authentication types supported by connectors
enum AuthType: Codable, Sendable {
    case none
    case bearer(token: String)
    case apiKey(key: String, headerName: String)
    case oauth(token: String)
    case basic(username: String, password: String)
}

// MARK: - Connector Category

/// Categories for organizing connectors in UI
enum ConnectorCategory: String, Codable, Sendable, CaseIterable {
    case taskManagement = "Task Management"
    case homeAutomation = "Home Automation"
    case communication = "Communication"
    case development = "Development"
    case knowledge = "Knowledge"
    case system = "System"
    case custom = "Custom"
}

// MARK: - Connector Result

/// Result of a connector operation
struct ConnectorResult: Sendable {
    /// Whether the operation succeeded
    let success: Bool

    /// Human-readable message
    let message: String

    /// Structured data returned by the operation (optional)
    let data: [String: Any]?

    /// Error details if failed
    let error: String?

    static func success(message: String, data: [String: Any]? = nil) -> ConnectorResult {
        ConnectorResult(success: true, message: message, data: data, error: nil)
    }

    static func failure(error: String) -> ConnectorResult {
        ConnectorResult(success: false, message: "", data: nil, error: error)
    }
}

// MARK: - Validation Result

/// Result of parameter validation
struct ValidationResult: Sendable {
    let valid: Bool
    let errors: [String]

    static let valid = ValidationResult(valid: true, errors: [])

    static func invalid(_ errors: [String]) -> ValidationResult {
        ValidationResult(valid: false, errors: errors)
    }
}

// MARK: - Connector Error

/// Errors that connectors can throw
enum ConnectorError: Error, LocalizedError {
    case unknownCapability(String)
    case missingParameter(String)
    case invalidParameter(String, expected: String, got: String)
    case authenticationFailed
    case connectionFailed
    case rateLimitExceeded
    case serviceUnavailable
    case invalidResponse(String)

    var errorDescription: String? {
        switch self {
        case .unknownCapability(let name):
            return "Unknown capability: \(name)"
        case .missingParameter(let name):
            return "Missing required parameter: \(name)"
        case .invalidParameter(let name, let expected, let got):
            return "Invalid parameter '\(name)': expected \(expected), got \(got)"
        case .authenticationFailed:
            return "Authentication failed"
        case .connectionFailed:
            return "Connection to service failed"
        case .rateLimitExceeded:
            return "Rate limit exceeded, please try again later"
        case .serviceUnavailable:
            return "Service is currently unavailable"
        case .invalidResponse(let message):
            return "Invalid response from service: \(message)"
        }
    }
}

// MARK: - Default Implementation

extension ActionConnector {
    /// Default validation - checks required parameters are present
    func validate(capability: String, parameters: [String: Any]) -> ValidationResult {
        guard let cap = capabilities.first(where: { $0.name == capability }) else {
            return .invalid(["Unknown capability: \(capability)"])
        }

        var errors: [String] = []

        for param in cap.parameters where param.required {
            if parameters[param.name] == nil {
                errors.append("Missing required parameter: \(param.name)")
            }
        }

        return errors.isEmpty ? .valid : .invalid(errors)
    }
}
