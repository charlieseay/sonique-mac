import SwiftUI

struct OnboardingView: View {
    @EnvironmentObject var monitor: ServerMonitor
    @Environment(\.dismiss) private var dismiss

    @State private var caelDirDraft = "~/Projects/cael"
    @State private var externalDraft = ""
    @State private var keyDraft = ""

    var body: some View {
        VStack(spacing: 20) {
            Text(monitor.settings.isConfigured ? "Settings" : "Set up Sonique")
                .font(.headline)

            VStack(alignment: .leading, spacing: 12) {

                // CAAL directory
                VStack(alignment: .leading, spacing: 4) {
                    Text("CAAL directory")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    HStack(spacing: 6) {
                        TextField("~/Projects/cael", text: $caelDirDraft)
                            .textFieldStyle(.roundedBorder)
                        Button {
                            let panel = NSOpenPanel()
                            panel.canChooseFiles = false
                            panel.canChooseDirectories = true
                            panel.allowsMultipleSelection = false
                            if panel.runModal() == .OK, let url = panel.url {
                                caelDirDraft = url.path
                            }
                        } label: {
                            Image(systemName: "folder")
                        }
                        .buttonStyle(.bordered)
                    }
                    Text("Where you cloned the CAAL repo. SoniqueBar starts and stops it automatically.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Divider()

                // Remote URL — premium feature
                VStack(alignment: .leading, spacing: 4) {
                    Text("Remote URL (optional)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    TextField("http://100.x.x.x:3000 or tunnel URL", text: $externalDraft)
                        .textFieldStyle(.roundedBorder)
                    Text("Tailscale IP, Cloudflare tunnel, etc. — used by iPhone when away from home.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                // API Key
                VStack(alignment: .leading, spacing: 4) {
                    Text("API Key (optional)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
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
                    .disabled(caelDirDraft.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(24)
        .frame(width: 340)
        .onAppear {
            caelDirDraft  = monitor.settings.caelDirectory
            externalDraft = monitor.settings.externalURL
            keyDraft      = monitor.settings.apiKey
        }
    }

    private func save() {
        monitor.settings.caelDirectory = caelDirDraft.trimmingCharacters(in: .whitespaces)
        monitor.settings.externalURL   = externalDraft.trimmingCharacters(in: .whitespaces)
        monitor.settings.apiKey        = keyDraft.trimmingCharacters(in: .whitespaces)
        Task { await monitor.containerManager.setup(caelDirectory: monitor.settings.caelDirectory) }
        monitor.startPolling()
        dismiss()
    }
}
