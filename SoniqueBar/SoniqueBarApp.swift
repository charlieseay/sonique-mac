import SwiftUI
import AppKit
import os.log

@main
struct SoniqueBarApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var commandServer = CommandServer.shared
    @State private var settingsWindow: NSWindow?
    @State private var chatWindow: NSWindow?

    init() {
        let logPath = "/tmp/soniquebar.log"
        freopen(logPath.cString(using: .utf8), "a+", stdout)
        freopen(logPath.cString(using: .utf8), "a+", stderr)
        print("=== SoniqueBar started at \(Date()) ===")
    }

    var body: some Scene {
        MenuBarExtra {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .firstTextBaseline) {
                    Text("SoniqueBar")
                        .font(.headline)
                    Spacer()
                    Text(appVersion)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }

                Divider()

                HStack {
                    Circle()
                        .fill(commandServer.isRunning ? Color.green : Color.red)
                        .frame(width: 8, height: 8)
                    Text(commandServer.isRunning ? "Online (port 8890)" : "Offline")
                        .font(.caption)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("Requests: \(commandServer.requestCount)")
                        .font(.caption)
                    if !commandServer.lastCommand.isEmpty {
                        Text("Last: \(commandServer.lastCommand)")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                            .lineLimit(2)
                    }
                }

                Divider()

                Button(action: openLogs) {
                    Label("Open Logs", systemImage: "doc.text")
                        .font(.caption)
                }

                Button(action: testConnection) {
                    Label("Test Connection", systemImage: "network")
                        .font(.caption)
                }

                Button(action: openSettings) {
                    Label("Settings", systemImage: "gearshape")
                        .font(.caption)
                }

                Button(action: openChat) {
                    Label("Chat with Quinn", systemImage: "message")
                        .font(.caption)
                }

                Divider()

                Button("Quit SoniqueBar") {
                    NSApp.terminate(nil)
                }
            }
            .padding()
            .frame(width: 250)
        } label: {
            Image(systemName: commandServer.isRunning ? "waveform" : "waveform.slash")
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(commandServer.isRunning ? .primary : .red)
        }
        .menuBarExtraStyle(.window)
    }

    // MARK: - Actions

    private var appVersion: String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let b = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        return "v\(v) (\(b))"
    }

    private func openLogs() {
        NSWorkspace.shared.selectFile("/tmp/soniquebar.log", inFileViewerRootedAtPath: "/tmp")
    }

    private func testConnection() {
        let alert = NSAlert()
        alert.messageText = "Connection Test"
        alert.informativeText = "Server is \(commandServer.isRunning ? "running on port 8890" : "offline")"
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    private func openSettings() {
        print("[SoniqueBar] openSettings called")

        // Close existing settings window if open
        settingsWindow?.close()

        // Create new settings window
        let contentView = SettingsView()
        let hostingController = NSHostingController(rootView: contentView)

        let window = NSWindow(contentViewController: hostingController)
        window.title = "SoniqueBar Settings"
        window.styleMask = [.titled, .closable, NSWindow.StyleMask.miniaturizable]
        window.isReleasedWhenClosed = false
        window.center()
        window.setFrameAutosaveName("SoniqueBar Settings")

        print("[SoniqueBar] About to show settings window")
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        print("[SoniqueBar] Window shown, isVisible: \(window.isVisible)")

        settingsWindow = window
    }

    private func openChat() {
        print("[SoniqueBar] openChat called")

        // Bring existing chat window to front if open
        if let existing = chatWindow, existing.isVisible {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        // Close previous chat window
        chatWindow?.close()

        // Create new chat window
        let contentView = ChatWindow()
        let hostingController = NSHostingController(rootView: contentView)

        let window = NSWindow(contentViewController: hostingController)
        window.title = "Chat with Quinn"
        window.styleMask = [.titled, .closable, .resizable, .miniaturizable]
        window.isReleasedWhenClosed = false
        window.center()
        window.setFrameAutosaveName("SoniqueBar Chat")

        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        chatWindow = window
    }
}

/// Handles app lifecycle and CommandServer startup
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        let me = NSRunningApplication.current
        NSWorkspace.shared.runningApplications
            .filter { $0.bundleIdentifier == me.bundleIdentifier && $0.processIdentifier != me.processIdentifier }
            .forEach { $0.terminate() }

        NSApp.setActivationPolicy(.accessory)
        NSLog("[SoniqueBar] CommandServer running on port 8890")

        // Wake-up initialization: load personality so Sonique knows who she is
        // Delay slightly to let iCloud container resolve
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 500_000_000) // 0.5 seconds
            let personality = SoniqueBrain.shared.loadPersonaContext()
            if !personality.isEmpty {
                NSLog("[SoniqueBar] ✓ Wake-up complete: loaded identity, rules, capabilities from iCloud")
            } else {
                NSLog("[SoniqueBar] ⚠️ Wake-up incomplete: personality not found (check iCloud sync)")
            }

            // Show setup wizard on first run
            self.showSetupWizardIfNeeded()
        }
    }

    private func showSetupWizardIfNeeded() {
        Task { @MainActor in
            // Check if consumer auth is configured
            let isConfigured = await ProviderManager.shared.isConfigured

            guard !isConfigured else {
                NSLog("[SoniqueBar] Setup already complete")
                return
            }

            // Show setup assistant
            let assistant = SetupAssistantController()
            assistant.show()

            NSLog("[SoniqueBar] ✓ First run: showing setup assistant")
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        NSLog("[SoniqueBar] Terminating")
    }
}
