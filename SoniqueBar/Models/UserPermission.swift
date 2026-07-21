import Foundation

/// User access levels for Quinn
enum AccessLevel: Int, Codable, CaseIterable, Identifiable {
    case noAccess = 0
    case readOnlyScoped = 1
    case readOnlyGlobal = 2
    case readWriteScoped = 3
    case readWriteGlobal = 4
    case godMode = 5

    var id: Int { rawValue }

    var displayName: String {
        switch self {
        case .noAccess: return "No Access"
        case .readOnlyScoped: return "Read-Only (Scoped)"
        case .readOnlyGlobal: return "Read-Only (Global)"
        case .readWriteScoped: return "Read/Write (Scoped)"
        case .readWriteGlobal: return "Read/Write (Global)"
        case .godMode: return "God Mode"
        }
    }

    var description: String {
        switch self {
        case .noAccess:
            return "Cannot use Quinn"
        case .readOnlyScoped:
            return "Query info, read allowed files only"
        case .readOnlyGlobal:
            return "Query info, read all files"
        case .readWriteScoped:
            return "Read/write in allowed directories, create scoped tasks"
        case .readWriteGlobal:
            return "Read/write all files, create tasks, with confirmations"
        case .godMode:
            return "Full access, no confirmations"
        }
    }

    // Capability checks
    var canRead: Bool { rawValue >= 1 }
    var canReadGlobal: Bool { rawValue >= 2 }
    var canWrite: Bool { rawValue >= 3 }
    var canWriteGlobal: Bool { rawValue >= 4 }
    var canSpendMoney: Bool { rawValue == 5 }
    var canCommunicateExternal: Bool { rawValue == 5 }
}

/// Confirmation requirements for operations
struct ConfirmationRules: Codable, Equatable {
    var externalComms: Bool
    var spending: Bool
    var destructive: Bool

    static let `default` = ConfirmationRules(
        externalComms: true,
        spending: true,
        destructive: true
    )

    static let godMode = ConfirmationRules(
        externalComms: false,
        spending: false,
        destructive: false
    )
}

/// User permission record
struct UserPermission: Codable, Identifiable {
    let id: UUID
    var name: String
    var bearerToken: String
    var accessLevel: AccessLevel
    var allowedReadPaths: [String]
    var allowedWritePaths: [String]
    var allowedProjects: [String]
    var requireConfirmation: ConfirmationRules
    let created: Date
    var notes: String

    init(
        id: UUID = UUID(),
        name: String,
        bearerToken: String,
        accessLevel: AccessLevel,
        allowedReadPaths: [String] = [],
        allowedWritePaths: [String] = [],
        allowedProjects: [String] = [],
        requireConfirmation: ConfirmationRules = .default,
        created: Date = Date(),
        notes: String = ""
    ) {
        self.id = id
        self.name = name
        self.bearerToken = bearerToken
        self.accessLevel = accessLevel
        self.allowedReadPaths = allowedReadPaths
        self.allowedWritePaths = allowedWritePaths
        self.allowedProjects = allowedProjects
        self.requireConfirmation = requireConfirmation
        self.created = created
        self.notes = notes
    }

    /// Check if user can read a specific path
    func canRead(path: String) -> Bool {
        guard canRead else { return false }

        // Global read access
        if accessLevel.canReadGlobal { return true }

        // Scoped read access
        return allowedReadPaths.contains { path.hasPrefix($0) }
    }

    /// Check if user can write to a specific path
    func canWrite(path: String) -> Bool {
        guard canWrite else { return false }

        // Global write access
        if accessLevel.canWriteGlobal { return true }

        // Scoped write access
        return allowedWritePaths.contains { path.hasPrefix($0) }
    }

    /// Check if user can work on a specific project
    func canAccessProject(_ project: String) -> Bool {
        // Global access levels can access all projects
        if accessLevel.canReadGlobal { return true }

        // Scoped access checks allowed projects
        return allowedProjects.isEmpty || allowedProjects.contains(project)
    }
}

/// Container for all user permissions
struct UserPermissionsConfig: Codable {
    var users: [UserPermission]

    func user(for bearerToken: String) -> UserPermission? {
        users.first { $0.bearerToken == bearerToken }
    }
}
