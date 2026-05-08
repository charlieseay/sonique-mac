import SwiftUI
import Contacts
import EventKit
import UniformTypeIdentifiers

struct OnboardingView: View {
    @EnvironmentObject var monitor: ServerMonitor
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dismissWindow) private var dismissWindow
    @Environment(\.openWindow) private var openWindow

    @State private var caelDirDraft = "~/Projects/cael"
    @State private var externalDraft = ""
    @State private var keyDraft = ""
    @State private var ttsVoiceDraft = PiperVoice.defaultVoice.id
    @State private var deploymentModeDraft: SidecarManager.DeploymentMode = .embedded
    @State private var launchAtLoginDraft = true
    @State private var haURLDraft = ""
    @State private var haTokenDraft = ""
    @State private var llmProviderDraft: SoniqueBarLLMProvider = .ollama
    @State private var preferredModelDraft = "gemma4"
    @State private var fallbackPolicyDraft: SoniqueBarFallbackPolicy = .localOnly
    @State private var nvidiaBaseURLDraft = ""
    @State private var nvidiaApiKeyDraft = ""
    @State private var nvidiaModelDraft = "meta/llama-3.1-70b-instruct"
    @State private var nvidiaFeatureDraft = false
    @State private var helmsmanURLDraft = "http://localhost:5682"
    @State private var dispatchURLDraft = "http://localhost:5680"
    @State private var mcpProxyHostDraft = "localhost"
    @State private var labConnectionNote = ""
    @State private var scanSummary = "Not scanned yet."
    @State private var isScanning = false
    @State private var quickStartStep: QuickStartStep = .mode
    @State private var connectionProfileDraft: ConnectionProfile = .standard
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
    @State private var memoryHealth = MemoryHealthSnapshot.empty
    @State private var autoRemediationEnabled = true
    @State private var attemptedAutoRemediations: Set<String> = []
    @State private var showBulkPermissionPrompt = false
    @State private var pendingPermissionNeeds: [BulkPermissionNeed] = []
    @State private var suppressAutoPermissionPrompt = false
    @State private var doctorAutoFixStatus = "Idle"
    @AppStorage("soniquebar.doctor.requireHostCLIs") private var requireHostCLIs = false
    @State private var stagedCredentialImport: StagedCredentialImport?
    @State private var didSendCredentialIntakePrompt = false
    @State private var showAdvancedFallbacks = false
    @State private var isAutoSetupRunning = false
    @State private var autoSetupStatus = "Not started"

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
            Text(monitor.settings.isConfigured ? "Settings" : "Set up Sonique")
                .font(.headline)

            quickStartSection
            setupProgressSection
            labInfrastructureSection

            if showAdvancedFallbacks {
                Picker("Step", selection: $quickStartStep) {
                    ForEach(QuickStartStep.allCases) { step in
                        Text(step.label).tag(step)
                    }
                }
                .pickerStyle(.segmented)

                wizardStepContent
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
            nvidiaApiKeyDraft   = monitor.settings.nvidiaApiKey
            nvidiaModelDraft    = monitor.settings.nvidiaModel
            nvidiaFeatureDraft  = monitor.settings.nvidiaFeatureEnabled
            helmsmanURLDraft    = monitor.settings.helmsmanURL
            dispatchURLDraft    = monitor.settings.dispatchURL
            mcpProxyHostDraft   = monitor.settings.mcpProxyHost
            hostCalendarDraft   = monitor.settings.capabilityHostCalendar
            hostContactsDraft   = monitor.settings.capabilityHostContacts
            hostMailDraft       = monitor.settings.capabilityHostMail
            hostFilesDraft      = monitor.settings.capabilityHostFiles
            iosBridgeDraft      = monitor.settings.capabilityIOSBridge
            hostCalendarDraft   = false
            hostContactsDraft   = false
            connectionProfileDraft = inferConnectionProfile()
            if scanSummary == "Not scanned yet." {
                scanSummary = "Run Quick Start Scan to auto-detect local tooling and paths."
            }
            refreshMemoryHealth()
            Task { await runDoctorChecks(autoRemediate: autoRemediationEnabled) }
        }
        .alert(
            "Allow SoniqueBar access for setup?",
            isPresented: $showBulkPermissionPrompt
        ) {
            Button("Reset and re-request permissions") {
                suppressAutoPermissionPrompt = true
                Task { await resetAndRerequestPermissions() }
            }
            Button("Allow selected permissions") {
                suppressAutoPermissionPrompt = true
                Task { await applyBulkPermissionDecision(allow: true) }
            }
            Button("Reject and disable related tools", role: .destructive) {
                suppressAutoPermissionPrompt = true
                Task { await applyBulkPermissionDecision(allow: false) }
            }
            Button("Cancel", role: .cancel) {
                suppressAutoPermissionPrompt = true
                doctorAutoFixStatus = "Permission prompt dismissed"
            }
        } message: {
            Text(bulkPermissionPromptMessage())
        }
    }

    private var quickStartSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Quick Start")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                if isAutoSetupRunning {
                    ProgressView()
                        .controlSize(.small)
                }
                Button("Auto setup (recommended)") {
                    Task { await runAutoSetup() }
                }
                .buttonStyle(.borderedProminent)
                .disabled(isAutoSetupRunning || isScanning || isRunningDoctor)
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
            Text("Auto setup: \(autoSetupStatus)")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(10)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private var setupProgressSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Setup progress")
                .font(.subheadline.weight(.semibold))
            checklistRow("Runtime started", ok: monitor.isOnline)
            checklistRow("Voice services healthy", ok: voiceServicesHealthy)
            checklistRow("Learning memory active", ok: memoryHealth.janitorMode != "unknown")
            checklistRow("Assistant profile loaded", ok: monitor.profile != nil)
            if isReadyToTalk {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.seal.fill")
                        .foregroundStyle(Color.green)
                    Text("Ready to talk. Sonique is live and learning.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Open Chat") {
                        openWindow(id: "chat")
                        NSApp.activate(ignoringOtherApps: true)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                }
            } else {
                Text("Tip: Click Auto setup (recommended), wait until complete, then Open Chat.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(10)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private var labInfrastructureSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Lab infrastructure")
                .font(.subheadline.weight(.semibold))
            Text("Helmsman DB, dispatch webhook host, and MCP proxy hostname are passed into the embedded CAAL sidecar.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            TextField("Helmsman URL", text: $helmsmanURLDraft)
                .textFieldStyle(.roundedBorder)
            TextField("Dispatch base URL (no /webhook path)", text: $dispatchURLDraft)
                .textFieldStyle(.roundedBorder)
            TextField("MCP proxy host", text: $mcpProxyHostDraft)
                .textFieldStyle(.roundedBorder)
            Button("Test connections") {
                Task { await testLabConnections() }
            }
            .buttonStyle(.bordered)
            if !labConnectionNote.isEmpty {
                Text(labConnectionNote)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(10)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private func testLabConnections() async {
        var lines: [String] = []
        let hm = helmsmanURLDraft.trimmingCharacters(in: .whitespaces)
        if let u = URL(string: hm + "/tasks?status=pending&limit=1") {
            var req = URLRequest(url: u, timeoutInterval: 4)
            do {
                let (_, resp) = try await URLSession.shared.data(for: req)
                let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
                lines.append("Helmsman: HTTP \(code)")
            } catch {
                lines.append("Helmsman: failed (\(error.localizedDescription))")
            }
        } else {
            lines.append("Helmsman: bad URL")
        }
        let host = mcpProxyHostDraft.trimmingCharacters(in: .whitespaces)
        if let u = URL(string: "http://\(host):3700/vault/mcp") {
            var req = URLRequest(url: u, timeoutInterval: 4)
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = Data(#"{"jsonrpc":"2.0","method":"initialize","params":{},"id":1}"#.utf8)
            do {
                let (_, resp) = try await URLSession.shared.data(for: req)
                let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
                lines.append("MCP proxy: HTTP \(code)")
            } catch {
                lines.append("MCP proxy: failed (\(error.localizedDescription))")
            }
        }
        let dBase = dispatchURLDraft.trimmingCharacters(in: .whitespaces)
        if let u = URL(string: dBase) {
            var req = URLRequest(url: u, timeoutInterval: 4)
            do {
                let (_, resp) = try await URLSession.shared.data(for: req)
                let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
                lines.append("Dispatch host: HTTP \(code)")
            } catch {
                lines.append("Dispatch host: failed (\(error.localizedDescription))")
            }
        }
        labConnectionNote = lines.joined(separator: " · ")
    }

    private var voiceServicesHealthy: Bool {
        let labels = doctorResults.filter { $0.ok }.map(\.label)
        return labels.contains("Sidecar STT health") && labels.contains("Sidecar TTS health")
    }

    private var isReadyToTalk: Bool {
        monitor.isOnline && voiceServicesHealthy && memoryHealth.janitorMode != "unknown" && monitor.profile != nil
    }

    private func checklistRow(_ label: String, ok: Bool) -> some View {
        HStack(spacing: 8) {
            Image(systemName: ok ? "checkmark.circle.fill" : "circle.dotted")
                .foregroundStyle(ok ? Color.green : Color.secondary)
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
        }
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
        if scan.hasNvidiaHints, nvidiaBaseURLDraft.isEmpty {
            nvidiaFeatureDraft = true
            nvidiaBaseURLDraft = "https://integrate.api.nvidia.com/v1"
        }

        let cliLine = scan.detectedCLIs.isEmpty ? "none" : scan.detectedCLIs.joined(separator: ", ")
        let modelLine = scan.detectedModelRuntime
        let vaultLine = scan.detectedVaultPath.isEmpty ? "none" : scan.detectedVaultPath
        scanSummary = """
        Found: model runtime \(modelLine), CLIs \(cliLine), vault \(vaultLine).
        Runtime: embedded sidecar. CAAL path auto-filled when detected.
        """
        lastScan = scan
    }

    private func runAutoSetup() async {
        isAutoSetupRunning = true
        defer { isAutoSetupRunning = false }

        autoSetupStatus = "Scanning your environment..."
        await runQuickStartScan()

        autoSetupStatus = "Starting embedded runtime..."
        await monitor.sidecarManager.start()
        monitor.startPolling()

        autoSetupStatus = "Running doctor checks and applying safe fixes..."
        await runDoctorChecks(autoRemediate: true)

        autoSetupStatus = "Applying recommended defaults..."
        if llmProviderDraft != .ollama { llmProviderDraft = .ollama }
        if fallbackPolicyDraft == .providerThenLocal { fallbackPolicyDraft = .localOnly }
        monitor.settings.capabilityHostCalendar = false
        monitor.settings.capabilityHostContacts = false
        hostCalendarDraft = false
        hostContactsDraft = false

        refreshMemoryHealth()
        publishRuntimeContract()
        autoSetupStatus = "Ready. Sonique is running and learning from this device."
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
        monitor.settings.nvidiaApiKey = nvidiaApiKeyDraft.trimmingCharacters(in: .whitespaces)
        monitor.settings.nvidiaModel = nvidiaModelDraft.trimmingCharacters(in: .whitespaces)
        monitor.settings.helmsmanURL = helmsmanURLDraft.trimmingCharacters(in: .whitespaces)
        monitor.settings.dispatchURL = dispatchURLDraft.trimmingCharacters(in: .whitespaces)
        monitor.settings.mcpProxyHost = mcpProxyHostDraft.trimmingCharacters(in: .whitespaces)
        monitor.settings.capabilityHostCalendar = false
        monitor.settings.capabilityHostContacts = false
        monitor.settings.capabilityHostMail = hostMailDraft
        monitor.settings.capabilityHostFiles = hostFilesDraft
        monitor.settings.capabilityIOSBridge = iosBridgeDraft

        Task { await monitor.sidecarManager.start() }

        Task { await syncVoice() }
        Task { await syncRoutingSkillAccess() }
        Task { await syncConnectedProfileIfNeeded() }
        monitor.startPolling()
        publishRuntimeContract()
        dismissWindow(id: "settings")
        dismiss()
    }

    private func inferConnectionProfile() -> ConnectionProfile {
        if nvidiaFeatureDraft || !haURLDraft.trimmingCharacters(in: .whitespaces).isEmpty {
            return .connectedLab
        }
        return .standard
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
            nvidiaApiKey: nvidiaApiKeyDraft,
            nvidiaModel: nvidiaModelDraft,
            nvidiaFeatureEnabled: nvidiaFeatureDraft,
            helmsmanURL: helmsmanURLDraft,
            dispatchURL: dispatchURLDraft,
            mcpProxyHost: mcpProxyHostDraft,
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
        nvidiaApiKeyDraft = profile.nvidiaApiKey ?? ""
        nvidiaModelDraft = profile.nvidiaModel ?? "meta/llama-3.1-70b-instruct"
        nvidiaFeatureDraft = profile.nvidiaFeatureEnabled
        if let v = profile.helmsmanURL { helmsmanURLDraft = v }
        if let v = profile.dispatchURL { dispatchURLDraft = v }
        if let v = profile.mcpProxyHost { mcpProxyHostDraft = v }
        hostCalendarDraft = profile.capabilityHostCalendar
        hostContactsDraft = profile.capabilityHostContacts
        hostMailDraft = profile.capabilityHostMail
        hostFilesDraft = profile.capabilityHostFiles
        iosBridgeDraft = profile.capabilityIOSBridge
        scanSummary = "Imported profile from \(url.lastPathComponent). Review and Save to apply."
    }

    private func startCredentialIntakeWithCael() {
        doctorAutoFixStatus = "Credential intake started"
        Task {
            let suggestedDirectory = await suggestedCredentialDirectoryFromChat()
            if suggestedDirectory == nil, !didSendCredentialIntakePrompt {
                await openChatIntake(reason: "Ask where credentials are stored, what file types to read, and confirm explicit permission before ingesting")
                didSendCredentialIntakePrompt = true
            }
            await MainActor.run {
                importCredentialsFromSelection(startingDirectory: suggestedDirectory, autoApply: true)
            }
        }
    }

    private func importCredentialsFromSelection(startingDirectory: URL?, autoApply: Bool) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType.data]
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.directoryURL = startingDirectory ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
        panel.prompt = "Stage credentials"
        panel.message = "Select approved credential files or folders. SoniqueBar reads only selected items and stages detected fields for your review."
        guard panel.runModal() == .OK else {
            doctorAutoFixStatus = "Credential import cancelled"
            return
        }
        let urls = collectCredentialCandidateFiles(from: panel.urls)
        guard !urls.isEmpty else {
            doctorAutoFixStatus = "No readable credential files found in selection"
            return
        }

        var imported: Set<String> = []
        var staged = StagedCredentialImport()
        staged.sourceFiles = urls.map(\.lastPathComponent)
        for url in urls {
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            let entries = parseCredentialText(text)
            if let value = entries["CAAL_API_KEY"] ?? entries["API_KEY"] ?? entries["SONIQUE_API_KEY"] ?? entries["OPENAI_API_KEY"] {
                staged.apiKey = value
                imported.insert("API Key")
            }
            if let value = entries["HA_TOKEN"] ?? entries["HOME_ASSISTANT_TOKEN"] {
                staged.haToken = value
                imported.insert("Home Assistant token")
            }
            if let value = entries["HA_URL"] ?? entries["HOME_ASSISTANT_URL"] {
                staged.haURL = value
                imported.insert("Home Assistant URL")
            }
            if let value = entries["NVIDIA_BASE_URL"] {
                staged.nvidiaBaseURL = value
                imported.insert("NVIDIA base URL")
            }
            if let value = entries["EXTERNAL_URL"] {
                staged.externalURL = value
                imported.insert("External URL")
            }
        }

        if imported.isEmpty {
            doctorAutoFixStatus = "No recognized credentials found in selected files"
        } else {
            staged.detectedFields = imported.sorted()
            stagedCredentialImport = staged
            if autoApply {
                applyStagedCredentialImport()
                doctorAutoFixStatus = "Credentials imported automatically from approved selection"
                scanSummary = "Credentials were imported from your approved selection. You can still re-import or overwrite manually."
            } else {
                doctorAutoFixStatus = "Credential import staged. Review and apply."
                scanSummary = "Credentials staged from your approved selection. Apply or discard in Credential sources."
            }
        }
    }

    private func collectCredentialCandidateFiles(from selection: [URL]) -> [URL] {
        let fm = FileManager.default
        var files: [URL] = []
        let allowedExtensions = Set(["txt", "env", "json", "md", "yaml", "yml", "ini", "conf"])

        for url in selection {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else { continue }
            if isDir.boolValue {
                guard let enumerator = fm.enumerator(at: url, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey], options: [.skipsHiddenFiles]) else {
                    continue
                }
                for case let candidate as URL in enumerator {
                    let ext = candidate.pathExtension.lowercased()
                    guard allowedExtensions.contains(ext) else { continue }
                    guard
                        let values = try? candidate.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
                        values.isRegularFile == true,
                        (values.fileSize ?? 0) <= 512_000
                    else { continue }
                    files.append(candidate)
                }
            } else {
                let ext = url.pathExtension.lowercased()
                if allowedExtensions.contains(ext) {
                    files.append(url)
                }
            }
        }
        return files
    }

    private func applyStagedCredentialImport() {
        guard let staged = stagedCredentialImport else { return }
        if let value = staged.apiKey { keyDraft = value }
        if let value = staged.haToken { haTokenDraft = value }
        if let value = staged.haURL { haURLDraft = value }
        if let value = staged.nvidiaBaseURL { nvidiaBaseURLDraft = value }
        if let value = staged.externalURL { externalDraft = value }
        stagedCredentialImport = nil
        doctorAutoFixStatus = "Applied imported credentials to draft settings"
    }

    private func parseCredentialText(_ text: String) -> [String: String] {
        var result: [String: String] = [:]
        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty || line.hasPrefix("#") { continue }
            let separators = ["=", ":"]
            var found: (String, String)?
            for sep in separators {
                if let symbol = sep.first, let idx = line.firstIndex(of: symbol) {
                    let key = String(line[..<idx]).trimmingCharacters(in: .whitespaces).uppercased()
                    var value = String(line[line.index(after: idx)...]).trimmingCharacters(in: .whitespaces)
                    value = value.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
                    if !key.isEmpty, !value.isEmpty {
                        found = (key, value)
                    }
                    break
                }
            }
            if let found {
                result[found.0] = found.1
                continue
            }

            // Human-readable fallback labels:
            // "API Key: xxx", "Home Assistant Token: xxx", etc.
            let lowered = line.lowercased()
            if let value = trailingValue(after: "api key", in: line), lowered.contains("api key") {
                result["API_KEY"] = value
            } else if let value = trailingValue(after: "home assistant token", in: line), lowered.contains("home assistant token") {
                result["HOME_ASSISTANT_TOKEN"] = value
            } else if let value = trailingValue(after: "ha token", in: line), lowered.contains("ha token") {
                result["HA_TOKEN"] = value
            } else if let value = trailingValue(after: "home assistant url", in: line), lowered.contains("home assistant url") {
                result["HOME_ASSISTANT_URL"] = value
            } else if let value = trailingValue(after: "ha url", in: line), lowered.contains("ha url") {
                result["HA_URL"] = value
            } else if let value = trailingValue(after: "external url", in: line), lowered.contains("external url") {
                result["EXTERNAL_URL"] = value
            } else if let value = trailingValue(after: "nvidia base url", in: line), lowered.contains("nvidia base url") {
                result["NVIDIA_BASE_URL"] = value
            }
        }
        return result
    }

    private func trailingValue(after label: String, in line: String) -> String? {
        guard let range = line.range(of: label, options: [.caseInsensitive]) else { return nil }
        var tail = String(line[range.upperBound...]).trimmingCharacters(in: .whitespaces)
        if tail.hasPrefix(":") || tail.hasPrefix("=") {
            tail.removeFirst()
            tail = tail.trimmingCharacters(in: .whitespaces)
        }
        tail = tail.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        return tail.isEmpty ? nil : tail
    }

    private func suggestedCredentialDirectoryFromChat() async -> URL? {
        guard let url = URL(string: "\(monitor.settings.backendURL)/api/chat/history?session_id=sonique-main") else {
            return nil
        }
        var req = URLRequest(url: url, timeoutInterval: 6)
        if !monitor.settings.apiKey.isEmpty {
            req.setValue(monitor.settings.apiKey, forHTTPHeaderField: "x-api-key")
        }
        guard
            let (data, _) = try? await URLSession.shared.data(for: req),
            let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let rawMessages = payload["messages"] as? [[String: String]]
        else { return nil }

        let userMessages = rawMessages.reversed().filter { ($0["role"] ?? "") == "user" }
        let regex = try? NSRegularExpression(pattern: "/Users/[^\\n]+", options: [])
        for message in userMessages {
            guard let content = message["content"], let regex else { continue }
            let range = NSRange(location: 0, length: content.utf16.count)
            guard let match = regex.firstMatch(in: content, options: [], range: range),
                  let r = Range(match.range, in: content) else { continue }
            let rawPath = String(content[r]).trimmingCharacters(in: .whitespacesAndNewlines)
            let candidateURL = URL(fileURLWithPath: rawPath)
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: candidateURL.path, isDirectory: &isDir) {
                return isDir.boolValue ? candidateURL : candidateURL.deletingLastPathComponent()
            }
        }
        return nil
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
            dockerDetected: false,
            ollamaDetected: lastScan?.hasOllama ?? false,
            detectedCLIs: lastScan?.detectedCLIs ?? [],
            routingPolicyURL: "\(monitor.settings.backendURL)/routing/policy",
            backendHealthURL: "\(monitor.settings.backendURL)/health",
            frontendHealthURL: "\(monitor.settings.effectiveURL)/health",
            expectedSimpleProvider: llmProviderDraft.caalProviderString,
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

        await monitor.sidecarManager.start()

        monitor.startPolling()
        await runDoctorChecks()
        lastPreflightAt = Date()
        exportPreflightTelemetry(startedAt: started, finishedAt: lastPreflightAt ?? Date())
        publishRuntimeContract()
        scanSummary = "Preflight repair completed. Contract + telemetry published. Review Doctor results, then Save if configuration looks correct."
    }

    /// Task #284: extend `settings` with `LLMRoutingCAALKeys` fields when CAAL `/api/settings` accepts them.
    private func syncVoice() async {
        guard let url = URL(string: "\(monitor.settings.backendURL)/settings") else { return }
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

    private func syncRoutingSkillAccess() async {
        guard let url = URL(string: "\(monitor.settings.backendURL)/settings") else { return }

        let selectedProvider = llmProviderDraft.caalProviderString
        let fallback = fallbackPolicyDraft.rawValue

        var payload: [String: Any] = [
            LLMRoutingCAALKeys.provider: selectedProvider,
            LLMRoutingCAALKeys.modelLabel: preferredModelDraft.trimmingCharacters(in: .whitespaces),
            LLMRoutingCAALKeys.fallbackPolicy: fallback,
            LLMRoutingCAALKeys.nvidiaFeatureEnabled: nvidiaFeatureDraft
        ]

        let simpleProvider: String
        let mediumProvider: String
        let complexProvider: String

        switch fallbackPolicyDraft {
        case .localOnly:
            simpleProvider = "ollama"
            mediumProvider = "ollama"
            complexProvider = "ollama"
        case .providerThenLocal:
            simpleProvider = selectedProvider
            mediumProvider = selectedProvider
            complexProvider = "ollama"
        case .localThenProvider:
            simpleProvider = "ollama"
            mediumProvider = selectedProvider
            complexProvider = "claude_cli"
        }

        payload["router_simple_provider"] = simpleProvider
        payload["router_medium_provider"] = mediumProvider
        payload["router_complex_provider"] = complexProvider

        let trimmedNvidiaURL = nvidiaBaseURLDraft.trimmingCharacters(in: .whitespaces)
        if selectedProvider == "openai_compatible", !trimmedNvidiaURL.isEmpty {
            payload[LLMRoutingCAALKeys.cloudInferenceBaseURL] = trimmedNvidiaURL
            payload["openai_base_url"] = trimmedNvidiaURL
        }

        payload["nvidia_enabled"] = nvidiaFeatureDraft
        if !trimmedNvidiaURL.isEmpty {
            payload["nvidia_base_url"] = trimmedNvidiaURL
        }
        let trimmedNvidiaKey = nvidiaApiKeyDraft.trimmingCharacters(in: .whitespaces)
        if !trimmedNvidiaKey.isEmpty {
            payload["nvidia_api_key"] = trimmedNvidiaKey
        }
        let trimmedNvidiaModel = nvidiaModelDraft.trimmingCharacters(in: .whitespaces)
        if !trimmedNvidiaModel.isEmpty {
            payload["nvidia_model"] = trimmedNvidiaModel
        }

        guard let body = try? JSONSerialization.data(withJSONObject: ["settings": payload]) else { return }
        var req = URLRequest(url: url, timeoutInterval: 6)
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
            Picker("Connection profile", selection: $connectionProfileDraft) {
                ForEach(ConnectionProfile.allCases) { profile in
                    Text(profile.label).tag(profile)
                }
            }
            .pickerStyle(.menu)
            .onChange(of: connectionProfileDraft) { _, profile in
                applyConnectionProfileDefaults(profile)
            }
            Text("Deployment mode: Embedded (bundled sidecar)")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("Sonique runs locally and starts itself. You do not need to manage infrastructure.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func applyConnectionProfileDefaults(_ profile: ConnectionProfile) {
        switch profile {
        case .standard:
            if llmProviderDraft == .nvidia { llmProviderDraft = .ollama }
            if fallbackPolicyDraft == .providerThenLocal {
                fallbackPolicyDraft = .localOnly
            }
        case .connectedLab:
            nvidiaFeatureDraft = true
            if nvidiaBaseURLDraft.trimmingCharacters(in: .whitespaces).isEmpty {
                nvidiaBaseURLDraft = "https://integrate.api.nvidia.com/v1"
            }
            fallbackPolicyDraft = .localThenProvider
            hostCalendarDraft = false
            hostContactsDraft = false
            hostMailDraft = true
            hostFilesDraft = true
            iosBridgeDraft = true
        }
    }

    private func syncConnectedProfileIfNeeded() async {
        guard connectionProfileDraft == .connectedLab else { return }
        guard let url = URL(string: "\(monitor.settings.backendURL)/settings") else { return }

        let hassHost = haURLDraft.trimmingCharacters(in: .whitespaces)
        let hassToken = haTokenDraft.trimmingCharacters(in: .whitespaces)
        let hasHass = !hassHost.isEmpty && !hassToken.isEmpty
        let openAIBase = nvidiaBaseURLDraft.trimmingCharacters(in: .whitespaces)

        var settingsPayload: [String: Any] = [
            "llm_provider": llmProviderDraft.caalProviderString,
            "router_simple_provider": llmProviderDraft.caalProviderString,
            "router_medium_provider": llmProviderDraft == .ollama ? "ollama" : "openai_compatible",
            "router_complex_provider": "claude_cli",
            "n8n_enabled": true
        ]
        if !openAIBase.isEmpty {
            settingsPayload["openai_base_url"] = openAIBase
        }
        settingsPayload["hass_enabled"] = hasHass
        if hasHass {
            settingsPayload["hass_host"] = hassHost
            settingsPayload["hass_token"] = hassToken
        }

        guard let body = try? JSONSerialization.data(withJSONObject: ["settings": settingsPayload]) else { return }
        var req = URLRequest(url: url, timeoutInterval: 6)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !monitor.settings.apiKey.isEmpty {
            req.setValue(monitor.settings.apiKey, forHTTPHeaderField: "x-api-key")
        }
        req.httpBody = body
        _ = try? await URLSession.shared.data(for: req)
    }

    private var modelStep: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Model + provider setup")
                .font(.subheadline.weight(.semibold))
            Toggle("NVIDIA NIM options (experimental)", isOn: $nvidiaFeatureDraft)
                .toggleStyle(.switch)
                .controlSize(.small)
                .onChange(of: nvidiaFeatureDraft) { _, enabled in
                    if !enabled, llmProviderDraft == .nvidia { llmProviderDraft = .anthropic }
                }
            Picker("Provider", selection: $llmProviderDraft) {
                ForEach(monitor.settings.availableProviders) { provider in
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
                SecureField("NVIDIA API key", text: $nvidiaApiKeyDraft)
                    .textFieldStyle(.roundedBorder)
                TextField("NVIDIA model name", text: $nvidiaModelDraft)
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
            Toggle("Host calendar access (temporarily disabled)", isOn: .constant(false))
                .toggleStyle(.switch)
                .controlSize(.small)
                .disabled(true)
            Toggle("Host contacts access (temporarily disabled)", isOn: .constant(false))
                .toggleStyle(.switch)
                .controlSize(.small)
                .disabled(true)
            Text("Calendar/Contacts integration is temporarily disabled until we replace the permission path.")
                .font(.caption2)
                .foregroundStyle(.secondary)
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
            Divider()
            memoryHealthSection
        }
    }

    private var memoryHealthSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Memory health")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Refresh") { refreshMemoryHealth() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
            Text("Raw turns: \(memoryHealth.rawTurnCount) • Episodes: \(memoryHealth.episodeCount)")
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text("Janitor mode: \(memoryHealth.janitorMode)")
                .font(.caption2)
                .foregroundStyle(.secondary)
            if let lastRun = memoryHealth.lastRunAtISO8601 {
                Text("Last run: \(lastRun)")
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
            }
            if let compact = memoryHealth.lastCompactAtISO8601 {
                Text("Last compact: \(compact)")
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
            }
            Text(memoryHealth.personaSummary)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(8)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
    }

    private func refreshMemoryHealth() {
        memoryHealth = monitor.loadMemoryHealthSnapshot()
    }

    private var doctorStep: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Health checks")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                if isRunningDoctor {
                    ProgressView().controlSize(.small)
                }
                if showAdvancedFallbacks {
                    Button("Import credentials") {
                        startCredentialIntakeWithCael()
                    }
                    .buttonStyle(.bordered)
                    .disabled(isRunningDoctor)
                }
                Button("Auto-fix now") {
                    Task { await runDoctorChecks(autoRemediate: true) }
                }
                .buttonStyle(.bordered)
                .disabled(isRunningDoctor)
                Button("Run checks") {
                    Task { await runDoctorChecks(autoRemediate: autoRemediationEnabled) }
                }
                .buttonStyle(.borderedProminent)
                .disabled(isRunningDoctor)
            }
            HStack(spacing: 6) {
                Image(systemName: showBulkPermissionPrompt ? "exclamationmark.triangle.fill" : "wrench.and.screwdriver.fill")
                    .foregroundStyle(showBulkPermissionPrompt ? Color.orange : Color.blue)
                Text(showBulkPermissionPrompt ? "Needs approval: \(doctorAutoFixStatus)" : "Auto-fix status: \(doctorAutoFixStatus)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text("CLI mode: \(requireHostCLIs ? "Host CLI required" : "MCP-only")")
                .font(.caption2)
                .foregroundStyle(.secondary)
            Button(showAdvancedFallbacks ? "Hide advanced fallbacks" : "Show advanced fallbacks") {
                showAdvancedFallbacks.toggle()
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            if let staged = stagedCredentialImport {
                stagedCredentialImportPanel(staged)
            }
            doctorRow("CAAL configured", ok: !caelDirDraft.trimmingCharacters(in: .whitespaces).isEmpty)
            doctorRow("Backend online", ok: monitor.isOnline)
            doctorRow("Ollama detected", ok: lastScan?.hasOllama == true)
            doctorRow("CLIs detected", ok: !(lastScan?.detectedCLIs.isEmpty ?? true))
            if doctorResults.isEmpty {
                Text("Run checks for runtime health and setup readiness.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(doctorResults) { check in
                    doctorResultRow(check)
                }
                preflightTrendView
            }
            Text("These checks are local and safe to run again.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func stagedCredentialImportPanel(_ staged: StagedCredentialImport) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Credential sources")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Text("Staged from: \(staged.sourceFiles.joined(separator: ", "))")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text("Detected fields: \(staged.detectedFields.joined(separator: ", "))")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Button("Apply imported credentials") {
                    applyStagedCredentialImport()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                Button("Discard") {
                    stagedCredentialImport = nil
                    doctorAutoFixStatus = "Discarded staged credential import"
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
        .padding(8)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
    }

    private func runDoctorChecks(autoRemediate: Bool = false) async {
        isRunningDoctor = true
        if autoRemediate {
            attemptedAutoRemediations = []
            doctorAutoFixStatus = "Scanning and applying fixes..."
        } else {
            doctorAutoFixStatus = "Scan complete"
        }
        defer { isRunningDoctor = false }
        doctorResults = await QuickStartScanner.runDoctor(
            effectiveURL: monitor.settings.effectiveURL,
            backendURL: monitor.settings.backendURL,
            expectedSimpleProvider: llmProviderDraft.caalProviderString,
            requireHostCLIs: requireHostCLIs
        )
        preflightTrend = loadPreflightTrendSummary()
        if autoRemediate {
            await autoRemediateDoctorFailures()
            discoverBulkPermissionNeeds()
            if showBulkPermissionPrompt {
                doctorAutoFixStatus = "Permission decision required"
            } else {
                let remaining = doctorResults.filter { !$0.ok }.count
                doctorAutoFixStatus = remaining == 0 ? "All checks passing" : "Auto-fix complete, \(remaining) checks still failing"
            }
        }
    }

    private func autoRemediateDoctorFailures() async {
        var applied = 0
        for _ in 0..<4 {
            guard let candidate = doctorResults.first(where: { check in
                guard !check.ok, let remediation = check.remediation else { return false }
                return isAutoRemediable(remediation) && !attemptedAutoRemediations.contains(check.label)
            }), let remediation = candidate.remediation else {
                return
            }
            attemptedAutoRemediations.insert(candidate.label)
            await applyRemediation(remediation)
            applied += 1
        }
        if applied > 0 {
            doctorAutoFixStatus = "Applied \(applied) automatic remediation(s)"
        }
    }

    private func isAutoRemediable(_ remediation: DoctorRemediation) -> Bool {
        switch remediation {
        case .openGitHubCLIAuthDocs,
             .openClaudeCLIInstallDocs,
             .openGeminiCLIInstallDocs,
             .openCursorCLIInstallDocs,
             .openSidecarLogs,
             .publishRuntimeContract,
             .reconcileRoutingParity,
             .openChatIntake:
            return true
        case .openContactsPrivacy,
             .openCalendarPrivacy,
             .openFrontendURL,
             .openBackendURL,
             .requestContactsPermission,
             .requestCalendarPermission:
            return false
        }
    }

    private func discoverBulkPermissionNeeds() {
        guard !suppressAutoPermissionPrompt else { return }
        let needs = doctorResults.compactMap { check -> BulkPermissionNeed? in
            guard !check.ok, let remediation = check.remediation else { return nil }
            switch remediation {
            case .requestContactsPermission, .openContactsPrivacy: return .contacts
            case .requestCalendarPermission, .openCalendarPrivacy: return .calendar
            default: return nil
            }
        }
        let deduped = Array(Set(needs)).sorted { $0.rawValue < $1.rawValue }
        guard !deduped.isEmpty else { return }
        pendingPermissionNeeds = deduped
        showBulkPermissionPrompt = true
    }

    private func bulkPermissionPromptMessage() -> String {
        if pendingPermissionNeeds.isEmpty {
            return "No missing permissions detected."
        }
        let labels = pendingPermissionNeeds.map(\.label).joined(separator: ", ")
        return "Doctor detected missing permissions: \(labels). Approve once to request all at once."
    }

    private func applyBulkPermissionDecision(allow: Bool) async {
        defer {
            pendingPermissionNeeds = []
            showBulkPermissionPrompt = false
        }
        if allow {
            doctorAutoFixStatus = "Applying approved permissions..."
            if pendingPermissionNeeds.contains(.contacts) {
                let store = CNContactStore()
                switch CNContactStore.authorizationStatus(for: .contacts) {
                case .notDetermined:
                    _ = try? await store.requestAccess(for: .contacts)
                case .denied, .restricted:
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Contacts") {
                        NSWorkspace.shared.open(url)
                    }
                default:
                    break
                }
                hostContactsDraft = true
                monitor.settings.capabilityHostContacts = true
            }
            if pendingPermissionNeeds.contains(.calendar) {
                let store = EKEventStore()
                switch EKEventStore.authorizationStatus(for: .event) {
                case .notDetermined:
                    if #available(macOS 14.0, *) {
                        _ = try? await store.requestFullAccessToEvents()
                    } else {
                        _ = try? await store.requestAccess(to: .event)
                    }
                case .denied, .restricted:
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars") {
                        NSWorkspace.shared.open(url)
                    }
                default:
                    break
                }
                hostCalendarDraft = true
                monitor.settings.capabilityHostCalendar = true
            }
        } else {
            doctorAutoFixStatus = "Permissions rejected; disabling related tools..."
            if pendingPermissionNeeds.contains(.contacts) {
                hostContactsDraft = false
                monitor.settings.capabilityHostContacts = false
            }
            if pendingPermissionNeeds.contains(.calendar) {
                hostCalendarDraft = false
                monitor.settings.capabilityHostCalendar = false
            }
            await openChatIntake(reason: "user rejected one or more host permissions; confirm tool disablement preferences")
        }
        await runDoctorChecks()
    }

    private func resetAndRerequestPermissions() async {
        doctorAutoFixStatus = "Resetting permission state..."
        _ = localCommandSucceeds(["tccutil", "reset", "AddressBook", "com.seayniclabs.soniquebar"])
        _ = localCommandSucceeds(["tccutil", "reset", "Calendar", "com.seayniclabs.soniquebar"])

        if pendingPermissionNeeds.contains(.contacts) {
            let store = CNContactStore()
            _ = try? await store.requestAccess(for: .contacts)
        }
        if pendingPermissionNeeds.contains(.calendar) {
            let store = EKEventStore()
            if #available(macOS 14.0, *) {
                _ = try? await store.requestFullAccessToEvents()
            } else {
                _ = try? await store.requestAccess(to: .event)
            }
        }
        doctorAutoFixStatus = "Permission reset + re-request attempted"
        await runDoctorChecks()
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
                Text(humanDoctorLabel(for: check.label))
                    .font(.caption.weight(.semibold))
                Text(humanDoctorDetail(for: check))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            if !autoRemediationEnabled, !check.ok, let remediation = check.remediation {
                Button("Fix") {
                    Task { await applyRemediation(remediation) }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
    }

    private func humanDoctorLabel(for label: String) -> String {
        switch label {
        case "Backend health endpoint": return "Core runtime online"
        case "Routing policy endpoint": return "Routing service reachable"
        case "Sidecar STT health": return "Speech recognition ready"
        case "Sidecar TTS health": return "Voice output ready"
        case "GitHub CLI auth": return "External services access"
        case "Claude CLI available": return "Claude tools available"
        case "Gemini CLI available": return "Gemini tools available"
        case "Cursor CLI available": return "Cursor tools available"
        case "Runtime contract published": return "Runtime contract saved"
        default: return label
        }
    }

    private func humanDoctorDetail(for check: DoctorCheck) -> String {
        if check.ok { return "OK" }
        switch check.label {
        case "Sidecar STT health", "Sidecar TTS health":
            return "Voice services need a restart."
        case "Backend health endpoint":
            return "Core runtime is not responding yet."
        case "Routing policy endpoint":
            return "Routing service is not reachable yet."
        default:
            return check.detail
        }
    }

    private func applyRemediation(_ remediation: DoctorRemediation) async {
        switch remediation {
        case .openContactsPrivacy:
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Contacts") {
                NSWorkspace.shared.open(url)
            }
            doctorAutoFixStatus = "Contacts permission needs user approval in System Settings"
        case .openCalendarPrivacy:
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars") {
                NSWorkspace.shared.open(url)
            }
            doctorAutoFixStatus = "Calendar permission needs user approval in System Settings"
        case .openGitHubCLIAuthDocs:
            await runQuickStartScan()
            doctorAutoFixStatus = requireHostCLIs ? "GitHub CLI auth still missing" : "Using MCP mode; host GitHub CLI is optional"
        case .openClaudeCLIInstallDocs:
            await runQuickStartScan()
            doctorAutoFixStatus = requireHostCLIs ? "Claude CLI still missing" : "Using MCP mode; host Claude CLI is optional"
        case .openGeminiCLIInstallDocs:
            await runQuickStartScan()
            doctorAutoFixStatus = requireHostCLIs ? "Gemini CLI still missing" : "Using MCP mode; host Gemini CLI is optional"
        case .openCursorCLIInstallDocs:
            await runQuickStartScan()
            doctorAutoFixStatus = requireHostCLIs ? "Cursor CLI still missing" : "Using MCP mode; host Cursor CLI is optional"
        case .openFrontendURL(let raw):
            if let url = URL(string: raw) {
                NSWorkspace.shared.open(url)
            }
        case .openBackendURL(let raw):
            if let url = URL(string: raw) {
                NSWorkspace.shared.open(url)
            }
        case .openSidecarLogs:
            await restartRuntimeServices()
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
        case .reconcileRoutingParity(let expectedSimpleProvider):
            await reconcileRoutingParity(expectedSimpleProvider: expectedSimpleProvider)
        case .openChatIntake(let reason):
            doctorAutoFixStatus = reason
        }
    }

    private func restartRuntimeServices() async {
        await monitor.sidecarManager.start()
        await runDoctorChecks()
    }

    private func reconcileRoutingParity(expectedSimpleProvider: String) async {
        guard let url = URL(string: "\(monitor.settings.backendURL)/settings") else { return }
        var settingsPayload: [String: Any] = [:]
        settingsPayload["router_simple_provider"] = expectedSimpleProvider
        settingsPayload["llm_provider"] = expectedSimpleProvider
        guard let body = try? JSONSerialization.data(withJSONObject: ["settings": settingsPayload]) else { return }
        var req = URLRequest(url: url, timeoutInterval: 6)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !monitor.settings.apiKey.isEmpty {
            req.setValue(monitor.settings.apiKey, forHTTPHeaderField: "x-api-key")
        }
        req.httpBody = body
        _ = try? await URLSession.shared.data(for: req)
        await runDoctorChecks()
    }

    private func openChatIntake(reason: String) async {
        openWindow(id: "chat")
        NSApp.activate(ignoringOtherApps: true)
        guard let url = URL(string: "\(monitor.settings.backendURL)/api/chat") else { return }
        let prompt = intakePrompt(for: reason)
        guard let body = try? JSONSerialization.data(withJSONObject: [
            "text": prompt,
            "session_id": "sonique-main",
        ]) else { return }
        var req = URLRequest(url: url, timeoutInterval: 12)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !monitor.settings.apiKey.isEmpty {
            req.setValue(monitor.settings.apiKey, forHTTPHeaderField: "x-api-key")
        }
        req.httpBody = body
        _ = try? await URLSession.shared.data(for: req)
    }

    private func intakePrompt(for reason: String) -> String {
        let normalized = reason.lowercased()
        if normalized.contains("github cli auth") {
            return """
Auto-setup needs a quick decision:
1) Should I authenticate GitHub CLI on this Mac now?
2) If yes, is browser auth okay or do you prefer device code?
3) Should GitHub features stay enabled if auth is skipped?
"""
        }
        if normalized.contains("contacts permission") {
            return """
Auto-setup needs a quick decision:
1) Should SoniqueBar keep Contacts integration enabled?
2) If yes, please allow Contacts access in System Settings when prompted.
3) If no, should I permanently disable Contacts tools for this profile?
"""
        }
        if normalized.contains("calendar permission") {
            return """
Auto-setup needs a quick decision:
1) Should SoniqueBar keep Calendar integration enabled?
2) If yes, please allow Calendar access in System Settings when prompted.
3) If no, should I permanently disable Calendar tools for this profile?
"""
        }
        return """
Auto-setup needs a quick decision:
1) \(reason)
2) Do you want this capability enabled or disabled?
3) Should I continue auto-remediation after your answer?
"""
    }

    private func localCommandSucceeds(_ args: [String]) -> Bool {
        guard !args.isEmpty else { return false }
        if let resolved = localExecutablePath(args[0]) {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: resolved)
            p.arguments = Array(args.dropFirst())
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

    private func localExecutablePath(_ command: String) -> String? {
        let candidates = [
            "/opt/homebrew/bin/\(command)",
            "/usr/local/bin/\(command)",
            "/usr/bin/\(command)",
            "/bin/\(command)",
        ]
        return candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) })
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
            dockerDetected: false,
            ollamaDetected: lastScan?.hasOllama ?? false,
            detectedCLIs: lastScan?.detectedCLIs ?? [],
            routingPolicyURL: "\(monitor.settings.backendURL)/routing/policy",
            backendHealthURL: "\(monitor.settings.backendURL)/health",
            frontendHealthURL: "\(monitor.settings.effectiveURL)/health",
            expectedSimpleProvider: llmProviderDraft.caalProviderString,
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
    case reconcileRoutingParity(expectedSimpleProvider: String)
    case openChatIntake(reason: String)
}

