import Foundation
import os.log

/// Manages user permissions and access control
final class PermissionManager {
    static let shared = PermissionManager()

    private let logger = Logger(subsystem: "com.seayniclabs.soniquebar", category: "PermissionManager")
    private let configPath = "/Volumes/data/secrets/sonique_users.json"
    private let legacyTokenPath = "/Volumes/data/secrets/sonique_auth_token"

    private var config: UserPermissionsConfig?
    private var lastLoad: Date?

    private init() {
        loadConfig()
    }

    /// Load user permissions from disk
    private func loadConfig() {
        do {
            let data = try Data(contentsOf: URL(fileURLWithPath: configPath))
            config = try JSONDecoder().decode(UserPermissionsConfig.self, from: data)
            lastLoad = Date()
            logger.info("[PermissionManager] Loaded \(self.config?.users.count ?? 0) users")
        } catch {
            logger.warning("[PermissionManager] Config not found, creating default: \(error.localizedDescription)")
            createDefaultConfig()
        }
    }

    /// Create default configuration with Charlie at Level 4
    private func createDefaultConfig() {
        // Read legacy bearer token
        let bearerToken: String
        if let legacyToken = try? String(contentsOfFile: legacyTokenPath, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines) {
            bearerToken = legacyToken
        } else {
            bearerToken = UUID().uuidString
            logger.warning("[PermissionManager] No legacy token found, generated new token")
        }

        // Create Charlie's default user with Level 4
        let charlie = UserPermission(
            name: "Charlie Seay",
            bearerToken: bearerToken,
            accessLevel: .readWriteGlobal,
            allowedReadPaths: [],
            allowedWritePaths: [],
            allowedProjects: [],
            requireConfirmation: .default,
            created: Date(),
            notes: "Primary owner - Level 4 with safety confirmations"
        )

        config = UserPermissionsConfig(users: [charlie])
        saveConfig()
    }

    /// Save configuration to disk
    func saveConfig() {
        guard let config = config else { return }

        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(config)
            try data.write(to: URL(fileURLWithPath: configPath))
            logger.info("[PermissionManager] Saved \(config.users.count) users")
        } catch {
            logger.error("[PermissionManager] Failed to save config: \(error.localizedDescription)")
        }
    }

    /// Get user by bearer token
    func user(for bearerToken: String) -> UserPermission? {
        // Reload if config is older than 60 seconds (hot reload for testing)
        if let lastLoad = lastLoad, Date().timeIntervalSince(lastLoad) > 60 {
            loadConfig()
        }

        return config?.user(for: bearerToken)
    }

    /// Get all users (for settings UI)
    func allUsers() -> [UserPermission] {
        config?.users ?? []
    }

    /// Update user
    func updateUser(_ user: UserPermission) {
        guard var config = config else { return }

        if let index = config.users.firstIndex(where: { $0.id == user.id }) {
            config.users[index] = user
            self.config = config
            saveConfig()
            logger.info("[PermissionManager] Updated user: \(user.name)")
        }
    }

    /// Add new user
    func addUser(_ user: UserPermission) {
        guard var config = config else { return }

        config.users.append(user)
        self.config = config
        saveConfig()
        logger.info("[PermissionManager] Added user: \(user.name)")
    }

    /// Delete user
    func deleteUser(_ user: UserPermission) {
        guard var config = config else { return }

        config.users.removeAll { $0.id == user.id }
        self.config = config
        saveConfig()
        logger.info("[PermissionManager] Deleted user: \(user.name)")
    }

    // MARK: - Permission Checks

    enum OperationType {
        case read(path: String)
        case write(path: String)
        case execute(command: String)
        case createTask(project: String)
        case externalComm
        case spending
        case destructive
    }

    struct PermissionCheckResult {
        let allowed: Bool
        let requiresConfirmation: Bool
        let reason: String?

        static func allow() -> PermissionCheckResult {
            PermissionCheckResult(allowed: true, requiresConfirmation: false, reason: nil)
        }

        static func allowWithConfirmation(reason: String) -> PermissionCheckResult {
            PermissionCheckResult(allowed: true, requiresConfirmation: true, reason: reason)
        }

        static func deny(reason: String) -> PermissionCheckResult {
            PermissionCheckResult(allowed: false, requiresConfirmation: false, reason: reason)
        }
    }

    /// Check if operation is allowed for user
    func checkPermission(user: UserPermission, operation: OperationType) -> PermissionCheckResult {
        switch operation {
        case .read(let path):
            if user.canRead(path: path) {
                return .allow()
            } else {
                return .deny(reason: "You don't have access to \(path)")
            }

        case .write(let path):
            if user.canWrite(path: path) {
                return .allow()
            } else {
                return .deny(reason: "Your access level doesn't permit writing to \(path)")
            }

        case .execute:
            if user.accessLevel.canWrite {
                return .allow()
            } else {
                return .deny(reason: "Your access level doesn't permit executing commands")
            }

        case .createTask(let project):
            if !user.canAccessProject(project) {
                return .deny(reason: "You don't have access to project \(project)")
            }
            if user.accessLevel.canWrite {
                return .allow()
            } else {
                return .deny(reason: "Your access level doesn't permit creating tasks")
            }

        case .externalComm:
            if user.accessLevel.canCommunicateExternal {
                return .allow()
            } else if user.accessLevel.canWriteGlobal && user.requireConfirmation.externalComms {
                return .allowWithConfirmation(reason: "This will send external communication")
            } else {
                return .deny(reason: "Your access level doesn't permit external communications")
            }

        case .spending:
            if user.accessLevel.canSpendMoney {
                return .allow()
            } else if user.accessLevel.canWriteGlobal && user.requireConfirmation.spending {
                return .allowWithConfirmation(reason: "This will cost money")
            } else {
                return .deny(reason: "Your access level doesn't permit operations that cost money")
            }

        case .destructive:
            if user.accessLevel.canWriteGlobal {
                if user.requireConfirmation.destructive {
                    return .allowWithConfirmation(reason: "This is a destructive operation")
                } else {
                    return .allow()
                }
            } else {
                return .deny(reason: "Your access level doesn't permit destructive operations")
            }
        }
    }
}
