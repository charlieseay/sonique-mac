import SwiftUI
import AppKit

@main
struct SoniqueBarApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var monitor = ServerMonitor()
    @StateObject private var commandServer = CommandServer()

    init() {
        // Defer SMAppService / keychain work so App init never blocks the main thread
        // (menu bar must attach before first-install registration runs).
        Task { @MainActor in
            LaunchAtLoginManager.applyDefault()
        }
    }

    var body: some Scene {
        MenuBarExtra {
            if monitor.settings.isConfigured {
                StatusPopover()
                    .environmentObject(monitor)
                    .environmentObject(monitor.premium)
                    .environmentObject(commandServer)
                    .onAppear {
                        commandServer.start()
                    }
            } else {
                OnboardingView()
                    .environmentObject(monitor)
                    .onAppear {
                        commandServer.start()
                    }
            }
        } label: {
            BarLabel(monitor: monitor, sidecarManager: monitor.sidecarManager)
        }
        .onChange(of: appDelegate.isTerminating) { _, terminating in
            if terminating {
                commandServer.stop()
                monitor.sidecarManager.stopSync()
            }
        }
        .onChange(of: appDelegate.openChatRequested) { _, requested in
            if requested {
                appDelegate.openChatRequested = false
                if let url = URL(string: "slack://open?channel=C0B3JRFF58V") {
                    NSWorkspace.shared.open(url)
                }
            }
        }
        .menuBarExtraStyle(.window)

        Window("Sonique Settings", id: "settings") {
            OnboardingView()
                .environmentObject(monitor)
                .environmentObject(commandServer)
        }
        .windowResizability(.contentSize)

        Window("Chat", id: "chat") {
            ChatView()
                .environmentObject(monitor)
                .environmentObject(commandServer)
        }
        .windowResizability(.contentSize)
        .defaultPosition(.center)

        Window("About Sonique", id: "about") {
            AboutView()
                .environmentObject(monitor.premium)
                .environmentObject(commandServer)
        }
        .windowResizability(.contentSize)

        Window("Upgrade Sonique", id: "upgrade") {
            MacUpgradeView()
                .environmentObject(monitor.premium)
                .environmentObject(commandServer)
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
    private var commandServer: CommandServer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Terminate any older instance of SoniqueBar so there's never more than one running.
        let me = NSRunningApplication.current
        NSWorkspace.shared.runningApplications
            .filter { $0.bundleIdentifier == me.bundleIdentifier && $0.processIdentifier != me.processIdentifier }
            .forEach { $0.terminate() }

        // Dock vs menu bar: LSUIElement apps must set policy explicitly or the
        // status item can fail to adopt a visible template tint.
        if UserDefaults.standard.bool(forKey: "showInDock") {
            NSApp.setActivationPolicy(.regular)
        } else {
            NSApp.setActivationPolicy(.accessory)
        }

        // Global hotkey: ⌘⌥C — opens the Chat window from anywhere
        hotKeyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.modifierFlags.contains([.command, .option]),
                  event.characters?.lowercased() == "c"
            else { return }
            DispatchQueue.main.async { self?.openChatRequested = true }
        }

        // Start CommandServer
        Task { @MainActor in
            commandServer = CommandServer()
            commandServer?.start()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let monitor = hotKeyMonitor {
            NSEvent.removeMonitor(monitor)
        }
        Task { @MainActor in
            commandServer?.stop()
        }
        isTerminating = true
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
    }
}

private struct BarLabel: View {
    @ObservedObject var monitor: ServerMonitor
    @ObservedObject var sidecarManager: SidecarManager
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Group {
            switch sidecarManager.state {
            case .unpacking, .starting:
                sidecarLoadingIcon
            case .failed:
                Image(systemName: "waveform")
                    .font(.system(size: 14, weight: .medium))
                    .symbolRenderingMode(.monochrome)
                    .foregroundStyle(.orange)
                    .help("Sonique: Voice engine failed — open menu for details")
            default:
                normalIcon
            }
        }
        .frame(minWidth: 22, minHeight: 18)
        .accessibilityLabel("Sonique")
        .onReceive(NotificationCenter.default.publisher(for: .openChatWindow)) { _ in
            if let url = URL(string: "slack://open?channel=C0B3JRFF58V") {
                NSWorkspace.shared.open(url)
            }
        }
    }

    // Native macOS spinner — ProgressView uses AppKit's NSProgressIndicator
    // which works correctly in MenuBarExtra labels; TimelineView(.animation) deadlocks there.
    private var sidecarLoadingIcon: some View {
        ProgressView()
            .progressViewStyle(.circular)
            .controlSize(.regular)
            .tint(.primary)
            .help(sidecarStatusLabel)
    }

    private var sidecarStatusLabel: String {
        switch sidecarManager.state {
        case .unpacking: return "Sonique — Preparing voice engine (first launch takes ~2 min)…"
        case .starting:  return "Sonique — Starting voice services…"
        default:         return "Sonique"
        }
    }

    private var normalIcon: some View {
        Group {
            if let img = monitor.avatarImage {
                Image(nsImage: circularImage(img, size: 18))
                    .resizable()
                    .frame(width: 18, height: 18)
                    .opacity(monitor.isOnline ? 1.0 : 0.55)
            } else {
                Image(systemName: barIcon)
                    .font(.system(size: 14, weight: .medium))
                    .symbolRenderingMode(.monochrome)
                    .foregroundStyle(barColor)
            }
        }
    }

    private var barIcon: String {
        if monitor.systemControl.isExecuting { return "gearshape.fill" }
        if monitor.hasActiveVoiceSession { return "waveform.circle.fill" }
        return "waveform"
    }

    /// Menu bar is often light / high-key: `tertiaryLabelColor` makes SF Symbols
    /// nearly invisible when CAAL is offline — use full label contrast instead.
    private var barColor: Color {
        if !monitor.isOnline { return Color(nsColor: .labelColor) }
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
