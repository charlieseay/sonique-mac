import SwiftUI
import AppKit
import AVFoundation

/// Comprehensive permissions onboarding flow
struct PermissionsOnboarding: View {
    @Binding var isPresented: Bool
    let onComplete: () -> Void

    @State private var currentStep = 0
    @State private var grantedPermissions: Set<PermissionType> = []

    let permissions: [Permission] = [
        Permission(
            type: .fullDiskAccess,
            title: "Full Disk Access",
            icon: "externaldrive.fill",
            why: "Needed to import your Safari login session for Claude",
            consequence: "Setup will fail - you won't be able to use Quinn",
            required: true
        )
    ]

    var body: some View {
        VStack(spacing: 0) {
            if currentStep < permissions.count {
                PermissionRequestView(
                    permission: permissions[currentStep],
                    onGrant: {
                        grantedPermissions.insert(permissions[currentStep].type)
                        nextStep()
                    },
                    onSkip: {
                        nextStep()
                    }
                )
            } else {
                completionView
            }
        }
        .frame(width: 700, height: 550)
    }

    private func nextStep() {
        if currentStep < permissions.count - 1 {
            withAnimation {
                currentStep += 1
            }
        } else {
            // All permissions done
            withAnimation {
                currentStep += 1
            }
        }
    }

    private var completionView: some View {
        VStack(spacing: 30) {
            Spacer()

            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 60))
                .foregroundColor(.green)

            Text("Permissions Set!")
                .font(.title)
                .bold()

            Text("Quinn is ready to get started")
                .foregroundColor(.secondary)

            VStack(alignment: .leading, spacing: 8) {
                ForEach(permissions) { permission in
                    HStack {
                        Image(systemName: grantedPermissions.contains(permission.type) ? "checkmark.circle.fill" : "xmark.circle.fill")
                            .foregroundColor(grantedPermissions.contains(permission.type) ? .green : .secondary)

                        Text(permission.title)
                            .foregroundColor(grantedPermissions.contains(permission.type) ? .primary : .secondary)
                    }
                }
            }
            .padding()

            Spacer()

            Button("Continue") {
                onComplete()
                isPresented = false
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .padding(.bottom, 40)
        }
    }
}

struct PermissionRequestView: View {
    let permission: Permission
    let onGrant: () -> Void
    let onSkip: () -> Void

    @State private var isChecking = false
    @State private var hasPermission = false
    @State private var wasDenied = false

