import Foundation

/// Device context - timezone, location, battery from iOS client
@MainActor
class DeviceContext: ObservableObject {
    static let shared = DeviceContext()

    @Published private(set) var timezone: TimeZone = .current
    @Published private(set) var location: String?
    @Published private(set) var batteryLevel: Float?
    @Published private(set) var isLowPowerMode: Bool = false
    @Published private(set) var lastUpdate: Date?

    // iCloud shared state
    private let iCloudDir = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Mobile Documents/iCloud~com~seayniclabs~sonique/Documents/SoniqueProfiles/Desktop")

    private let contextFile: URL

    private init() {
        contextFile = iCloudDir.appendingPathComponent("device_context.json")

        // Load context
        loadContext()

        // Monitor for updates every 30 seconds
        Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.loadContext()
            }
        }
    }

    // MARK: - Context Loading

    private func loadContext() {
        guard FileManager.default.fileExists(atPath: contextFile.path) else {
            return
        }

        do {
            let data = try Data(contentsOf: contextFile)
            let context = try JSONDecoder().decode(DeviceContextData.self, from: data)

            // Update timezone if different
            if let timezoneIdentifier = context.timezoneIdentifier,
               let tz = TimeZone(identifier: timezoneIdentifier) {
                timezone = tz
            }

            location = context.location
            batteryLevel = context.batteryLevel
            isLowPowerMode = context.isLowPowerMode ?? false
            lastUpdate = context.timestamp

            NSLog("[DeviceContext] Updated: timezone=\(timezone.identifier), location=\(location ?? "unknown"), battery=\(batteryLevel ?? 0)%")
        } catch {
            NSLog("[DeviceContext] Failed to load context: \(error)")
        }
    }

    // MARK: - Helpers

    /// Get current time in device's timezone
    func currentTime() -> Date {
        return Date()
    }

    /// Format date in device's timezone
    func formatDate(_ date: Date, style: DateFormatter.Style = .short) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = style
        formatter.timeZone = timezone
        return formatter.string(from: date)
    }

    /// Format time in device's timezone
    func formatTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "h:mm a"
        formatter.timeZone = timezone
        return formatter.string(from: date)
    }

    /// Get greeting appropriate for time of day in device's timezone
    func getGreeting() -> String {
        let calendar = Calendar.current
        let hour = calendar.component(.hour, from: Date())

        // Adjust for timezone offset
        let currentTZ = TimeZone.current
        let deviceTZ = timezone
        let offset = (deviceTZ.secondsFromGMT() - currentTZ.secondsFromGMT()) / 3600
        let adjustedHour = (hour + offset + 24) % 24

        switch adjustedHour {
        case 5..<12: return "Good morning"
        case 12..<17: return "Good afternoon"
        case 17..<22: return "Good evening"
        default: return "Hello"
        }
    }
}

// MARK: - Models

struct DeviceContextData: Codable {
    let timezoneIdentifier: String?
    let location: String?
    let batteryLevel: Float?
    let isLowPowerMode: Bool?
    let timestamp: Date
}
