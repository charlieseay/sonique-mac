import SwiftUI
import AppKit

@main
struct SoniqueBarApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var monitor = ServerMonitor()

    init() {
        // On first install, register for launch at login (matches the default on in Settings).
        // Only fires once — subsequent launches respect the user's saved preference.
        LaunchAtLoginManager.applyDefault()
    }

    var body: some Scene {
        MenuBarExtra {
            if monitor.settings.isConfigured {
                StatusPopover()
                    .environmentObject(monitor)
                    .environmentObject(monitor.premium)
            } else {
                OnboardingView()
                    .environmentObject(monitor)
            }
        } label: {
            BarLabel(monitor: monitor)
        }
        .onChange(of: appDelegate.isTerminating) { _, terminating in
            if terminating { monitor.sidecarManager.stopSync() }
        }
        .onChange(of: appDelegate.openChatRequested) { _, requested in
            if requested {
                appDelegate.openChatRequested = false
                NSApp.activate(ignoringOtherApps: true)
                // openWindow is not directly accessible here; use notification
                NotificationCenter.default.post(name: .openChatWindow, object: nil)
            }
        }
        .menuBarExtraStyle(.window)

        Window("Sonique Settings", id: "settings") {
            OnboardingView()
                .environmentObject(monitor)
        }
        .windowResizability(.contentSize)

        Window("Chat", id: "chat") {
            ChatView()
                .environmentObject(monitor)
        }
        .windowResizability(.contentSize)
        .defaultPosition(.center)

        Window("About Sonique", id: "about") {
            AboutView()
                .environmentObject(monitor.premium)
        }
        .windowResizability(.contentSize)

        Window("Upgrade Sonique", id: "upgrade") {
            MacUpgradeView()
                .environmentObject(monitor.premium)
        }
        .windowResizability(.contentSize)
    }
}

/// Bridges `applicationWillTerminate` into SwiftUI and registers the global
/// chat hotkey (⌘⌥C) so the chat window can be opened from any context.
final class AppDelegate: NSObject, NSApplicationDelegate, ObservableObject {
    @Published var isTerminating = false
    @Published var openChatRequested = false

    private var hotKeyMonitor: Any?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Restore dock visibility preference (default: hidden — pure menu bar app)
        if UserDefaults.standard.bool(forKey: "showInDock") {
            NSApp.setActivationPolicy(.regular)
        }

        // Global hotkey: ⌘⌥C — opens the Chat window from anywhere
        hotKeyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.modifierFlags.contains([.command, .option]),
                  event.characters?.lowercased() == "c"
            else { return }
            DispatchQueue.main.async { self?.openChatRequested = true }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let monitor = hotKeyMonitor {
            NSEvent.removeMonitor(monitor)
        }
        isTerminating = true
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
    }
}

private struct BarLabel: View {
    @ObservedObject var monitor: ServerMonitor
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Group {
            if let img = monitor.avatarImage {
                Image(nsImage: circularImage(img, size: 18))
                    .resizable()
                    .frame(width: 18, height: 18)
                    .opacity(monitor.isOnline ? 1.0 : 0.4)
            } else {
                Image(systemName: barIcon)
                    .foregroundStyle(barColor)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .openChatWindow)) { _ in
            openWindow(id: "chat")
        }
    }

    private var barIcon: String {
        if monitor.systemControl.isExecuting { return "gearshape.fill" }
        if monitor.hasActiveVoiceSession { return "waveform.circle.fill" }
        return "waveform"
    }

    private var barColor: Color {
        if !monitor.isOnline { return Color(nsColor: .tertiaryLabelColor) }
        if monitor.hasActiveVoiceSession { return Color(red: 0.4, green: 0.3, blue: 0.9) }
        return .primary
    }

    private func circularImage(_ source: NSImage, size: CGFloat) -> NSImage {
        let result = NSImage(size: NSSize(width: size, height: size))
        result.lockFocus()
        NSGraphicsContext.current?.imageInterpolation = .high
        let path = NSBezierPath(ovalIn: NSRect(x: 0, y: 0, width: size, height: size))
        path.addClip()
        source.draw(in: NSRect(x: 0, y: 0, width: size, height: size),
                    from: .zero, operation: .sourceOver, fraction: 1)
        result.unlockFocus()
        return result
    }
}

extension Notification.Name {
    static let openChatWindow = Notification.Name("SoniqueOpenChatWindow")
}
