import Foundation
import UserNotifications
import AppKit

/// Handles proactive notifications - alerts Sonique can send when things need attention
@MainActor
class NotificationService: ObservableObject {
    static let shared = NotificationService()

    @Published var notificationsEnabled = false

    private init() {
        requestAuthorization()
    }

    /// Request notification permissions
    func requestAuthorization() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { granted, error in
            Task { @MainActor in
                self.notificationsEnabled = granted
                if let error = error {
                    print("[Notifications] Authorization error: \(error)")
                }
            }
        }
    }

    /// Send a notification to Charlie
    func notify(title: String, message: String, priority: Priority = .normal) {
        guard notificationsEnabled else {
            print("[Notifications] Not authorized - skipping: \(title)")
            return
        }

        let content = UNMutableNotificationContent()
        content.title = title
        content.body = message
        content.sound = priority == .critical ? .defaultCritical : .default

        if priority == .critical {
            content.interruptionLevel = .critical
        }

        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil  // Immediate delivery
        )

        UNUserNotificationCenter.current().add(request) { error in
            if let error = error {
                print("[Notifications] Failed to send: \(error)")
            }
        }
    }

    /// Speak an alert via TTS (for critical interruptions)
    func speakAlert(_ text: String) {
        let utterance = NSSpeechSynthesizer()
        utterance.startSpeaking(text)
    }

    enum Priority {
        case low       // Silent notification
        case normal    // Standard sound
        case critical  // Critical sound, breaks through DND
    }
}
