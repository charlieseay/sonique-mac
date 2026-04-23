import SwiftUI
import AppKit
import CoreImage.CIFilterBuiltins

private let donationURL = "https://seayniclabs.com/support"
private let dockerInstallURL = "https://docs.docker.com/desktop/install/mac/"
private let caelRepoURL = "https://github.com/CoreWorxLab/CAAL"

struct StatusPopover: View {
    @EnvironmentObject var monitor: ServerMonitor
    @State private var showOnboarding = false
    @State private var showAbout = false
    @State private var showUpgrade = false

    var body: some View {
        VStack(spacing: 0) {
            // Identity header
            VStack(spacing: 10) {
                avatarView
                    .frame(width: 64, height: 64)

                Text(monitor.profile?.name ?? "Sonique")
                    .font(.system(size: 15, weight: .semibold))

                HStack(spacing: 5) {
                    Circle()
                        .fill(monitor.isOnline ? Color.green : Color.red)
                        .frame(width: 7, height: 7)
                    Text(monitor.isOnline ? "Online" : "Offline")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.top, 18)
            .padding(.bottom, 14)

            // QR code for iOS onboarding
            if monitor.settings.isConfigured, let qrImage = localQRImage() {
                Divider()
                VStack(spacing: 6) {
                    Image(nsImage: qrImage)
                        .interpolation(.none)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 160, height: 160)
                        .background(.white)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                    Text("Scan with Sonique on iPhone")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 14)
            }

            // CAAL container status
            Divider()
            containerStatusRow

            // House ad — hidden for premium users
            if !monitor.premium.isPremium {
                Divider()
                houseAdRow
            }

            Divider()

            VStack(spacing: 1) {
                popoverButton("Open Dashboard", icon: "square.grid.2x2",
                              disabled: monitor.containerManager.state != .running) {
                    if let url = URL(string: monitor.settings.effectiveURL) {
                        NSWorkspace.shared.open(url)
                    }
                }
                popoverButton("Refresh", icon: "arrow.clockwise") {
                    Task { await monitor.refresh() }
                }
                Divider().padding(.horizontal, 8).padding(.vertical, 2)
                popoverButton("Settings", icon: "gearshape") {
                    showOnboarding = true
                }
                popoverButton("About & Support", icon: "heart") {
                    showAbout = true
                }
                Divider().padding(.horizontal, 8).padding(.vertical, 2)
                popoverButton("Quit Sonique", icon: "power") {
                    NSApplication.shared.terminate(nil)
                }
            }
            .padding(.vertical, 6)
        }
        .frame(width: 240)
        .sheet(isPresented: $showOnboarding) {
            OnboardingView().environmentObject(monitor)
        }
        .sheet(isPresented: $showAbout) {
            AboutView().environmentObject(monitor.premium)
        }
        .sheet(isPresented: $showUpgrade) {
            MacUpgradeView().environmentObject(monitor.premium)
        }
    }

    // MARK: - Container status row