private enum BulkPermissionNeed: String, Hashable {
    case contacts
    case calendar

    var label: String {
        switch self {
        case .contacts: return "Contacts"
        case .calendar: return "Calendar"
        }
    }
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
    let nvidiaApiKey: String?
    let nvidiaModel: String?
    let nvidiaFeatureEnabled: Bool
    let helmsmanURL: String?
    let dispatchURL: String?
    let mcpProxyHost: String?
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

private struct StagedCredentialImport {
    var apiKey: String?
    var haToken: String?
    var haURL: String?
    var nvidiaBaseURL: String?
    var externalURL: String?
    var sourceFiles: [String] = []
    var detectedFields: [String] = []
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

private enum ConnectionProfile: String, CaseIterable, Identifiable {
    case standard
    case connectedLab

    var id: String { rawValue }
    var label: String {
        switch self {
        case .standard: return "Standard (Easy Install)"
        case .connectedLab: return "Connected Lab (HA + NVIDIA + CLI)"
        }
    }
}

private struct QuickStartScanResult {
    let hasOllama: Bool
    let hasBundledRuntime: Bool
    let detectedCLIs: [String]
    let detectedVaultPath: String
    let detectedCaelPath: String
    let hasNvidiaHints: Bool

    var detectedModelRuntime: String { hasOllama ? "ollama" : "none" }
    var recommendedModeLabel: String { "Embedded" }
}

private enum QuickStartScanner {
    static func scan() -> QuickStartScanResult {
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
        expectedSimpleProvider: String,
        requireHostCLIs: Bool
    ) async -> [DoctorCheck] {
        _ = effectiveURL
        async let backend = endpointReachable("\(backendURL)/routing/policy")
        async let backendHealth = endpointReachable("\(backendURL)/health")
        async let sttHealth = endpointReachable("http://127.0.0.1:8081/health")
        async let ttsHealth = endpointReachable("http://127.0.0.1:8082/health")
        async let policyParity = routingPolicyParityCheck(
            backendURL: backendURL,
            expectedSimpleProvider: expectedSimpleProvider
        )
        let ghAuth = commandSucceeds(["gh", "auth", "status"])
        let claudeAvailable = commandExists("claude")
        let geminiAvailable = commandExists("gemini")
        let cursorAvailable = commandExists("cursor")
        let mcpAvailable = mcpToolingAvailable()

        let localFilesReadable = FileManager.default.isReadableFile(atPath: NSHomeDirectory())
        let parity = await policyParity
        let publishedContractPath = ("~/Library/Application Support/SoniqueBar/contracts/runtime-contract.latest.json" as NSString).expandingTildeInPath
        let contractPublished = FileManager.default.fileExists(atPath: publishedContractPath)

        let effectiveGHAAuth = requireHostCLIs ? ghAuth : (ghAuth || mcpAvailable)
        let effectiveClaude = requireHostCLIs ? claudeAvailable : (claudeAvailable || mcpAvailable)
        let effectiveGemini = requireHostCLIs ? geminiAvailable : (geminiAvailable || mcpAvailable)
        let effectiveCursor = requireHostCLIs ? cursorAvailable : (cursorAvailable || mcpAvailable)

        let ghDetail = requireHostCLIs
            ? "gh auth status"
            : (ghAuth ? "host gh authenticated" : (mcpAvailable ? "MCP available (host gh optional)" : "host gh missing, MCP not detected"))
        let claudeDetail = requireHostCLIs
            ? "command: claude"
            : (claudeAvailable ? "command: claude" : (mcpAvailable ? "MCP available (host claude optional)" : "command: claude"))
        let geminiDetail = requireHostCLIs
            ? "command: gemini"
            : (geminiAvailable ? "command: gemini" : (mcpAvailable ? "MCP available (host gemini optional)" : "command: gemini"))
        let cursorDetail = requireHostCLIs
            ? "command: cursor"
            : (cursorAvailable ? "command: cursor" : (mcpAvailable ? "MCP available (host cursor optional)" : "command: cursor"))

        return [
            DoctorCheck(label: "Routing policy endpoint", ok: await backend, detail: "\(backendURL)/routing/policy", remediation: .openBackendURL("\(backendURL)/routing/policy")),
            DoctorCheck(label: "Backend health endpoint", ok: await backendHealth, detail: "\(backendURL)/health", remediation: .openBackendURL("\(backendURL)/health")),
            DoctorCheck(label: "Sidecar STT health", ok: await sttHealth, detail: "http://127.0.0.1:8081/health", remediation: .openSidecarLogs),
            DoctorCheck(label: "Sidecar TTS health", ok: await ttsHealth, detail: "http://127.0.0.1:8082/health", remediation: .openSidecarLogs),
            DoctorCheck(label: "GitHub CLI auth", ok: effectiveGHAAuth, detail: ghDetail, remediation: effectiveGHAAuth ? nil : .openGitHubCLIAuthDocs),
            DoctorCheck(label: "Claude CLI available", ok: effectiveClaude, detail: claudeDetail, remediation: effectiveClaude ? nil : .openClaudeCLIInstallDocs),
            DoctorCheck(label: "Gemini CLI available", ok: effectiveGemini, detail: geminiDetail, remediation: effectiveGemini ? nil : .openGeminiCLIInstallDocs),
            DoctorCheck(label: "Cursor CLI available", ok: effectiveCursor, detail: cursorDetail, remediation: effectiveCursor ? nil : .openCursorCLIInstallDocs),
            DoctorCheck(label: "Local files readable", ok: localFilesReadable, detail: NSHomeDirectory(), remediation: nil),
            DoctorCheck(label: "Routing policy parity", ok: parity.ok, detail: parity.detail, remediation: parity.ok ? nil : .reconcileRoutingParity(expectedSimpleProvider: expectedSimpleProvider)),
            DoctorCheck(label: "Runtime contract published", ok: contractPublished, detail: publishedContractPath, remediation: contractPublished ? nil : .publishRuntimeContract)
        ]
    }

    private static func mcpToolingAvailable() -> Bool {
        let root = ("~/Library/Mobile Documents/iCloud~md~obsidian/Documents/SeaynicNet/mcps" as NSString).expandingTildeInPath
        let folder = URL(fileURLWithPath: root, isDirectory: true)
        guard let enumerator = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil) else {
            return false
        }
        for case let fileURL as URL in enumerator {
            if fileURL.pathExtension == "json" {
                return true
            }
        }
        return false
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
        if let resolved = executablePath(args[0]) {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: resolved)
            p.arguments = Array(args.dropFirst())
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
        if executablePath(command) != nil {
            return true
        }
        if commandSucceeds([command, "--version"]) {
            return true
        }
        if commandSucceeds(["which", command]) {
            return true
        }
        return commandSucceeds(["/bin/zsh", "-lc", "command -v \(command) >/dev/null 2>&1"])
    }

    private static func executablePath(_ command: String) -> String? {
        let candidates = [
            "/opt/homebrew/bin/\(command)",
            "/usr/local/bin/\(command)",
            "/usr/bin/\(command)",
            "/bin/\(command)",
        ]
        return candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) })
    }
}
