import SwiftUI
import AppKit
import os.log
import EventKit

@main
struct SoniqueBarApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var commandServer = CommandServer.shared
    @StateObject private var memoryService = MemoryService.shared

    init() {
        // Redirect stdout/stderr to a file for debugging
        let logPath = "/tmp/soniquebar.log"
        freopen(logPath.cString(using: .utf8), "a+", stdout)
        freopen(logPath.cString(using: .utf8), "a+", stderr)
        print("=== SoniqueBar started at \(Date()) ===")
    }

    var body: some Scene {
        MenuBarExtra {
            VStack(alignment: .leading, spacing: 12) {
                // Header
                HStack(alignment: .firstTextBaseline) {
                    Text("SoniqueBar")
                        .font(.headline)
                    Spacer()
                    Text(appVersion)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }

                Divider()

                // Server status
                HStack {
                    Circle()
                        .fill(commandServer.isRunning ? Color.green : Color.red)
                        .frame(width: 8, height: 8)
                    Text(commandServer.isRunning ? "Online (port 8890)" : "Offline")
                        .font(.caption)
                }

                // Stats
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

                // Memory stats
                VStack(alignment: .leading, spacing: 4) {
                    Text("Memory: \(String(format: "%.1f", memoryService.memorySizeMB))MB")
                        .font(.caption)
                    Text("Conversations: \(memoryService.workingMemory.count) in session")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }

                Divider()

                // Actions
                Button(action: restartServer) {
                    Label("Restart Server", systemImage: "arrow.clockwise")
                        .font(.caption)
                }

                Button(action: openLogs) {
                    Label("Open Logs", systemImage: "doc.text")
                        .font(.caption)
                }

                Button(action: testConnection) {
                    Label("Test Connection", systemImage: "network")
                        .font(.caption)
                }

                Button(action: clearMemory) {
                    Label("Clear Memory", systemImage: "trash")
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

    private func restartServer() {
        Task { @MainActor in
            CommandServer.shared.stop()
            try? await Task.sleep(nanoseconds: 500_000_000)
            CommandServer.shared.start()
        }
    }

    private func openLogs() {
        let logPath = NSHomeDirectory() + "/Library/Logs/SoniqueBar"
        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: logPath)
    }

    private func testConnection() {
        Task {
            let result = await InfrastructureExecutor.shell("curl -s http://localhost:8890/health")
            let alert = NSAlert()
            alert.messageText = "Connection Test"
            alert.informativeText = result.exitCode == 0 ? "✅ Server is healthy\n\(result.stdout)" : "❌ Server is unreachable\n\(result.stderr)"
            alert.alertStyle = result.exitCode == 0 ? .informational : .warning
            alert.addButton(withTitle: "OK")
            alert.runModal()
        }
    }

    private func clearMemory() {
        Task { @MainActor in
            await MemoryService.shared.cleanMemory()
            MemoryService.shared.clearWorkingMemory()

            let alert = NSAlert()
            alert.messageText = "Memory Cleared"
            alert.informativeText = "Working memory and old conversations have been cleared."
            alert.alertStyle = .informational
            alert.addButton(withTitle: "OK")
            alert.runModal()
        }
    }
}

/// Handles app lifecycle and CommandServer startup
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Terminate any older instance
        let me = NSRunningApplication.current
        NSWorkspace.shared.runningApplications
            .filter { $0.bundleIdentifier == me.bundleIdentifier && $0.processIdentifier != me.processIdentifier }
            .forEach { $0.terminate() }

        // Run as menu bar app (no dock icon)
        NSApp.setActivationPolicy(.accessory)

        // Request Calendar access on first launch (triggers permission prompt)
        requestCalendarAccess()

        // Start CommandServer
        Task { @MainActor in
            CommandServer.shared.start()

            // Start background monitoring (Helmsman queue, Docker health, disk space)
            BackgroundMonitor.shared.startMonitoring()

            // Screen awareness disabled - screenshots taken on-demand only
            // ScreenAwarenessService.shared.startMonitoring()
        }
    }

    private func requestCalendarAccess() {
        let eventStore = EKEventStore()
        eventStore.requestFullAccessToEvents { granted, error in
            if granted {
                NSLog("[SoniqueBar] Calendar access granted")
            } else {
                NSLog("[SoniqueBar] Calendar access denied: \(error?.localizedDescription ?? "unknown")")
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        Task { @MainActor in
            CommandServer.shared.stop()
        }
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
    }
}
