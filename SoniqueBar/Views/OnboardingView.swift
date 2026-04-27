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
    @State private var launchAtLoginDraft = true
    @State private var haURLDraft = ""
    @State private var haTokenDraft = ""
    @State private var llmProviderDraft: SoniqueBarLLMProvider = .ollama
    @State private var preferredModelDraft = "gemma4"
    @State private var fallbackPolicyDraft: SoniqueBarFallbackPolicy = .localOnly
    @State private var nvidiaBaseURLDraft = ""
    @State private var nvidiaFeatureDraft = false

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

                // LLM provider (UI scaffold only)
                VStack(alignment: .leading, spacing: 4) {
                    Text("LLM provider")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Toggle("NVIDIA NIM options (experimental)", isOn: $nvidiaFeatureDraft)
                        .toggleStyle(.switch)
                        .controlSize(.small)
                        .onChange(of: nvidiaFeatureDraft) { _, enabled in
                            if !enabled, llmProviderDraft == .nvidia {
                                llmProviderDraft = .ollama
                            }
                        }
                    Text("Off by default. UI + prefs only until CAAL task #284.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)

                    Picker("", selection: $llmProviderDraft) {
                        ForEach(nvidiaFeatureDraft ? SoniqueBarLLMProvider.allCases : [.ollama]) { provider in
                            Text(provider.label).tag(provider)
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()

                    TextField("Model label (display only)", text: $preferredModelDraft)
                        .textFieldStyle(.roundedBorder)

                    Picker("Fallback", selection: $fallbackPolicyDraft) {
                        ForEach(SoniqueBarFallbackPolicy.allCases) { policy in
                            Text(policy.label).tag(policy)
                        }
                    }
                    .pickerStyle(.menu)

                    Text(fallbackPolicyDraft.routingHint)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)

                    if nvidiaFeatureDraft {
                        TextField("NVIDIA endpoint base URL", text: $nvidiaBaseURLDraft)
                            .textFieldStyle(.roundedBorder)
                        Text("Use a placeholder-friendly URL; API keys are never stored here.")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
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
                        ? "Embedded — bundled Python runtime with STT, TTS, and voice agent. Requires Ollama installed separately for local LLM."
                        : "Networked — uses the Docker-based CAAL stack in the directory above. Keep if you already run CAAL for other tools.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Divider()

                // Home Assistant
                VStack(alignment: .leading, spacing: 4) {
                    Text("Home Assistant (optional)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    TextField("http://192.168.0.x:8123", text: $haURLDraft)
                        .textFieldStyle(.roundedBorder)
                    SecureField("Long-lived access token", text: $haTokenDraft)
                        .textFieldStyle(.roundedBorder)
                    Text("Enables voice control of lights, switches, covers, and more.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Divider()

                // Launch at login
                Toggle("Launch at login", isOn: $launchAtLoginDraft)
                    .toggleStyle(.switch)
                    .controlSize(.small)
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
            launchAtLoginDraft  = monitor.settings.launchAtLogin
            haURLDraft          = monitor.settings.haURL
            haTokenDraft        = monitor.settings.haToken
            llmProviderDraft    = monitor.settings.llmProvider
            preferredModelDraft = monitor.settings.preferredModelLabel
            fallbackPolicyDraft = monitor.settings.fallbackPolicy
            nvidiaBaseURLDraft  = monitor.settings.nvidiaBaseURL
            nvidiaFeatureDraft  = monitor.settings.nvidiaFeatureEnabled
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
        monitor.settings.launchAtLogin = launchAtLoginDraft
        monitor.settings.haURL         = haURLDraft.trimmingCharacters(in: .whitespaces)
        monitor.settings.haToken       = haTokenDraft.trimmingCharacters(in: .whitespaces)
        monitor.settings.nvidiaFeatureEnabled = nvidiaFeatureDraft
        monitor.settings.llmProvider   = llmProviderDraft
        monitor.settings.preferredModelLabel = preferredModelDraft.trimmingCharacters(in: .whitespaces)
        monitor.settings.fallbackPolicy = fallbackPolicyDraft
        monitor.settings.nvidiaBaseURL = nvidiaBaseURLDraft.trimmingCharacters(in: .whitespaces)

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

    /// Task #284: extend `settings` with `LLMRoutingCAALKeys` fields when CAAL `/api/settings` accepts them.
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
