import SwiftUI
import AppKit
import os.log

@main
struct SoniqueBarApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var commandServer = CommandServer.shared

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
        let configPath = NSHomeDirectory() + "/Library/Application Support/SoniqueBar/config.json"
        NSWorkspace.shared.selectFile(configPath, inFileViewerRootedAtPath: "")
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
        Task { @MainActor in
            let personality = SoniqueBrain.shared.loadPersonaContext()
            if !personality.isEmpty {
                NSLog("[SoniqueBar] ✓ Wake-up complete: loaded identity, rules, capabilities from iCloud")
            } else {
                NSLog("[SoniqueBar] ⚠️ Wake-up incomplete: personality not found (check iCloud sync)")
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        NSLog("[SoniqueBar] Terminating")
    }
}
