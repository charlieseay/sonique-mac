import Foundation

enum ContainerState: Equatable {
    case unknown
    case notInstalled
    case daemonDown
    case noProject
    case idle
    case building
    case starting
    case running
    case stopping
    case error(String)

    var label: String {
        switch self {
        case .unknown:          return "Checking..."
        case .notInstalled:     return "Docker not installed"
        case .daemonDown:       return "Docker not running"
        case .noProject:        return "CAAL not found"
        case .idle:             return "Stopped"
        case .building:         return "Building images..."
        case .starting:         return "Starting..."
        case .running:          return "Running"
        case .stopping:         return "Stopping..."
        case .error(let msg):   return msg
        }
    }

    var canStart: Bool {
        switch self { case .idle, .error: return true; default: return false }
    }

    var canStop: Bool { self == .running }

    var isBusy: Bool {
        switch self { case .unknown, .building, .starting, .stopping: return true; default: return false }
    }
}

@MainActor
class ContainerManager: ObservableObject {
    @Published var state: ContainerState = .unknown
    @Published var lanIP: String = ""

    private var dockerPath: String?
    private var monitorTask: Task<Void, Never>?

    func setup(caelDirectory: String) async {
        dockerPath = findDocker()
        guard let docker = dockerPath else { state = .notInstalled; return }

        let (_, infoCode) = await run(docker, ["info"])
        guard infoCode == 0 else { state = .daemonDown; return }

        let dir = expand(caelDirectory)
        guard FileManager.default.fileExists(atPath: dir) else { state = .noProject; return }

        lanIP = await localIP()

        let running = await isStackRunning(docker: docker)
        state = running ? .running : .idle
        startMonitoring(caelDirectory: dir)
    }

    func start(caelDirectory: String) async {
        guard let docker = dockerPath else { return }
        let dir = expand(caelDirectory)
        await writeEnvIfNeeded(directory: dir)

        let (images, _) = await run(docker, ["images", "-q", "caal-agent"])
        state = images.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? .building : .starting

        var args = ["compose", "-f", "docker-compose.apple.yaml", "up", "-d"]
        if state == .building { args.append("--build") }

        let (_, code) = await run(docker, args, directory: dir, capture: false)
        if code == 0 {
            state = .running
            startMonitoring(caelDirectory: dir)
        } else {
            state = .error("Start failed — check Docker")
        }
    }

    func stop(caelDirectory: String) async {
        guard let docker = dockerPath else { return }
        let dir = expand(caelDirectory)
        state = .stopping
        monitorTask?.cancel()
        let (_, code) = await run(docker, ["compose", "-f", "docker-compose.apple.yaml", "down"],
                                   directory: dir, capture: false)
        state = code == 0 ? .idle : .error("Stop failed")
    }

    // MARK: - Private

    private func isStackRunning(docker: String) async -> Bool {
        let (output, code) = await run(docker,
            ["ps", "--filter", "name=caal-frontend", "--filter", "status=running", "-q"])
        return code == 0 && !output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func startMonitoring(caelDirectory: String) {
        monitorTask?.cancel()
        monitorTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(15))
                guard !Task.isCancelled, let docker = dockerPath else { break }
                guard !state.isBusy else { continue }
                let running = await isStackRunning(docker: docker)
                if running {
                    state = .running
                } else if state == .running {
                    state = .idle
                }
            }
        }
    }

    private func findDocker() -> String? {
        let candidates = ["/usr/local/bin/docker", "/opt/homebrew/bin/docker", "/usr/bin/docker"]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    private func localIP() async -> String {
        let (out0, c0) = await run("/usr/sbin/ipconfig", ["getifaddr", "en0"])
        if c0 == 0 {
            let ip = out0.trimmingCharacters(in: .whitespacesAndNewlines)
            if !ip.isEmpty { return ip }
        }
        let (out1, c1) = await run("/usr/sbin/ipconfig", ["getifaddr", "en1"])
        if c1 == 0 {
            let ip = out1.trimmingCharacters(in: .whitespacesAndNewlines)
            if !ip.isEmpty { return ip }
        }
        return "127.0.0.1"
    }

    private func writeEnvIfNeeded(directory: String) async {
        let envPath = "\(directory)/.env"
        guard !FileManager.default.fileExists(atPath: envPath) else { return }
        let ip = await localIP()
        let content = """
            CAAL_HOST_IP=\(ip)
            LIVEKIT_API_KEY=devkey
            LIVEKIT_API_SECRET=secret
            LLM_PROVIDER=ollama
            OLLAMA_HOST=http://host.docker.internal:11434
            OLLAMA_MODEL=ministral-3:8b
            OLLAMA_THINK=false
            TTS_VOICE=af_heart
            TIMEZONE=America/Chicago
            """
        try? content.write(toFile: envPath, atomically: true, encoding: .utf8)
    }

    private func expand(_ path: String) -> String {
        NSString(string: path).expandingTildeInPath
    }

    @discardableResult
    private func run(_ executable: String, _ args: [String],
                     directory: String? = nil, capture: Bool = true) async -> (String, Int32) {
        await withCheckedContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = args
            if let dir = directory {
                process.currentDirectoryURL = URL(fileURLWithPath: dir)
            }
            if capture {
                let pipe = Pipe()
                process.standardOutput = pipe
                process.standardError = pipe
                process.terminationHandler = { p in
                    let data = pipe.fileHandleForReading.readDataToEndOfFile()
                    let output = String(data: data, encoding: .utf8) ?? ""
                    continuation.resume(returning: (output, p.terminationStatus))
                }
            } else {
                process.standardOutput = FileHandle.nullDevice
                process.standardError = FileHandle.nullDevice
                process.terminationHandler = { p in
                    continuation.resume(returning: ("", p.terminationStatus))
                }
            }
            do {
                try process.run()
            } catch {
                continuation.resume(returning: ("", -1))
            }
        }
    }
}
