import Foundation

/// Connector for Docker container management
/// Allows Quinn to check status, restart containers, and query health
struct DockerConnector: ActionConnector {
    let id = UUID()
    let name = "Docker Management"
    let version = "1.0.0"
    let description = "Manage Docker containers on local host"
    let category: ConnectorCategory = .development
    var isEnabled: Bool = true

    /// Docker API endpoint (local socket)
    private let endpoint = "http://localhost:2375"

    var capabilities: [ConnectorCapability] {
        [
            .init(
                name: "list_containers",
                description: "List all Docker containers",
                parameters: [
                    .init(name: "all", type: .boolean, required: false, defaultValue: "true", description: "Show all containers (including stopped)")
                ],
                requiredAuth: .none,
                mutates: false
            ),
            .init(
                name: "get_container",
                description: "Get details of a specific container",
                parameters: [
                    .init(name: "name", type: .string, required: true, description: "Container name")
                ],
                requiredAuth: .none,
                mutates: false
            ),
            .init(
                name: "restart_container",
                description: "Restart a Docker container",
                parameters: [
                    .init(name: "name", type: .string, required: true, description: "Container name to restart")
                ],
                requiredAuth: .none,
                mutates: true
            ),
            .init(
                name: "start_container",
                description: "Start a stopped container",
                parameters: [
                    .init(name: "name", type: .string, required: true, description: "Container name to start")
                ],
                requiredAuth: .none,
                mutates: true
            ),
            .init(
                name: "stop_container",
                description: "Stop a running container",
                parameters: [
                    .init(name: "name", type: .string, required: true, description: "Container name to stop")
                ],
                requiredAuth: .none,
                mutates: true
            ),
            .init(
                name: "health_check",
                description: "Check health status of all containers",
                parameters: [],
                requiredAuth: .none,
                mutates: false
            )
        ]
    }

    // MARK: - Execution

    func execute(_ capability: String, parameters: [String: Any]) async throws -> ConnectorResult {
        switch capability {
        case "list_containers":
            return try await listContainers(parameters)
        case "get_container":
            return try await getContainer(parameters)
        case "restart_container":
            return try await restartContainer(parameters)
        case "start_container":
            return try await startContainer(parameters)
        case "stop_container":
            return try await stopContainer(parameters)
        case "health_check":
            return try await healthCheckContainers()
        default:
            throw ConnectorError.unknownCapability(capability)
        }
    }

    func healthCheck() async -> Bool {
        // Check if Docker API is reachable
        let result = await shell("docker ps > /dev/null 2>&1")
        return result.exitCode == 0
    }

    // MARK: - Private Implementation

    private func listContainers(_ params: [String: Any]) async throws -> ConnectorResult {
        let showAll = params["all"] as? Bool ?? true
        let args = showAll ? "ps -a" : "ps"

        let result = await shell("docker \(args) --format '{{.Names}}\t{{.Status}}\t{{.Image}}'")

        guard result.exitCode == 0 else {
            throw ConnectorError.serviceUnavailable
        }

        // Parse output into structured data
        let lines = result.stdout.components(separatedBy: "\n").filter { !$0.isEmpty }
        var containers: [[String: Any]] = []

        for line in lines {
            let parts = line.components(separatedBy: "\t")
            guard parts.count >= 3 else { continue }

            containers.append([
                "name": parts[0],
                "status": parts[1],
                "image": parts[2]
            ])
        }

        return .success(
            message: "Found \(containers.count) container(s)",
            data: ["containers": containers, "count": containers.count]
        )
    }

    private func getContainer(_ params: [String: Any]) async throws -> ConnectorResult {
        guard let name = params["name"] as? String else {
            throw ConnectorError.missingParameter("name")
        }

        let result = await shell("docker inspect \(name)")

        guard result.exitCode == 0 else {
            throw ConnectorError.invalidResponse("Container '\(name)' not found")
        }

        // Parse JSON output
        if let data = result.stdout.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]],
           let container = json.first {
            return .success(
                message: "Container '\(name)' details",
                data: container
            )
        }

        throw ConnectorError.invalidResponse("Could not parse container details")
    }

    private func restartContainer(_ params: [String: Any]) async throws -> ConnectorResult {
        guard let name = params["name"] as? String else {
            throw ConnectorError.missingParameter("name")
        }

        let result = await shell("docker restart \(name)")

        guard result.exitCode == 0 else {
            throw ConnectorError.serviceUnavailable
        }

        return .success(message: "Container '\(name)' restarted successfully")
    }

    private func startContainer(_ params: [String: Any]) async throws -> ConnectorResult {
        guard let name = params["name"] as? String else {
            throw ConnectorError.missingParameter("name")
        }

        let result = await shell("docker start \(name)")

        guard result.exitCode == 0 else {
            throw ConnectorError.serviceUnavailable
        }

        return .success(message: "Container '\(name)' started successfully")
    }

    private func stopContainer(_ params: [String: Any]) async throws -> ConnectorResult {
        guard let name = params["name"] as? String else {
            throw ConnectorError.missingParameter("name")
        }

        let result = await shell("docker stop \(name)")

        guard result.exitCode == 0 else {
            throw ConnectorError.serviceUnavailable
        }

        return .success(message: "Container '\(name)' stopped successfully")
    }

    private func healthCheckContainers() async throws -> ConnectorResult {
        let result = await shell("docker ps --filter 'health=unhealthy' --format '{{.Names}}'")

        guard result.exitCode == 0 else {
            throw ConnectorError.serviceUnavailable
        }

        let unhealthy = result.stdout.components(separatedBy: "\n").filter { !$0.isEmpty }

        if unhealthy.isEmpty {
            return .success(message: "All containers are healthy")
        } else {
            return .success(
                message: "\(unhealthy.count) unhealthy container(s)",
                data: ["unhealthy": unhealthy]
            )
        }
    }

    // MARK: - Helper

    /// Execute shell command (reuses InfrastructureExecutor pattern)
    private func shell(_ command: String) async -> (stdout: String, stderr: String, exitCode: Int32) {
        let task = Process()
        task.launchPath = "/bin/zsh"
        task.arguments = ["-c", command]

        let outPipe = Pipe()
        let errPipe = Pipe()
        task.standardOutput = outPipe
        task.standardError = errPipe

        do {
            try task.run()
            task.waitUntilExit()

            let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
            let errData = errPipe.fileHandleForReading.readDataToEndOfFile()

            let stdout = String(data: outData, encoding: .utf8) ?? ""
            let stderr = String(data: errData, encoding: .utf8) ?? ""

            return (stdout, stderr, task.terminationStatus)
        } catch {
            return ("", error.localizedDescription, -1)
        }
    }
}
