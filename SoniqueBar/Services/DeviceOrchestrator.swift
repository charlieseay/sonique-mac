import Foundation

/// Multi-device orchestration - shared state, handoff protocol, device routing
@MainActor
class DeviceOrchestrator: ObservableObject {
    static let shared = DeviceOrchestrator()

    @Published private(set) var connectedDevices: [Device] = []
    @Published private(set) var activeHandoff: Handoff?

    // iCloud shared state directory
    private let iCloudDir = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Mobile Documents/iCloud~com~seayniclabs~sonique/Documents/SoniqueProfiles/Desktop")

    private let devicesFile: URL
    private let handoffFile: URL

    private init() {
        devicesFile = iCloudDir.appendingPathComponent("devices.json")
        handoffFile = iCloudDir.appendingPathComponent("handoff.json")

        // Create directory if needed
        try? FileManager.default.createDirectory(
            at: iCloudDir,
            withIntermediateDirectories: true
        )

        loadDevices()
        loadHandoff()

        // Start monitoring for changes
        startMonitoring()
    }

    // MARK: - Device Registration

    /// Register this device
    func registerDevice() {
        let device = Device(
            id: getDeviceID(),
            name: getDeviceName(),
            type: .mac,
            lastSeen: Date(),
            capabilities: getDeviceCapabilities()
        )

        var devices = loadDevicesFromFile()
        devices.removeAll { $0.id == device.id }
        devices.append(device)

        saveDevices(devices)
        connectedDevices = devices
    }

    private func getDeviceID() -> String {
        // Use Mac Mini's hardware UUID
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", "ioreg -d2 -c IOPlatformExpertDevice | awk -F'\"' '/IOPlatformUUID/{print $(NF-1)}'"]

        let pipe = Pipe()
        task.standardOutput = pipe

        do {
            try task.run()
            task.waitUntilExit()

            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            if let output = String(data: data, encoding: .utf8) {
                return output.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
            }
        } catch {
            NSLog("[DeviceOrchestrator] Failed to get device ID: \(error)")
        }

        return "UNKNOWN"
    }

    private func getDeviceName() -> String {
        return Host.current().localizedName ?? "Mac Mini"
    }

    private func getDeviceCapabilities() -> [String] {
        return [
            "docker",
            "git",
            "xcode",
            "homebrew",
            "node",
            "python",
            "ollama",
            "screen_capture",
            "file_system_full"
        ]
    }

    // MARK: - Handoff Protocol

    /// Initiate handoff to another device
    func initiateHandoff(to deviceID: String, context: HandoffContext) {
        let handoff = Handoff(
            id: UUID().uuidString,
            fromDevice: getDeviceID(),
            toDevice: deviceID,
            context: context,
            timestamp: Date(),
            status: .pending
        )

        saveHandoff(handoff)
        activeHandoff = handoff
    }

    /// Accept handoff from another device
    func acceptHandoff(_ handoffID: String) {
        guard var handoff = loadHandoffFromFile(),
              handoff.id == handoffID,
              handoff.toDevice == getDeviceID() else {
            return
        }

        handoff.status = .accepted
        saveHandoff(handoff)
        activeHandoff = handoff
    }

    /// Complete handoff
    func completeHandoff(_ handoffID: String) {
        guard var handoff = loadHandoffFromFile(),
              handoff.id == handoffID else {
            return
        }

        handoff.status = .completed
        saveHandoff(handoff)
        activeHandoff = nil
    }

    // MARK: - Device Routing

    /// Route task to appropriate device
    func routeTask(_ task: String) -> String {
        let devices = loadDevicesFromFile()

        // Parse task requirements
        let requirements = parseTaskRequirements(task)

        // Find best device
        guard let bestDevice = findBestDevice(for: requirements, in: devices) else {
            return "MACMINI"  // Default to Mac Mini
        }

        return bestDevice.name
    }