    var body: some View {
        VStack(spacing: 30) {
            Spacer()

            // Icon and title
            VStack(spacing: 16) {
                Image(systemName: permission.icon)
                    .font(.system(size: 70))
                    .foregroundColor(.blue)

                Text(permission.title)
                    .font(.title)
                    .bold()

                if permission.required {
                    Text("REQUIRED")
                        .font(.caption)
                        .bold()
                        .foregroundColor(.white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 4)
                        .background(Color.red)
                        .cornerRadius(4)
                }
            }

            // Why it's needed
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Why:")
                        .font(.headline)
                        .foregroundColor(.blue)

                    Text(permission.why)
                        .font(.body)
                        .fixedSize(horizontal: false, vertical: true)
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("Without it:")
                        .font(.headline)
                        .foregroundColor(.orange)

                    Text(permission.consequence)
                        .font(.body)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: 600)
            .padding(.horizontal, 50)

            Spacer()

            // Action buttons
            VStack(spacing: 12) {
                if hasPermission {
                    HStack {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(.green)
                        Text("Permission granted!")
                            .foregroundColor(.green)
                    }
                    .padding()

                    Button("Continue") {
                        onGrant()
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                } else if wasDenied {
                    // Permission was denied - show instructions to fix in System Settings
                    VStack(spacing: 12) {
                        HStack {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundColor(.orange)
                            Text("Permission Denied")
                                .foregroundColor(.orange)
                                .font(.headline)
                        }

                        Text("To enable \(permission.title), open System Settings and toggle it on for SoniqueBar")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal)

                        Button("Open System Settings") {
                            if permission.type == .microphone {
                                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
                                    NSWorkspace.shared.open(url)
                                }
                            }
                            // Start polling for permission grant
                            startPollingForPermission()
                        }
                        .buttonStyle(.borderedProminent)

                        if !permission.required {
                            Button("Skip for Now") {
                                onSkip()
                            }
                            .foregroundColor(.secondary)
                        }
                    }
                } else {
                    Button(action: requestPermission) {
                        Text("Grant \(permission.title)")
                            .font(.headline)
                            .frame(maxWidth: 300)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(isChecking)

                    if !permission.required {
                        Button("Skip for Now") {
                            onSkip()
                        }
                        .foregroundColor(.secondary)
                    }
                }
            }
            .padding(.bottom, 40)
        }
        .onAppear {
            checkPermission()
        }
    }

    private func checkPermission() {
        switch permission.type {
        case .microphone:
            hasPermission = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        case .fullDiskAccess:
            hasPermission = checkFullDiskAccess()
        case .accessibility:
            hasPermission = AXIsProcessTrusted()
        }
    }

    private func requestPermission() {
        NSLog("[PermissionsOnboarding] Requesting \(permission.title)")
        isChecking = true

        switch permission.type {
        case .microphone:
            NSLog("[PermissionsOnboarding] Requesting microphone access")
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                NSLog("[PermissionsOnboarding] Microphone granted: \(granted)")
                DispatchQueue.main.async {
                    hasPermission = granted
                    wasDenied = !granted
                    isChecking = false
                    if granted {
                        NSLog("[PermissionsOnboarding] Auto-advancing after grant")
                        // Auto-advance after brief delay
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                            onGrant()
                        }
                    } else {
                        NSLog("[PermissionsOnboarding] Permission denied - showing System Settings instructions")
                    }
                }
            }

        case .fullDiskAccess:
            showFullDiskAccessGuide()

        case .accessibility:
            showAccessibilityGuide()
        }
    }

    private func showFullDiskAccessGuide() {
        let alert = NSAlert()
        alert.messageText = "Grant Full Disk Access"
        alert.informativeText = """
        Quinn will open System Settings.

        Follow these steps:
        1. Click the "+" button
        2. Find and select "SoniqueBar" from Applications
        3. Authenticate with your password
        4. Toggle the switch ON

        ⚠️ Quinn will restart automatically when you toggle the switch.
        """
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "I'll Do This Later")
        alert.alertStyle = .informational

        if alert.runModal() == .alertFirstButtonReturn {
            // Open System Settings to Full Disk Access
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
                NSWorkspace.shared.open(url)
            }

            // Start polling to detect when permission is granted
            startPollingForPermission()
        } else {
            isChecking = false
            onSkip()
        }
    }

    private func showAccessibilityGuide() {
        let alert = NSAlert()
        alert.messageText = "Grant Accessibility Access"
        alert.informativeText = """
        Quinn will open System Settings.

        Follow these steps:
        1. Find "SoniqueBar" in the list
        2. Toggle the switch ON
        3. Authenticate with your password

        ⚠️ Quinn will restart automatically when you toggle the switch.
        """
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "I'll Do This Later")
        alert.alertStyle = .informational

        if alert.runModal() == .alertFirstButtonReturn {
            // Open System Settings to Accessibility
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                NSWorkspace.shared.open(url)
            }

            startPollingForPermission()
        } else {
            isChecking = false
            onSkip()
        }
    }

    private func startPollingForPermission() {
        // Poll every 2 seconds to detect when permission is granted
        Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { timer in
            checkPermission()

            if hasPermission {
                timer.invalidate()
                isChecking = false

                // Auto-advance
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                    onGrant()
                }
            }
        }
    }

    private func checkFullDiskAccess() -> Bool {
        // Try to read Safari bookmarks (protected by FDA)
        let safariBookmarks = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Safari/Bookmarks.plist")

        return FileManager.default.isReadableFile(atPath: safariBookmarks.path)
    }
}

struct Permission: Identifiable {
    let id = UUID()
    let type: PermissionType
    let title: String
    let icon: String
    let why: String
    let consequence: String
    let required: Bool
}

enum PermissionType: Hashable {
    case microphone
    case fullDiskAccess
    case accessibility
}
