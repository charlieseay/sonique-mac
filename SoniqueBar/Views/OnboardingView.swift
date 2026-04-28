import SwiftUI
import Contacts
import EventKit
import UniformTypeIdentifiers

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
    @State private var isRunningPreflightRepair = false
    @State private var lastPreflightAt: Date?
    @State private var preflightTrend = PreflightTrendSummary.empty

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
            HStack {
                Button("Import profile") { importProfile() }
                    .buttonStyle(.bordered)
                Button("Export profile") { exportProfile() }
                    .buttonStyle(.bordered)
                Button("Export runtime contract") { exportRuntimeContract() }
                    .buttonStyle(.bordered)
                Button("Preflight repair") {
                    Task { await runPreflightRepair() }
                }
                .buttonStyle(.borderedProminent)
                .disabled(isRunningPreflightRepair)
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
        publishRuntimeContract()
        dismissWindow(id: "settings")
        dismiss()
    }

    private func exportProfile() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType.json]
        panel.nameFieldStringValue = "sonique-onboarding-profile.json"
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }

        let profile = OnboardingProfile(
            caelDirectory: caelDirDraft,
            externalURL: externalDraft,
            apiKey: keyDraft,
            ttsVoiceId: ttsVoiceDraft,
            deploymentMode: deploymentModeDraft.rawValue,
            launchAtLogin: launchAtLoginDraft,
            haURL: haURLDraft,
            haToken: haTokenDraft,
            llmProvider: llmProviderDraft.rawValue,
            preferredModelLabel: preferredModelDraft,
            fallbackPolicy: fallbackPolicyDraft.rawValue,
            nvidiaBaseURL: nvidiaBaseURLDraft,
            nvidiaFeatureEnabled: nvidiaFeatureDraft,
            capabilityHostCalendar: hostCalendarDraft,
            capabilityHostContacts: hostContactsDraft,
            capabilityHostMail: hostMailDraft,
            capabilityHostFiles: hostFilesDraft,
            capabilityIOSBridge: iosBridgeDraft
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(profile) {
            try? data.write(to: url, options: Data.WritingOptions.atomic)
        }
    }

    private func importProfile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType.json]
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard let data = try? Data(contentsOf: url),
              let profile = try? JSONDecoder().decode(OnboardingProfile.self, from: data) else {
            return
        }

        caelDirDraft = profile.caelDirectory
        externalDraft = profile.externalURL
        keyDraft = profile.apiKey
        ttsVoiceDraft = profile.ttsVoiceId
        deploymentModeDraft = SidecarManager.DeploymentMode(rawValue: profile.deploymentMode) ?? deploymentModeDraft
        launchAtLoginDraft = profile.launchAtLogin
        haURLDraft = profile.haURL
        haTokenDraft = profile.haToken
        llmProviderDraft = SoniqueBarLLMProvider(rawValue: profile.llmProvider) ?? llmProviderDraft
        preferredModelDraft = profile.preferredModelLabel
        fallbackPolicyDraft = SoniqueBarFallbackPolicy(rawValue: profile.fallbackPolicy) ?? fallbackPolicyDraft
        nvidiaBaseURLDraft = profile.nvidiaBaseURL
        nvidiaFeatureDraft = profile.nvidiaFeatureEnabled
        hostCalendarDraft = profile.capabilityHostCalendar
        hostContactsDraft = profile.capabilityHostContacts
        hostMailDraft = profile.capabilityHostMail
        hostFilesDraft = profile.capabilityHostFiles
        iosBridgeDraft = profile.capabilityIOSBridge
        scanSummary = "Imported profile from \(url.lastPathComponent). Review and Save to apply."
    }

    private func exportRuntimeContract() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType.json]
        panel.nameFieldStringValue = "sonique-runtime-contract.json"
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }

        let contract = OnboardingRuntimeContract(
            generatedAtISO8601: ISO8601DateFormatter().string(from: Date()),
            deploymentMode: deploymentModeDraft.rawValue,
            llmProvider: llmProviderDraft.rawValue,
            fallbackPolicy: fallbackPolicyDraft.rawValue,
            preferredModelLabel: preferredModelDraft,
            capabilityHostCalendar: hostCalendarDraft,
            capabilityHostContacts: hostContactsDraft,
            capabilityHostMail: hostMailDraft,
            capabilityHostFiles: hostFilesDraft,
            capabilityIOSBridge: iosBridgeDraft,
            dockerDetected: lastScan?.hasDocker ?? false,
            ollamaDetected: lastScan?.hasOllama ?? false,
            detectedCLIs: lastScan?.detectedCLIs ?? [],
            routingPolicyURL: "\(monitor.settings.backendURL)/routing/policy",
            backendHealthURL: "\(monitor.settings.backendURL)/health",
            frontendHealthURL: "\(monitor.settings.effectiveURL)/health",
            expectedSimpleProvider: llmProviderDraft == .ollama ? "ollama" : "openai_compatible",
            contractPullPath: url.path,
            contractPullURL: monitor.contractEndpoint.runtimeContractPullURL ?? "",
            preflightTrendPullURL: monitor.contractEndpoint.preflightTrendPullURL ?? ""
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(contract) {
            try? data.write(to: url, options: Data.WritingOptions.atomic)
        }
    }

    private func runPreflightRepair() async {
        isRunningPreflightRepair = true
        defer { isRunningPreflightRepair = false }
        let started = Date()

        await runQuickStartScan()

        if deploymentModeDraft == .embedded {
            await monitor.sidecarManager.start()
        } else {
            await monitor.containerManager.setup(caelDirectory: caelDirDraft.trimmingCharacters(in: .whitespaces))
        }

        monitor.startPolling()
        await runDoctorChecks()
        lastPreflightAt = Date()
        exportPreflightTelemetry(startedAt: started, finishedAt: lastPreflightAt ?? Date())
        publishRuntimeContract()
        scanSummary = "Preflight repair completed. Contract + telemetry published. Review Doctor results, then Save if configuration looks correct."
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
                preflightTrendView
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
            backendURL: monitor.settings.backendURL,
            expectedSimpleProvider: llmProviderDraft == .ollama ? "ollama" : "openai_compatible"
        )
        preflightTrend = loadPreflightTrendSummary()
    }

    private var preflightTrendView: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Preflight trend")
                .font(.caption.weight(.semibold))
            Text("Runs: \(preflightTrend.sampleCount) • Pass rate: \(Int(preflightTrend.passRate * 100))% • Avg duration: \(String(format: "%.1fs", preflightTrend.avgDurationSeconds))")
                .font(.caption2)
                .foregroundStyle(.secondary)
            ForEach(preflightTrend.lastRuns) { run in
                HStack(spacing: 6) {
                    Image(systemName: run.failingChecks == 0 ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .foregroundStyle(run.failingChecks == 0 ? Color.green : Color.orange)
                    Text(run.generatedAtISO8601)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                    Text("fail: \(run.failingChecks)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.top, 4)
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
            Spacer(minLength: 8)
            if !check.ok, let remediation = check.remediation {
                Button("Fix") {
                    Task { await applyRemediation(remediation) }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
    }

    private func applyRemediation(_ remediation: DoctorRemediation) async {
        switch remediation {
        case .openDockerApp:
            NSWorkspace.shared.open(URL(fileURLWithPath: "/Applications/Docker.app"))
        case .openContactsPrivacy:
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Contacts") {
                NSWorkspace.shared.open(url)
            }
        case .openCalendarPrivacy:
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars") {
                NSWorkspace.shared.open(url)
            }
        case .openGitHubCLIAuthDocs:
            if let url = URL(string: "https://cli.github.com/manual/gh_auth_login") {
                NSWorkspace.shared.open(url)
            }
        case .openClaudeCLIInstallDocs:
            if let url = URL(string: "https://docs.anthropic.com/en/docs/claude-code") {
                NSWorkspace.shared.open(url)
            }
        case .openGeminiCLIInstallDocs:
            if let url = URL(string: "https://github.com/google-gemini/gemini-cli") {
                NSWorkspace.shared.open(url)
            }
        case .openCursorCLIInstallDocs:
            if let url = URL(string: "https://docs.cursor.com/en/cli/overview") {
                NSWorkspace.shared.open(url)
            }
        case .openFrontendURL(let raw):
            if let url = URL(string: raw) {
                NSWorkspace.shared.open(url)
            }
        case .openBackendURL(let raw):
            if let url = URL(string: raw) {
                NSWorkspace.shared.open(url)
            }
        case .openSidecarLogs:
            let path = ("~/Library/Logs/SoniqueBar" as NSString).expandingTildeInPath
            NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: path)
        case .requestContactsPermission:
            let store = CNContactStore()
            _ = try? await store.requestAccess(for: .contacts)
            await runDoctorChecks()
        case .requestCalendarPermission:
            let store = EKEventStore()
            if #available(macOS 14.0, *) {
                _ = try? await store.requestFullAccessToEvents()
            } else {
                _ = try? await store.requestAccess(to: .event)
            }
            await runDoctorChecks()
        case .publishRuntimeContract:
            publishRuntimeContract()
        }
    }

    private func publishRuntimeContract() {
        let fm = FileManager.default
        let root = ("~/Library/Application Support/SoniqueBar/contracts" as NSString).expandingTildeInPath
        let dirURL = URL(fileURLWithPath: root, isDirectory: true)
        try? fm.createDirectory(at: dirURL, withIntermediateDirectories: true)
        let target = dirURL.appendingPathComponent("runtime-contract.latest.json")
        let endpointFile = dirURL.appendingPathComponent("runtime-contract.endpoint.txt")
        let contract = OnboardingRuntimeContract(
            generatedAtISO8601: ISO8601DateFormatter().string(from: Date()),
            deploymentMode: deploymentModeDraft.rawValue,
            llmProvider: llmProviderDraft.rawValue,
            fallbackPolicy: fallbackPolicyDraft.rawValue,
            preferredModelLabel: preferredModelDraft,
            capabilityHostCalendar: hostCalendarDraft,
            capabilityHostContacts: hostContactsDraft,
            capabilityHostMail: hostMailDraft,
            capabilityHostFiles: hostFilesDraft,
            capabilityIOSBridge: iosBridgeDraft,
            dockerDetected: lastScan?.hasDocker ?? false,
            ollamaDetected: lastScan?.hasOllama ?? false,
            detectedCLIs: lastScan?.detectedCLIs ?? [],
            routingPolicyURL: "\(monitor.settings.backendURL)/routing/policy",
            backendHealthURL: "\(monitor.settings.backendURL)/health",
            frontendHealthURL: "\(monitor.settings.effectiveURL)/health",
            expectedSimpleProvider: llmProviderDraft == .ollama ? "ollama" : "openai_compatible",
            contractPullPath: target.path,
            contractPullURL: monitor.contractEndpoint.runtimeContractPullURL ?? "",
            preflightTrendPullURL: monitor.contractEndpoint.preflightTrendPullURL ?? ""
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(contract) {
            try? data.write(to: target, options: Data.WritingOptions.atomic)
            try? target.path.write(to: endpointFile, atomically: true, encoding: .utf8)
            scanSummary = "Published runtime contract to \(target.path)"
        }
    }

    private func exportPreflightTelemetry(startedAt: Date, finishedAt: Date) {
        let fm = FileManager.default
        let root = ("~/Library/Application Support/SoniqueBar/contracts" as NSString).expandingTildeInPath
        let dirURL = URL(fileURLWithPath: root, isDirectory: true)
        try? fm.createDirectory(at: dirURL, withIntermediateDirectories: true)
        let target = dirURL.appendingPathComponent("preflight-telemetry.latest.json")

        let total = doctorResults.count
        let passing = doctorResults.filter(\.ok).count
        let failing = max(0, total - passing)
        let telemetry = PreflightTelemetry(
            generatedAtISO8601: ISO8601DateFormatter().string(from: Date()),
            startedAtISO8601: ISO8601DateFormatter().string(from: startedAt),
            finishedAtISO8601: ISO8601DateFormatter().string(from: finishedAt),
            durationSeconds: finishedAt.timeIntervalSince(startedAt),
            deploymentMode: deploymentModeDraft.rawValue,
            llmProvider: llmProviderDraft.rawValue,
            totalChecks: total,
            passingChecks: passing,
            failingChecks: failing,
            failedCheckLabels: doctorResults.filter { !$0.ok }.map(\.label)
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(telemetry) {
            try? data.write(to: target, options: Data.WritingOptions.atomic)
            appendTelemetryHistory(telemetry, in: dirURL)
            preflightTrend = loadPreflightTrendSummary()
        }
    }

    private func appendTelemetryHistory(_ telemetry: PreflightTelemetry, in dirURL: URL) {
        let historyURL = dirURL.appendingPathComponent("preflight-telemetry.history.jsonl")
        let encoder = JSONEncoder()
        guard let lineData = try? encoder.encode(telemetry),
              let line = String(data: lineData, encoding: .utf8) else { return }
        if let fh = try? FileHandle(forWritingTo: historyURL) {
            fh.seekToEndOfFile()
            if let data = (line + "\n").data(using: .utf8) { fh.write(data) }
            try? fh.close()
        } else {
            try? (line + "\n").write(to: historyURL, atomically: true, encoding: .utf8)
        }
        trimTelemetryHistory(historyURL: historyURL, keepLast: 50)
    }

    private func trimTelemetryHistory(historyURL: URL, keepLast: Int) {
        guard let content = try? String(contentsOf: historyURL, encoding: .utf8) else { return }
        var lines = content.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        if lines.count <= keepLast { return }
        lines = Array(lines.suffix(keepLast))
        try? (lines.joined(separator: "\n") + "\n").write(to: historyURL, atomically: true, encoding: .utf8)
    }

    private func loadPreflightTrendSummary() -> PreflightTrendSummary {
        let historyPath = ("~/Library/Application Support/SoniqueBar/contracts/preflight-telemetry.history.jsonl" as NSString).expandingTildeInPath
        guard let raw = try? String(contentsOfFile: historyPath, encoding: .utf8) else {
            return .empty
        }
        let decoder = JSONDecoder()
        let entries: [PreflightTelemetry] = raw
            .split(separator: "\n", omittingEmptySubsequences: true)
            .compactMap { line in
                guard let data = line.data(using: .utf8) else { return nil }
                return try? decoder.decode(PreflightTelemetry.self, from: data)
            }
        guard !entries.isEmpty else { return .empty }
        let totalChecks = entries.reduce(0) { $0 + $1.totalChecks }
        let totalPassing = entries.reduce(0) { $0 + $1.passingChecks }
        let passRate = totalChecks == 0 ? 0.0 : Double(totalPassing) / Double(totalChecks)
        let avgDuration = entries.reduce(0.0) { $0 + $1.durationSeconds } / Double(entries.count)
        let lastRuns = Array(entries.suffix(5)).reversed()
        return PreflightTrendSummary(
            sampleCount: entries.count,
            passRate: passRate,
            avgDurationSeconds: avgDuration,
            lastRuns: Array(lastRuns)
        )
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
    let remediation: DoctorRemediation?
}

private enum DoctorRemediation {
    case openDockerApp
    case openContactsPrivacy
    case openCalendarPrivacy
    case openGitHubCLIAuthDocs
    case openClaudeCLIInstallDocs
    case openGeminiCLIInstallDocs
    case openCursorCLIInstallDocs
    case openFrontendURL(String)
    case openBackendURL(String)
    case openSidecarLogs
    case requestContactsPermission
    case requestCalendarPermission
    case publishRuntimeContract
}

private struct OnboardingProfile: Codable {
    let caelDirectory: String
    let externalURL: String
    let apiKey: String
    let ttsVoiceId: String
    let deploymentMode: String
    let launchAtLogin: Bool
    let haURL: String
    let haToken: String
    let llmProvider: String
    let preferredModelLabel: String
    let fallbackPolicy: String
    let nvidiaBaseURL: String
    let nvidiaFeatureEnabled: Bool
    let capabilityHostCalendar: Bool
    let capabilityHostContacts: Bool
    let capabilityHostMail: Bool
    let capabilityHostFiles: Bool
    let capabilityIOSBridge: Bool
}

private struct OnboardingRuntimeContract: Codable {
    let generatedAtISO8601: String
    let deploymentMode: String
    let llmProvider: String
    let fallbackPolicy: String
    let preferredModelLabel: String
    let capabilityHostCalendar: Bool
    let capabilityHostContacts: Bool
    let capabilityHostMail: Bool
    let capabilityHostFiles: Bool
    let capabilityIOSBridge: Bool
    let dockerDetected: Bool
    let ollamaDetected: Bool
    let detectedCLIs: [String]
    let routingPolicyURL: String
    let backendHealthURL: String
    let frontendHealthURL: String
    let expectedSimpleProvider: String
    let contractPullPath: String
    let contractPullURL: String
    let preflightTrendPullURL: String
}

private struct PreflightTelemetry: Codable {
    let generatedAtISO8601: String
    let startedAtISO8601: String
    let finishedAtISO8601: String
    let durationSeconds: TimeInterval
    let deploymentMode: String
    let llmProvider: String
    let totalChecks: Int
    let passingChecks: Int
    let failingChecks: Int
    let failedCheckLabels: [String]
}

private struct PreflightTrendSummary {
    let sampleCount: Int
    let passRate: Double
    let avgDurationSeconds: TimeInterval
    let lastRuns: [PreflightTelemetry]

    static let empty = PreflightTrendSummary(sampleCount: 0, passRate: 0, avgDurationSeconds: 0, lastRuns: [])
}

extension PreflightTelemetry: Identifiable {
    var id: String { generatedAtISO8601 + ":\(failingChecks)" }
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

    static func runDoctor(
        effectiveURL: String,
        backendURL: String,
        expectedSimpleProvider: String
    ) async -> [DoctorCheck] {
        async let frontend = endpointReachable("\(effectiveURL)/health")
        async let backend = endpointReachable("\(backendURL)/routing/policy")
        async let backendHealth = endpointReachable("\(backendURL)/health")
        async let sttHealth = endpointReachable("http://127.0.0.1:8081/health")
        async let ttsHealth = endpointReachable("http://127.0.0.1:8082/health")
        async let policyParity = routingPolicyParityCheck(
            backendURL: backendURL,
            expectedSimpleProvider: expectedSimpleProvider
        )
        let dockerDaemon = commandSucceeds(["docker", "info"])
        let ghAuth = commandSucceeds(["gh", "auth", "status"])
        let claudeAvailable = commandExists("claude")
        let geminiAvailable = commandExists("gemini")
        let cursorAvailable = commandExists("cursor")

        let contactsStatus = contactsPermissionLabel()
        let calendarStatus = calendarPermissionLabel()
        let localFilesReadable = FileManager.default.isReadableFile(atPath: NSHomeDirectory())
        let parity = await policyParity
        let publishedContractPath = ("~/Library/Application Support/SoniqueBar/contracts/runtime-contract.latest.json" as NSString).expandingTildeInPath
        let contractPublished = FileManager.default.fileExists(atPath: publishedContractPath)

        return [
            DoctorCheck(label: "Frontend API health", ok: await frontend, detail: "\(effectiveURL)/health", remediation: .openFrontendURL("\(effectiveURL)/health")),
            DoctorCheck(label: "Routing policy endpoint", ok: await backend, detail: "\(backendURL)/routing/policy", remediation: .openBackendURL("\(backendURL)/routing/policy")),
            DoctorCheck(label: "Backend health endpoint", ok: await backendHealth, detail: "\(backendURL)/health", remediation: .openBackendURL("\(backendURL)/health")),
            DoctorCheck(label: "Sidecar STT health", ok: await sttHealth, detail: "http://127.0.0.1:8081/health", remediation: .openSidecarLogs),
            DoctorCheck(label: "Sidecar TTS health", ok: await ttsHealth, detail: "http://127.0.0.1:8082/health", remediation: .openSidecarLogs),
            DoctorCheck(label: "Docker daemon reachable", ok: dockerDaemon, detail: "docker info", remediation: dockerDaemon ? nil : .openDockerApp),
            DoctorCheck(label: "GitHub CLI auth", ok: ghAuth, detail: "gh auth status", remediation: ghAuth ? nil : .openGitHubCLIAuthDocs),
            DoctorCheck(label: "Claude CLI available", ok: claudeAvailable, detail: "command: claude", remediation: claudeAvailable ? nil : .openClaudeCLIInstallDocs),
            DoctorCheck(label: "Gemini CLI available", ok: geminiAvailable, detail: "command: gemini", remediation: geminiAvailable ? nil : .openGeminiCLIInstallDocs),
            DoctorCheck(label: "Cursor CLI available", ok: cursorAvailable, detail: "command: cursor", remediation: cursorAvailable ? nil : .openCursorCLIInstallDocs),
            DoctorCheck(label: "Contacts permission", ok: contactsStatus == "authorized", detail: contactsStatus, remediation: contactsRemediation(status: contactsStatus)),
            DoctorCheck(label: "Calendar permission", ok: calendarStatus == "full_access" || calendarStatus == "write_only" || calendarStatus == "authorized", detail: calendarStatus, remediation: calendarRemediation(status: calendarStatus)),
            DoctorCheck(label: "Local files readable", ok: localFilesReadable, detail: NSHomeDirectory(), remediation: nil),
            DoctorCheck(label: "Routing policy parity", ok: parity.ok, detail: parity.detail, remediation: parity.ok ? nil : .openBackendURL("\(backendURL)/routing/policy")),
            DoctorCheck(label: "Runtime contract published", ok: contractPublished, detail: publishedContractPath, remediation: contractPublished ? nil : .publishRuntimeContract)
        ]
    }

    private static func contactsRemediation(status: String) -> DoctorRemediation? {
        if status == "authorized" { return nil }
        if status == "not_determined" { return .requestContactsPermission }
        return .openContactsPrivacy
    }

    private static func calendarRemediation(status: String) -> DoctorRemediation? {
        if status == "full_access" || status == "write_only" || status == "authorized" { return nil }
        if status == "not_determined" { return .requestCalendarPermission }
        return .openCalendarPrivacy
    }

    private static func routingPolicyParityCheck(
        backendURL: String,
        expectedSimpleProvider: String
    ) async -> (ok: Bool, detail: String) {
        guard let url = URL(string: "\(backendURL)/routing/policy") else {
            return (false, "invalid policy URL")
        }
        do {
            let (data, response) = try await URLSession.shared.data(for: URLRequest(url: url, timeoutInterval: 4))
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                return (false, "policy endpoint unavailable")
            }
            guard
                let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                let policy = root["policy"] as? [String: Any],
                let tiers = policy["tiers"] as? [[String: Any]],
                let simple = tiers.first(where: { ($0["label"] as? String) == "simple" }),
                let provider = simple["provider"] as? String
            else {
                return (false, "policy payload missing simple tier")
            }
            if provider == expectedSimpleProvider {
                return (true, "simple tier provider = \(provider)")
            }
            return (false, "simple tier provider \(provider) != expected \(expectedSimpleProvider)")
        } catch {
            return (false, "policy fetch failed")
        }
    }

    private static func contactsPermissionLabel() -> String {
        switch CNContactStore.authorizationStatus(for: .contacts) {
        case .authorized: return "authorized"
        case .notDetermined: return "not_determined"
        case .denied: return "denied"
        case .restricted: return "restricted"
        @unknown default: return "unknown"
        }
    }

    private static func calendarPermissionLabel() -> String {
        if #available(macOS 14.0, *) {
            switch EKEventStore.authorizationStatus(for: .event) {
            case .fullAccess: return "full_access"
            case .writeOnly: return "write_only"
            case .notDetermined: return "not_determined"
            case .denied: return "denied"
            case .restricted: return "restricted"
            @unknown default: return "unknown"
            }
        } else {
            switch EKEventStore.authorizationStatus(for: .event) {
            case .authorized: return "authorized"
            case .fullAccess: return "full_access"
            case .writeOnly: return "write_only"
            case .notDetermined: return "not_determined"
            case .denied: return "denied"
            case .restricted: return "restricted"
            @unknown default: return "unknown"
            }
        }
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
