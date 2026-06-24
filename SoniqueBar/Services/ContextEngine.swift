import Foundation
import AppKit

/// Context awareness engine - understands Charlie's current activity and environment
@MainActor
class ContextEngine: ObservableObject {
    static let shared = ContextEngine()

    @Published private(set) var currentContext: WorkContext = .unknown
    @Published private(set) var activeApplication: String = ""
    @Published private(set) var isUserPresent: Bool = false
    @Published private(set) var timeOfDay: TimeContext = .morning

    private var monitoringTimer: Timer?

    private init() {}

    func startMonitoring() {
        // Update context every 30 seconds
        monitoringTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.updateContext()
            }
        }

        // Initial update
        updateContext()

        print("[ContextEngine] Started monitoring")
    }

    func stopMonitoring() {
        monitoringTimer?.invalidate()
        monitoringTimer = nil

        print("[ContextEngine] Stopped monitoring")
    }

    // MARK: - Context Detection

    private func updateContext() {
        updateActiveApplication()
        updateTimeOfDay()
        updatePresence()
        inferWorkContext()
    }

    private func updateActiveApplication() {
        if let activeApp = NSWorkspace.shared.frontmostApplication {
            activeApplication = activeApp.localizedName ?? "Unknown"
        }
    }

    private func updateTimeOfDay() {
        let hour = Calendar.current.component(.hour, from: Date())

        switch hour {
        case 0..<6:
            timeOfDay = .lateNight
        case 6..<12:
            timeOfDay = .morning
        case 12..<17:
            timeOfDay = .afternoon
        case 17..<22:
            timeOfDay = .evening
        default:
            timeOfDay = .lateNight
        }
    }

    private func updatePresence() {
        // Detect if user is present based on:
        // 1. Recent keyboard/mouse activity
        // 2. Active window changes
        // 3. System idle time

        let idleTime = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .mouseMoved)

        // Consider present if activity in last 5 minutes
        isUserPresent = idleTime < 300
    }

    private func inferWorkContext() {
        // Infer what Charlie is working on based on active apps
        let app = activeApplication.lowercased()

        if app.contains("xcode") || app.contains("vs code") || app.contains("terminal") {
            currentContext = .coding
        } else if app.contains("chrome") || app.contains("safari") || app.contains("firefox") {
            currentContext = .browsing
        } else if app.contains("slack") || app.contains("mail") || app.contains("messages") {
            currentContext = .communication
        } else if app.contains("obsidian") || app.contains("notion") {
            currentContext = .writing
        } else if app.contains("music") || app.contains("spotify") {
            currentContext = .leisure
        } else if !isUserPresent {
            currentContext = .away
        } else {
            currentContext = .unknown
        }
    }

    // MARK: - Context-Aware Helpers

    /// Should Quinn be proactive right now?
    var shouldBeProactive: Bool {
        // Don't interrupt if user is away or in deep focus
        guard isUserPresent else { return false }

        switch currentContext {
        case .coding:
            return false // Don't interrupt during coding
        case .communication:
            return true // Can suggest during communication
        case .browsing, .writing:
            return true // Can be helpful
        case .leisure, .away, .unknown:
            return false
        }
    }

    /// Get greeting based on time of day
    var contextualGreeting: String {
        let name = UserDefaults.standard.string(forKey: "quinn_name") ?? "Sonique"

        switch timeOfDay {
        case .morning:
            return "Good morning"
        case .afternoon:
            return "Good afternoon"
        case .evening:
            return "Good evening"
        case .lateNight:
            return "You're up late"
        }
    }
}

// MARK: - Context Types

enum WorkContext: String {
    case coding
    case writing
    case browsing
    case communication
    case leisure
    case away
    case unknown
}

enum TimeContext {
    case morning
    case afternoon
    case evening
    case lateNight
}
