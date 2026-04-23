import SwiftUI

struct OnboardingView: View {
    @EnvironmentObject var monitor: ServerMonitor
    @Environment(\.dismiss) private var dismiss

    @State private var urlDraft = ""
    @State private var keyDraft = ""
    @State private var externalDraft = ""
    @State private var managedMode = false
    @State private var caelDirDraft = "~/Projects/cael"

    var body: some View {
        VStack(spacing: 20) {
            Text(monitor.settings.isConfigured ? "Settings" : "Connect to Sonique")
                .font(.headline)

            VStack(alignment: .leading, spacing: 12) {

                // Managed mode toggle
                VStack(alignment: .leading, spacing: 6) {
                    Toggle(isOn: $managedMode) {
                        Text("Manage CAAL with SoniqueBar")
                            .font(.system(size: 13, weight: .medium))
                    }
                    .toggleStyle(.switch)

                    if managedMode {
                        Text("SoniqueBar will start and stop the CAAL voice backend automatically using Docker.")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                            .fixedSize(horizontal: false, vertical: true)

                        VStack(alignment: .leading, spacing: 4) {
                            Text("CAAL directory")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            TextField("~/Projects/cael", text: $caelDirDraft)
                                .textFieldStyle(.roundedBorder)
                        }
                        .padding(.top, 2)
                    }
                }

                Divider()

                // Manual URL fields — always available, required when not managed
                VStack(alignment: .leading, spacing: 6) {
                    if managedMode {
                        Text("Manual URL override (optional)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("Local URL")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    TextField(managedMode ? "Leave empty to use localhost:3000" : "http://192.168.0.x:3000",
                              text: $urlDraft)
                        .textFieldStyle(.roundedBorder)

                    Text("Remote URL (optional)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.top, 4)
                    TextField("http://100.x.x.x:3000 or tunnel URL", text: $externalDraft)
                        .textFieldStyle(.roundedBorder)
                    Text("Tailscale IP, Cloudflare tunnel, etc. — used by iPhone when away from home.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)

                    Text("API Key (optional)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.top, 4)
                    SecureField("Leave empty if not set", text: $keyDraft)
                        .textFieldStyle(.roundedBorder)
                }
            }

            HStack {
                if monitor.settings.isConfigured {
                    Button("Cancel") { dismiss() }
                }
                Spacer()
                Button("Save") { save() }
                    .buttonStyle(.borderedProminent)
                    .disabled(!managedMode && urlDraft.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(24)
        .frame(width: 340)
        .onAppear {
            urlDraft      = monitor.settings.serverURL
            keyDraft      = monitor.settings.apiKey
            externalDraft = monitor.settings.externalURL
            managedMode   = monitor.settings.managedMode
            caelDirDraft  = monitor.settings.caelDirectory
        }
    }

    private func save() {
        monitor.settings.managedMode   = managedMode
        monitor.settings.caelDirectory = caelDirDraft.trimmingCharacters(in: .whitespaces)
        monitor.settings.serverURL     = urlDraft.trimmingCharacters(in: .whitespaces)
        monitor.settings.externalURL   = externalDraft.trimmingCharacters(in: .whitespaces)
        monitor.settings.apiKey        = keyDraft.trimmingCharacters(in: .whitespaces)

        if managedMode {
            Task { await monitor.containerManager.setup(caelDirectory: monitor.settings.caelDirectory) }
        }
        monitor.startPolling()
        dismiss()
    }
}