    private func parseTaskRequirements(_ task: String) -> [String] {
        let lower = task.lowercased()
        var requirements: [String] = []

        if lower.contains("docker") || lower.contains("container") {
            requirements.append("docker")
        }

        if lower.contains("xcode") || lower.contains("build ios") || lower.contains("swift") {
            requirements.append("xcode")
        }

        if lower.contains("git") || lower.contains("commit") || lower.contains("push") {
            requirements.append("git")
        }

        if lower.contains("screenshot") || lower.contains("screen") {
            requirements.append("screen_capture")
        }

        if lower.contains("file") || lower.contains("directory") {
            requirements.append("file_system_full")
        }

        return requirements
    }

    private func findBestDevice(for requirements: [String], in devices: [Device]) -> Device? {
        // Score each device
        let scored = devices.map { device -> (device: Device, score: Int) in
            let matchingCapabilities = requirements.filter { device.capabilities.contains($0) }
            return (device, matchingCapabilities.count)
        }

        // Return device with highest score
        return scored.max(by: { $0.score < $1.score })?.device
    }

    // MARK: - Shared State Sync

    /// Get shared state value
    func getSharedState(key: String) -> String? {
        let stateFile = iCloudDir.appendingPathComponent("state_\(key).txt")

        guard FileManager.default.fileExists(atPath: stateFile.path) else {
            return nil
        }

        return try? String(contentsOf: stateFile, encoding: .utf8)
    }

    /// Set shared state value
    func setSharedState(key: String, value: String) {
        let stateFile = iCloudDir.appendingPathComponent("state_\(key).txt")
        try? value.write(to: stateFile, atomically: true, encoding: .utf8)
    }

    // MARK: - Monitoring

    private func startMonitoring() {
        // Monitor devices file for changes (other devices registering)
        Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.loadDevices()
            }
        }

        // Monitor handoff file for incoming handoffs
        Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.loadHandoff()
            }
        }

        // Update this device's last seen
        Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.registerDevice()
            }
        }
    }

    // MARK: - Persistence

    private func loadDevices() {
        connectedDevices = loadDevicesFromFile()
    }

    private func loadDevicesFromFile() -> [Device] {
        guard FileManager.default.fileExists(atPath: devicesFile.path) else {
            return []
        }

        do {
            let data = try Data(contentsOf: devicesFile)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try decoder.decode([Device].self, from: data)
        } catch {
            NSLog("[DeviceOrchestrator] Failed to load devices: \(error)")
            return []
        }
    }

    private func saveDevices(_ devices: [Device]) {
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = .prettyPrinted
            let data = try encoder.encode(devices)
            try data.write(to: devicesFile, options: .atomic)
        } catch {
            NSLog("[DeviceOrchestrator] Failed to save devices: \(error)")
        }
    }

    private func loadHandoff() {
        activeHandoff = loadHandoffFromFile()
    }

    private func loadHandoffFromFile() -> Handoff? {
        guard FileManager.default.fileExists(atPath: handoffFile.path) else {
            return nil
        }

        do {
            let data = try Data(contentsOf: handoffFile)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try decoder.decode(Handoff.self, from: data)
        } catch {
            NSLog("[DeviceOrchestrator] Failed to load handoff: \(error)")
            return nil
        }
    }

    private func saveHandoff(_ handoff: Handoff) {
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = .prettyPrinted
            let data = try encoder.encode(handoff)
            try data.write(to: handoffFile, options: .atomic)
        } catch {
            NSLog("[DeviceOrchestrator] Failed to save handoff: \(error)")
        }
    }
}

// MARK: - Models

struct Device: Codable, Identifiable {
    let id: String
    let name: String
    let type: DeviceType
    let lastSeen: Date
    let capabilities: [String]
}

enum DeviceType: String, Codable {
    case mac
    case iPhone
    case iPad
}

struct Handoff: Codable, Identifiable {
    let id: String
    let fromDevice: String
    let toDevice: String
    let context: HandoffContext
    let timestamp: Date
    var status: HandoffStatus
}

struct HandoffContext: Codable {
    let task: String
    let currentState: String?
    let data: [String: String]?
}

enum HandoffStatus: String, Codable {
    case pending
    case accepted
    case completed
    case cancelled
}
