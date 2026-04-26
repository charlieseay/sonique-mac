import SwiftUI

struct OnboardingView: View {
    @EnvironmentObject var monitor: ServerMonitor
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dismissWindow) private var dismissWindow

    @State private var caelDirDraft = "~/Projects/cael"
    @State private var externalDraft = ""
    @State private var keyDraft = ""
    @State private var ttsVoiceDraft = PiperVoice.defaultVoice.id
    @State private var deploymentModeDraft: SidecarManager.DeploymentMode = .networked

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
                    HStack(spacing: 6) {
                        TextField("http://100.x.x.x:3100 or tunnel URL", text: $externalDraft)
                            .textFieldStyle(.roundedBorder)
                        Button("Tailscale") {
                            Task { await detectTailscale() }
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .help("Auto-detect your Tailscale IP")
                    }
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

                Divider()

                // Voice selection
                VStack(alignment: .leading, spacing: 4) {
                    Text("Voice")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Picker("", selection: $ttsVoiceDraft) {
                        ForEach(PiperVoice.all) { voice in
                            Text(voice.label).tag(voice.id)
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                }

                Divider()

                // Deployment mode
                VStack(alignment: .leading, spacing: 4) {
                    Text("Deployment mode")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Picker("", selection: $deploymentModeDraft) {
                        ForEach(SidecarManager.DeploymentMode.allCases) { mode in
                            Text(mode.label).tag(mode)
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    Text(deploymentModeDraft == .embedded
                        ? "Embedded — ships a bundled Python runtime, Ollama, STT, TTS inside the app. No Docker or external services required."
                        : "Networked — uses the Docker-based CAAL stack in the directory above. Keep if you already run CAAL for other tools.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            HStack {
                if monitor.settings.isConfigured {
                    Button("Cancel") {
                        dismissWindow(id: "settings")
                        dismiss()
                    }
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
            caelDirDraft        = monitor.settings.caelDirectory
            externalDraft       = monitor.settings.externalURL
            keyDraft            = monitor.settings.apiKey
            ttsVoiceDraft       = monitor.settings.ttsVoiceId
            deploymentModeDraft = monitor.settings.deploymentMode
        }
    }

    private func detectTailscale() async {
        if let ip = await monitor.detectTailscaleIP() {
            externalDraft = "http://\(ip):3100"
        }
    }

    private func save() {
        monitor.settings.caelDirectory = caelDirDraft.trimmingCharacters(in: .whitespaces)
        monitor.settings.externalURL   = externalDraft.trimmingCharacters(in: .whitespaces)
        monitor.settings.apiKey        = keyDraft.trimmingCharacters(in: .whitespaces)
        monitor.settings.ttsVoiceId    = ttsVoiceDraft

        let modeChanged = deploymentModeDraft != monitor.settings.deploymentMode
        if modeChanged {
            Task { await monitor.applyDeploymentMode(deploymentModeDraft) }
        } else if deploymentModeDraft == .networked {
            Task { await monitor.containerManager.setup(caelDirectory: monitor.settings.caelDirectory) }
        }

        Task { await syncVoice() }
        monitor.startPolling()
        dismissWindow(id: "settings")
        dismiss()
    }

    private func syncVoice() async {
        guard let url = URL(string: "\(monitor.settings.effectiveURL)/api/settings") else { return }
        guard let body = try? JSONSerialization.data(withJSONObject: [
            "settings": ["tts_voice_piper": ttsVoiceDraft]
        ]) else { return }
        var req = URLRequest(url: url, timeoutInterval: 5)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !monitor.settings.apiKey.isEmpty {
            req.setValue(monitor.settings.apiKey, forHTTPHeaderField: "x-api-key")
        }
        req.httpBody = body
        _ = try? await URLSession.shared.data(for: req)
    }
}
