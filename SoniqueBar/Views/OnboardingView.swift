import SwiftUI

struct OnboardingView: View {
    @EnvironmentObject var monitor: ServerMonitor
    @Environment(\.dismiss) private var dismiss
    @State private var urlDraft = ""
    @State private var keyDraft = ""
    @State private var externalDraft = ""

    var body: some View {
        VStack(spacing: 20) {
            Text(monitor.settings.isConfigured ? "Settings" : "Connect to Base Station")
                .font(.headline)

            VStack(alignment: .leading, spacing: 6) {
                Text("Local URL")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextField("http://192.168.0.x:3000", text: $urlDraft)
                    .textFieldStyle(.roundedBorder)

                Text("Remote URL (optional)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.top, 4)
                TextField("http://100.x.x.x:3000 or tunnel URL", text: $externalDraft)
                    .textFieldStyle(.roundedBorder)
                Text("Used by the iPhone when not on your local network — Tailscale IP, Cloudflare tunnel, etc.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)

                Text("API Key (optional)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.top, 4)
                SecureField("Leave empty if not set", text: $keyDraft)
                    .textFieldStyle(.roundedBorder)
            }

            HStack {
                if monitor.settings.isConfigured {
                    Button("Cancel") { dismiss() }
                }
                Spacer()
                Button("Connect") { save() }
                    .buttonStyle(.borderedProminent)
                    .disabled(urlDraft.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(24)
        .frame(width: 320)
        .onAppear {
            urlDraft = monitor.settings.serverURL
            keyDraft = monitor.settings.apiKey
            externalDraft = monitor.settings.externalURL
        }
    }

    private func save() {
        monitor.settings.serverURL = urlDraft.trimmingCharacters(in: .whitespaces)
        monitor.settings.apiKey = keyDraft.trimmingCharacters(in: .whitespaces)
        monitor.settings.externalURL = externalDraft.trimmingCharacters(in: .whitespaces)
        monitor.startPolling()
        dismiss()
    }
}
