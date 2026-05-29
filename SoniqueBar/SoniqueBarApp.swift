import SwiftUI
import AppKit

@main
struct SoniqueBarApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var commandServer = CommandServer()

    var body: some Scene {
        MenuBarExtra {
            VStack(alignment: .leading, spacing: 12) {
                // Server status
                HStack {
                    Circle()
                        .fill(commandServer.isRunning ? Color.green : Color.red)
                        .frame(width: 8, height: 8)
                    Text(commandServer.isRunning ? "Online" : "Offline")
                        .font(.caption)
                }

                Divider()

                // Stats
                VStack(alignment: .leading, spacing: 4) {
                    Text("Requests: \(commandServer.requestCount)")
                        .font(.caption)
                    if !commandServer.lastCommand.isEmpty {
                        Text("Last: \(commandServer.lastCommand)")
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
            Image(systemName: commandServer.isRunning ? "waveform" : "waveform.slash")
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(commandServer.isRunning ? .primary : .red)
        }
        .menuBarExtraStyle(.window)
        .onChange(of: appDelegate.isTerminating) { _, terminating in
            if terminating {
                commandServer.stop()
            }
        }
    }
}

/// Handles app lifecycle and CommandServer startup
final class AppDelegate: NSObject, NSApplicationDelegate, ObservableObject {
    @Published var isTerminating = false
    private var commandServer: CommandServer?

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
            commandServer = CommandServer()
            commandServer?.start()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        Task { @MainActor in
            commandServer?.stop()
        }
        isTerminating = true
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
    }
}
