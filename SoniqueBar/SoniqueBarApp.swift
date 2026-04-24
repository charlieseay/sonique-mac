import SwiftUI
import AppKit

@main
struct SoniqueBarApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var monitor = ServerMonitor()

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
        .menuBarExtraStyle(.window)

        Window("Sonique Settings", id: "settings") {
            OnboardingView()
                .environmentObject(monitor)
        }
        .windowResizability(.contentSize)

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

/// Bridges `applicationWillTerminate` into SwiftUI. SidecarManager listens
/// for `isTerminating` flipping to true and runs its synchronous cleanup
/// (SIGTERM → 5 s → SIGKILL) before the process exits.
final class AppDelegate: NSObject, NSApplicationDelegate, ObservableObject {
    @Published var isTerminating = false

    func applicationWillTerminate(_ notification: Notification) {
        isTerminating = true
        // Give the SwiftUI onChange handler a moment to run synchronously.
        // SidecarManager.stopSync() is bounded (5 s grace + SIGKILL).
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
    }
}

private struct BarLabel: View {
    @ObservedObject var monitor: ServerMonitor

    var body: some View {
        if let img = monitor.avatarImage {
            Image(nsImage: circularImage(img, size: 18))
                .resizable()
                .frame(width: 18, height: 18)
        } else {
            Image(systemName: "waveform")
        }
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
