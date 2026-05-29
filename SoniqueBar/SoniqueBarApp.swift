import SwiftUI
import AppKit

@main
struct SoniqueBarApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra {
            VStack(alignment: .leading, spacing: 12) {
                // Server status
                HStack {
                    Circle()
                        .fill(appDelegate.commandServer.isRunning ? Color.green : Color.red)
                        .frame(width: 8, height: 8)
                    Text(appDelegate.commandServer.isRunning ? "Online" : "Offline")
                        .font(.caption)
                }

                Divider()

                // Stats
                VStack(alignment: .leading, spacing: 4) {
                    Text("Requests: \(appDelegate.commandServer.requestCount)")
                        .font(.caption)
                    if !appDelegate.commandServer.lastCommand.isEmpty {
                        Text("Last: \(appDelegate.commandServer.lastCommand)")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                    }
                }

                Divider()

                Button("Quit Sonique") {
                    NSApp.terminate(nil)
                }
            }
            .padding()
        } label: {
            Image(systemName: appDelegate.commandServer.isRunning ? "waveform" : "waveform.slash")
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(appDelegate.commandServer.isRunning ? .primary : .red)
        }
        .menuBarExtraStyle(.window)
    }
}

/// Handles app lifecycle and CommandServer startup
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, ObservableObject {
    @Published var commandServer = CommandServer()

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Terminate any older instance
        let me = NSRunningApplication.current
        NSWorkspace.shared.runningApplications
            .filter { $0.bundleIdentifier == me.bundleIdentifier && $0.processIdentifier != me.processIdentifier }
            .forEach { $0.terminate() }

        // Run as menu bar app (no dock icon)
        NSApp.setActivationPolicy(.accessory)

        // Start CommandServer
        Task { @MainActor in
            commandServer.start()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        Task { @MainActor in
            commandServer.stop()
        }
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
    }
}