    private var containerStatusRow: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(containerDotColor)
                .frame(width: 7, height: 7)
            VStack(alignment: .leading, spacing: 1) {
                Text("CAAL")
                    .font(.system(size: 12, weight: .medium))
                Text(monitor.containerManager.state.label)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            containerActionView
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private var containerActionView: some View {
        let s = monitor.containerManager.state
        if s == .notInstalled {
            Button("Install Docker") { openURL(dockerInstallURL) }
                .buttonStyle(.bordered)
                .controlSize(.small)
        } else if s == .daemonDown {
            Button("Start Docker") {
                NSWorkspace.shared.open(URL(fileURLWithPath: "/Applications/Docker.app"))
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        } else if s.canStart {
            Button("Start") {
                Task { await monitor.containerManager.start(caelDirectory: monitor.settings.caelDirectory) }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        } else if s.canStop {
            Button("Stop") {
                Task { await monitor.containerManager.stop(caelDirectory: monitor.settings.caelDirectory) }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        } else if s.isBusy {
            ProgressView()
                .scaleEffect(0.6)
                .frame(width: 20, height: 20)
        }
    }

    private var containerDotColor: Color {
        switch monitor.containerManager.state {
        case .running:                        return .green
        case .starting, .building, .stopping: return .orange
        case .notInstalled, .daemonDown:      return .yellow
        case .error:                          return .red
        default:                              return Color(nsColor: .tertiaryLabelColor)
        }
    }

    // MARK: - House ad

    private var houseAdRow: some View {
        HStack(spacing: 10) {
            Image(systemName: "sparkles")
                .font(.system(size: 12))
                .foregroundStyle(Color(red: 0.6, green: 0.3, blue: 0.9))
            Text("Seaynic Labs")
                .font(.system(size: 11, weight: .semibold))
            Text("·")
                .foregroundStyle(.secondary)
            Text("Self-hosted AI tools")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Spacer()
            Button("Remove Ads") { showUpgrade = true }
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Color(red: 0.6, green: 0.3, blue: 0.9))
                .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    // MARK: - QR code

    private func localQRImage() -> NSImage? {
        let local = "http://localhost:3100"
        guard !local.isEmpty else { return nil }

        var items: [URLQueryItem] = [URLQueryItem(name: "local", value: local)]
        // External URL only included for premium users — free tier is local-only
        let ext = monitor.settings.normalizedExternalURL
        if !ext.isEmpty && monitor.premium.isPremium { items.append(URLQueryItem(name: "external", value: ext)) }
        let key = monitor.settings.apiKey
        if !key.isEmpty { items.append(URLQueryItem(name: "key", value: key)) }

        var comps = URLComponents()
        comps.scheme = "sonique"
        comps.host = "connect"
        comps.queryItems = items
        guard let qrString = comps.url?.absoluteString,
              let data = qrString.data(using: .utf8) else { return nil }

        let filter = CIFilter.qrCodeGenerator()
        filter.message = data
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        let scaled = output.transformed(by: CGAffineTransform(scaleX: 10, y: 10))
        let context = CIContext()
        guard let cgImage = context.createCGImage(scaled, from: scaled.extent) else { return nil }
        return NSImage(cgImage: cgImage, size: NSSize(width: 160, height: 160))
    }

    // MARK: - Avatar

    @ViewBuilder
    private var avatarView: some View {
        Group {
            if let img = monitor.avatarImage {
                Image(nsImage: img)
                    .resizable()
                    .scaledToFill()
                    .clipShape(Circle())
                    .overlay(Circle().strokeBorder(.white.opacity(0.15), lineWidth: 1))
            } else {
                Circle()
                    .fill(LinearGradient(colors: [Color(red: 0.4, green: 0.3, blue: 0.9),
                                                  Color(red: 0.6, green: 0.3, blue: 0.9)],
                                        startPoint: .topLeading, endPoint: .bottomTrailing))
                    .overlay(Image(systemName: "waveform")
                        .font(.title2)
                        .foregroundStyle(.white))
            }
        }
    }

    // MARK: - Button

    private func popoverButton(_ title: String, icon: String, disabled: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .frame(width: 16)
                    .foregroundStyle(disabled ? Color(nsColor: .tertiaryLabelColor) : .secondary)
                Text(title)
                    .foregroundStyle(disabled ? Color(nsColor: .tertiaryLabelColor) : .primary)
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .background(Color.primary.opacity(0.001))
        .hoverEffect()
    }

    private func openURL(_ string: String) {
        if let url = URL(string: string) { NSWorkspace.shared.open(url) }
    }
}

// MARK: - Mac upgrade sheet

struct MacUpgradeView: View {
    @EnvironmentObject var premium: PremiumManager
    @Environment(\.dismiss) private var dismiss

    @State private var code = ""
    @State private var invalid = false

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "waveform.circle.fill")
                .font(.system(size: 48))
                .foregroundStyle(LinearGradient(
                    colors: [Color(red: 0.4, green: 0.3, blue: 0.9), Color(red: 0.6, green: 0.3, blue: 0.9)],
                    startPoint: .topLeading, endPoint: .bottomTrailing))

            VStack(spacing: 4) {
                Text("Support Sonique")
                    .font(.title3.bold())
                Text("$19.99 one-time donation")
                    .foregroundStyle(Color(red: 0.6, green: 0.3, blue: 0.9))
                    .font(.subheadline)
            }

            VStack(alignment: .leading, spacing: 10) {
                featureRow(icon: "network", text: "Remote access — iPhone connects when away from home")
                featureRow(icon: "xmark.circle", text: "No ads")
                featureRow(icon: "heart", text: "Keep Sonique free for everyone")
            }

            Button("Donate — $19.99") {
                premium.openDonationPage()
            }
            .buttonStyle(.borderedProminent)

            Divider()

            VStack(alignment: .leading, spacing: 6) {
                Text("Already donated? Enter your unlock code:")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    TextField("SONIQUE-XXXX", text: $code)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.body, design: .monospaced))
                        .onChange(of: code) { _ in invalid = false }
                    Button("Apply") { apply() }
                        .disabled(code.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                if invalid {
                    Text("Code not recognized. Check your donation confirmation.")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }

            Text("Ads help keep Sonique free. The unlock code appears on your Stripe donation confirmation page.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            Button("Not Now") { dismiss() }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .font(.caption)
        }
        .padding(28)
        .frame(width: 320)
        .onChange(of: premium.isPremium) { newVal in
            if newVal { dismiss() }
        }
    }

    private func apply() {
        if premium.redeem(code) {
            dismiss()
        } else {
            invalid = true
        }
    }

    private func featureRow(icon: String, text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .frame(width: 16)
                .foregroundStyle(Color(red: 0.6, green: 0.3, blue: 0.9))
            Text(text)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - About sheet

struct AboutView: View {
    @EnvironmentObject var premium: PremiumManager
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "waveform.circle.fill")
                .font(.system(size: 48))
                .foregroundStyle(LinearGradient(
                    colors: [Color(red: 0.4, green: 0.3, blue: 0.9), Color(red: 0.6, green: 0.3, blue: 0.9)],
                    startPoint: .topLeading, endPoint: .bottomTrailing))

            VStack(spacing: 4) {
                Text("Sonique")
                    .font(.title2.bold())
                Text("by Seaynic Labs")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Text("Sonique is free. If it saves you time or makes your home a little smarter, consider supporting development — it keeps the project alive.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            Button("Support Development") {
                NSWorkspace.shared.open(URL(string: donationURL)!)
            }
            .buttonStyle(.borderedProminent)

            Divider()

            VStack(spacing: 6) {
                Text("Powered by CAAL")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text("The voice engine behind Sonique is CAAL, an open-source voice assistant framework by CoreWorxLab. Sonique wouldn't exist without it.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                Button("View CAAL on GitHub") {
                    NSWorkspace.shared.open(URL(string: caelRepoURL)!)
                }
                .font(.caption)
                .buttonStyle(.plain)
                .foregroundStyle(.blue)
            }

            Button("Close") { dismiss() }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .font(.caption)
        }
        .padding(28)
        .frame(width: 300)
    }
}

private extension View {
    func hoverEffect() -> some View {
        self.onHover { hovering in _ = hovering }
    }
}
