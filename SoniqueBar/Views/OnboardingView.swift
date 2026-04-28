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
    @State private var scanSummary = "Not scanned yet."
    @State private var isScanning = false
    @State private var quickStartStep: QuickStartStep = .mode
    @State private var lastScan: QuickStartScanResult?
    @State private var hostCalendarDraft = true
    @State private var hostContactsDraft = true
    @State private var hostMailDraft = true
    @State private var hostFilesDraft = true
    @State private var iosBridgeDraft = true
    @State private var isRunningDoctor = false
    @State private var doctorResults: [DoctorCheck] = []

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
            Text(monitor.settings.isConfigured ? "Settings" : "Set up Sonique")
                .font(.headline)

            quickStartSection

            Picker("Step", selection: $quickStartStep) {
                ForEach(QuickStartStep.allCases) { step in
                    Text(step.label).tag(step)
                }
            }
            .pickerStyle(.segmented)

            wizardStepContent

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
        }
        .padding(24)
        .frame(minWidth: 360, idealWidth: 480, maxWidth: 720, minHeight: 560, idealHeight: 760)
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
            hostCalendarDraft   = monitor.settings.capabilityHostCalendar
            hostContactsDraft   = monitor.settings.capabilityHostContacts
            hostMailDraft       = monitor.settings.capabilityHostMail
            hostFilesDraft      = monitor.settings.capabilityHostFiles
            iosBridgeDraft      = monitor.settings.capabilityIOSBridge
            if scanSummary == "Not scanned yet." {
                scanSummary = "Run Quick Start Scan to auto-detect local tooling and paths."
            }
        }
    }

    private var quickStartSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Quick Start")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                if isScanning {
                    ProgressView()
                        .controlSize(.small)
                }
                Button("Scan") {
                    Task { await runQuickStartScan() }
                }
                .buttonStyle(.borderedProminent)
                .disabled(isScanning)
            }
            Text(scanSummary)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(10)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private func detectTailscale() async {
        if let ip = await monitor.detectTailscaleIP() {
            externalDraft = "http://\(ip):3100"
        }
    }

    private func runQuickStartScan() async {
        isScanning = true
        defer { isScanning = false }

        let scan = await Task.detached(priority: .userInitiated) {
            QuickStartScanner.scan()
        }.value

        if !scan.detectedCaelPath.isEmpty {
            caelDirDraft = scan.detectedCaelPath
        }
        if deploymentModeDraft == .networked, scan.hasBundledRuntime {
            deploymentModeDraft = .embedded
        }
        if scan.hasNvidiaHints, nvidiaBaseURLDraft.isEmpty {
            nvidiaFeatureDraft = true
            nvidiaBaseURLDraft = "https://integrate.api.nvidia.com/v1"
        }

        let cliLine = scan.detectedCLIs.isEmpty ? "none" : scan.detectedCLIs.joined(separator: ", ")
        let modelLine = scan.detectedModelRuntime
        let vaultLine = scan.detectedVaultPath.isEmpty ? "none" : scan.detectedVaultPath
        scanSummary = """
        Found: Docker \(scan.hasDocker ? "yes" : "no"), model runtime \(modelLine), CLIs \(cliLine), vault \(vaultLine).
        Suggested mode: \(scan.recommendedModeLabel). CAAL path auto-filled when detected.
        """
        lastScan = scan
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
        monitor.settings.capabilityHostCalendar = hostCalendarDraft
        monitor.settings.capabilityHostContacts = hostContactsDraft
        monitor.settings.capabilityHostMail = hostMailDraft
        monitor.settings.capabilityHostFiles = hostFilesDraft
        monitor.settings.capabilityIOSBridge = iosBridgeDraft

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

    @ViewBuilder
    private var wizardStepContent: some View {
        switch quickStartStep {
        case .mode:
            modeStep
        case .models:
            modelStep
        case .capabilities:
            capabilitiesStep
        case .knowledge:
            knowledgeStep
        case .doctor:
            doctorStep
        }
    }

    private var modeStep: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Mode selection")
                .font(.subheadline.weight(.semibold))
            Picker("Deployment mode", selection: $deploymentModeDraft) {
                ForEach(SidecarManager.DeploymentMode.allCases) { mode in
                    Text(mode.label).tag(mode)
                }
            }
            .pickerStyle(.menu)
            Text(deploymentModeDraft == .embedded
                 ? "Embedded is recommended for local-first installs with bundled runtime."
                 : "Networked keeps Docker-based CAAL stack compatibility with lab workflows.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var modelStep: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Model + provider setup")
                .font(.subheadline.weight(.semibold))
            Toggle("NVIDIA NIM options (experimental)", isOn: $nvidiaFeatureDraft)
                .toggleStyle(.switch)
                .controlSize(.small)
                .onChange(of: nvidiaFeatureDraft) { _, enabled in
                    if !enabled, llmProviderDraft == .nvidia { llmProviderDraft = .ollama }
                }
            Picker("Provider", selection: $llmProviderDraft) {
                ForEach(nvidiaFeatureDraft ? SoniqueBarLLMProvider.allCases : [.ollama]) { provider in
                    Text(provider.label).tag(provider)
                }
            }
            .pickerStyle(.menu)
            TextField("Model label (display only)", text: $preferredModelDraft)
                .textFieldStyle(.roundedBorder)
            Picker("Fallback", selection: $fallbackPolicyDraft) {
                ForEach(SoniqueBarFallbackPolicy.allCases) { policy in
                    Text(policy.label).tag(policy)
                }
            }
            .pickerStyle(.menu)
            if nvidiaFeatureDraft {
                TextField("NVIDIA endpoint base URL", text: $nvidiaBaseURLDraft)
                    .textFieldStyle(.roundedBorder)
            }
            Text(fallbackPolicyDraft.routingHint)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var capabilitiesStep: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Capabilities setup")
                .font(.subheadline.weight(.semibold))
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
            Text("Home Assistant (optional)")
                .font(.caption)
                .foregroundStyle(.secondary)
            TextField("http://192.168.0.x:8123", text: $haURLDraft)
                .textFieldStyle(.roundedBorder)
            SecureField("Long-lived access token", text: $haTokenDraft)
                .textFieldStyle(.roundedBorder)
            Toggle("Launch at login", isOn: $launchAtLoginDraft)
                .toggleStyle(.switch)
                .controlSize(.small)
            Divider()
            Toggle("Host calendar access", isOn: $hostCalendarDraft)
                .toggleStyle(.switch)
                .controlSize(.small)
            Toggle("Host contacts access", isOn: $hostContactsDraft)
                .toggleStyle(.switch)
                .controlSize(.small)
            Toggle("Host mail access", isOn: $hostMailDraft)
                .toggleStyle(.switch)
                .controlSize(.small)
            Toggle("Host files access", isOn: $hostFilesDraft)
                .toggleStyle(.switch)
                .controlSize(.small)
            Toggle("iOS bridge fallback", isOn: $iosBridgeDraft)
                .toggleStyle(.switch)
                .controlSize(.small)
        }
    }

    private var knowledgeStep: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Knowledge + memory setup")
                .font(.subheadline.weight(.semibold))
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
                    if panel.runModal() == .OK, let url = panel.url { caelDirDraft = url.path }
                } label: {
                    Image(systemName: "folder")
                }
                .buttonStyle(.bordered)
            }
            Text("Remote URL (optional)")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack(spacing: 6) {
                TextField("http://100.x.x.x:3100 or tunnel URL", text: $externalDraft)
                    .textFieldStyle(.roundedBorder)
                Button("Tailscale") { Task { await detectTailscale() } }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
            SecureField("API Key (optional)", text: $keyDraft)
                .textFieldStyle(.roundedBorder)
        }
    }

    private var doctorStep: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Doctor checks")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                if isRunningDoctor {
                    ProgressView().controlSize(.small)
                }
                Button("Run checks") {
                    Task { await runDoctorChecks() }
                }
                .buttonStyle(.borderedProminent)
                .disabled(isRunningDoctor)
            }
            doctorRow("CAAL configured", ok: !caelDirDraft.trimmingCharacters(in: .whitespaces).isEmpty)
            doctorRow("Backend online", ok: monitor.isOnline)
            doctorRow("Docker detected", ok: lastScan?.hasDocker == true)
            doctorRow("Ollama detected", ok: lastScan?.hasOllama == true)
            doctorRow("CLIs detected", ok: !(lastScan?.detectedCLIs.isEmpty ?? true))
            if doctorResults.isEmpty {
                Text("Run checks for API reachability, Docker daemon status, CLI availability, and routing policy endpoint.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(doctorResults) { check in
                    doctorResultRow(check)
                }
            }
            Text("These checks are local diagnostics and safe to rerun.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func runDoctorChecks() async {
        isRunningDoctor = true
        defer { isRunningDoctor = false }
        doctorResults = await QuickStartScanner.runDoctor(
            effectiveURL: monitor.settings.effectiveURL,
            backendURL: monitor.settings.backendURL
        )
    }

    private func doctorResultRow(_ check: DoctorCheck) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: check.ok ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundStyle(check.ok ? Color.green : Color.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text(check.label)
                    .font(.caption.weight(.semibold))
                Text(check.detail)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func doctorRow(_ label: String, ok: Bool) -> some View {
        HStack {
            Image(systemName: ok ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundStyle(ok ? Color.green : Color.orange)
            Text(label)
                .font(.caption)
        }
    }
}

private struct DoctorCheck: Identifiable {
    let id = UUID()
    let label: String
    let ok: Bool
    let detail: String
}

private enum QuickStartStep: String, CaseIterable, Identifiable {
    case mode, models, capabilities, knowledge, doctor

    var id: String { rawValue }
    var label: String {
        switch self {
        case .mode: return "Mode"
        case .models: return "Models"
        case .capabilities: return "Capabilities"
        case .knowledge: return "Knowledge"
        case .doctor: return "Doctor"
        }
    }
}

private struct QuickStartScanResult {
    let hasDocker: Bool
    let hasOllama: Bool
    let hasBundledRuntime: Bool
    let detectedCLIs: [String]
    let detectedVaultPath: String
    let detectedCaelPath: String
    let hasNvidiaHints: Bool

    var detectedModelRuntime: String { hasOllama ? "ollama" : "none" }
    var recommendedModeLabel: String {
        if hasBundledRuntime { return "Embedded" }
        if hasDocker { return "Networked" }
        return "Embedded (after local runtime install)"
    }
}

private enum QuickStartScanner {
    static func scan() -> QuickStartScanResult {
        let hasDocker = commandExists("docker")
        let hasOllama = commandExists("ollama")
        let hasBundledRuntime = Bundle.main.url(forResource: "python-runtime", withExtension: "tar.gz") != nil

        let cliCandidates = [
            ("claude", "Claude CLI"),
            ("gemini", "Gemini CLI"),
            ("cursor", "Cursor CLI"),
            ("gh", "GitHub CLI")
        ]
        let detectedCLIs = cliCandidates
            .filter { commandExists($0.0) }
            .map(\.1)

        let home = NSHomeDirectory()
        let vaultPath = "\(home)/Library/Mobile Documents/iCloud~md~obsidian/Documents/SeaynicNet"
        let detectedVaultPath = FileManager.default.fileExists(atPath: vaultPath) ? vaultPath : ""

        let caelCandidates = [
            "\(home)/Projects/cael",
            "\(home)/Projects/CAEL",
            "\(home)/Code/cael"
        ]
        let detectedCaelPath = caelCandidates.first(where: { FileManager.default.fileExists(atPath: $0) }) ?? ""

        let nvidiaHints = hasOllama || commandExists("nvidia-smi")

        return QuickStartScanResult(
            hasDocker: hasDocker,
            hasOllama: hasOllama,
            hasBundledRuntime: hasBundledRuntime,
            detectedCLIs: detectedCLIs,
            detectedVaultPath: detectedVaultPath,
            detectedCaelPath: detectedCaelPath,
            hasNvidiaHints: nvidiaHints
        )
    }

    static func runDoctor(effectiveURL: String, backendURL: String) async -> [DoctorCheck] {
        async let frontend = endpointReachable("\(effectiveURL)/health")
        async let backend = endpointReachable("\(backendURL)/routing/policy")
        let dockerDaemon = commandSucceeds(["docker", "info"])
        let ghAuth = commandSucceeds(["gh", "auth", "status"])
        let claudeAvailable = commandExists("claude")
        let geminiAvailable = commandExists("gemini")
        let cursorAvailable = commandExists("cursor")

        return [
            DoctorCheck(label: "Frontend API health", ok: await frontend, detail: "\(effectiveURL)/health"),
            DoctorCheck(label: "Routing policy endpoint", ok: await backend, detail: "\(backendURL)/routing/policy"),
            DoctorCheck(label: "Docker daemon reachable", ok: dockerDaemon, detail: "docker info"),
            DoctorCheck(label: "GitHub CLI auth", ok: ghAuth, detail: "gh auth status"),
            DoctorCheck(label: "Claude CLI available", ok: claudeAvailable, detail: "command: claude"),
            DoctorCheck(label: "Gemini CLI available", ok: geminiAvailable, detail: "command: gemini"),
            DoctorCheck(label: "Cursor CLI available", ok: cursorAvailable, detail: "command: cursor")
        ]
    }

    private static func endpointReachable(_ rawURL: String) async -> Bool {
        guard let url = URL(string: rawURL) else { return false }
        var request = URLRequest(url: url, timeoutInterval: 4)
        request.httpMethod = "GET"
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else { return false }
            return (200..<500).contains(http.statusCode)
        } catch {
            return false
        }
    }

    private static func commandSucceeds(_ args: [String]) -> Bool {
        guard !args.isEmpty else { return false }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = args
        p.standardOutput = Pipe()
        p.standardError = Pipe()
        do {
            try p.run()
            p.waitUntilExit()
            return p.terminationStatus == 0
        } catch {
            return false
        }
    }

    private static func commandExists(_ command: String) -> Bool {
        commandSucceeds(["which", command])
    }
}
