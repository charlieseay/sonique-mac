import SwiftUI
import AppKit
import os.log
import EventKit

@main
struct SoniqueBarApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var commandServer = CommandServer.shared
    @StateObject private var memoryService = MemoryService.shared
    // @StateObject private var selfHealing = SelfHealingEngine.shared

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

                // Self-healing status (TODO: enable when SelfHealingEngine added to Xcode project)
                // HStack {
                //     Circle()
                //         .fill(selfHealing.isHealthy ? Color.green : Color.orange)
                //         .frame(width: 8, height: 8)
                //     Text(selfHealing.isHealthy ? "Healthy" : "Auto-healing")
                //         .font(.caption)
                //     if let lastCheck = selfHealing.lastSelfCheck {
                //         Text("(checked \(timeSince(lastCheck)))")
                //             .font(.caption2)
                //             .foregroundColor(.secondary)
                //     }
                // }

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

                Button(action: openSettings) {
                    Label("Settings", systemImage: "gearshape")
                        .font(.caption)
                }

                // Button(action: runDiagnostic) {
                //     Label("Run Full Diagnostic", systemImage: "stethoscope")
                //         .font(.caption)
                // }

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
        // CommandServer restart removed - requires implementing stop/start methods
        NSLog("[SoniqueBar] Restart not yet implemented")
    }

    private func openLogs() {
        let logPath = NSHomeDirectory() + "/Library/Logs/SoniqueBar"
        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: logPath)
    }

    private func testConnection() {
        let alert = NSAlert()
        alert.messageText = "Connection Test"
        alert.informativeText = "Health check not yet implemented in simplified version"
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        alert.runModal()
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

    private func openSettings() {
        // Open Settings window
        let settingsWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        settingsWindow.title = "Quinn Settings"
        // Settings view removed during simplification
        settingsWindow.contentView = NSHostingView(rootView: Text("Settings coming soon"))
        settingsWindow.center()
        settingsWindow.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // private func runDiagnostic() {
    //     Task { @MainActor in
    //         let result = await SelfHealingEngine.shared.runFullDiagnostic()
    //
    //         let alert = NSAlert()
    //         alert.messageText = "Diagnostic Complete"
    //         alert.informativeText = result
    //         alert.alertStyle = selfHealing.isHealthy ? .informational : .warning
    //         alert.addButton(withTitle: "OK")
    //         alert.runModal()
    //     }
    // }

    private func timeSince(_ date: Date) -> String {
        let seconds = Int(Date().timeIntervalSince(date))
        if seconds < 60 { return "\(seconds)s ago" }
        let minutes = seconds / 60
        if minutes < 60 { return "\(minutes)m ago" }
        let hours = minutes / 60
        return "\(hours)h ago"
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

        // Calendar access now handled via AppleScript (works with Full Disk Access)
        // requestCalendarAccess() // Disabled - using AppleScript instead of EventKit

        // Run initialization script (validate + auto-heal)
        Task { @MainActor in
            let healthReport = await InitializationScript.initialize()

            // Log health report
            NSLog("[SoniqueBar] Initialization complete")
            NSLog(healthReport.summary)

            // CommandServer starts automatically on init (setupListener)
            NSLog("[SoniqueBar] CommandServer running on port 8890")

            // Background monitoring removed during simplification
            // BackgroundMonitor.shared.startMonitoring()

            // Start self-healing engine (auto-detect and fix Quinn's own issues)
            // TODO: Add SelfHealingEngine.swift to Xcode project, then uncomment:
            // SelfHealingEngine.shared.startSelfMonitoring()

            // Start live screen capture for active vision (macOS 12.3+)
            // Requires Screen Recording permission - grant in System Settings
            if #available(macOS 12.3, *) {
                do {
                    try await LiveScreenCapture.shared.startCapture()
                    NSLog("[SoniqueBar] Live screen capture started (2 FPS)")
                } catch {
                    NSLog("[SoniqueBar] Live screen capture failed: \(error.localizedDescription)")
                    NSLog("[SoniqueBar] Grant Screen Recording permission in System Settings → Privacy & Security")
                }
            }
        }
    }

    private func requestCalendarAccess() {
        guard #available(macOS 14.0, *) else {
            NSLog("[SoniqueBar] Calendar access requires macOS 14+")
            return
        }

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
        // CommandServer cleanup handled by deinit
        NSLog("[SoniqueBar] Terminating")
    }
}
