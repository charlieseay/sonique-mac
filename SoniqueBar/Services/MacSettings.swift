import Foundation
import ServiceManagement
import os.log

private let lalLog = Logger(subsystem: "com.seayniclabs.soniquebar", category: "LaunchAtLogin")

/// `UserDefaults` keys shared with Sonique iOS for LLM routing UI (CAAL wiring — task #284).
/// NVIDIA fields stay inert until CAAL reads them; expose in UI only when `nvidiaFeatureEnabled` is true.
enum LLMRoutingStorageKeys {
    static let llmProvider = "llmProvider"
    static let preferredModelLabel = "preferredModelLabel"
    static let fallbackPolicy = "fallbackPolicy"
    static let nvidiaFeatureEnabled = "nvidiaFeatureEnabled"
    static let nvidiaBaseURL = "nvidiaBaseURL"
}

/// Snake_case keys for CAAL `settings.json` and POST `/api/settings` merges (task #284).
/// Client `UserDefaults` / `AppStorage` use camelCase in `LLMRoutingStorageKeys`; CAAL uses these names.
/// `cloudInferenceBaseURL` is the first managed cloud endpoint slot (NVIDIA NIM today; alias may generalize later).
enum LLMRoutingCAALKeys {
    static let provider = "llm_provider"
    static let modelLabel = "llm_model_label"
    static let fallbackPolicy = "llm_fallback_policy"
    static let nvidiaFeatureEnabled = "nvidia_feature_enabled"
    static let cloudInferenceBaseURL = "nvidia_base_url"
}

enum LaunchAtLoginManager {
    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

    static func set(enabled: Bool) {
        do {
            if enabled {
                if SMAppService.mainApp.status != .enabled {
                    try SMAppService.mainApp.register()
                    lalLog.info("registered for launch at login")
                }
            } else {
                if SMAppService.mainApp.status == .enabled {
                    try SMAppService.mainApp.unregister()
                    lalLog.info("unregistered from launch at login")
                }
            }
        } catch {
            lalLog.error("SMAppService: \(error.localizedDescription)")
        }
    }

    /// Registers on first install only. Subsequent launches honour the saved preference.
    static func applyDefault() {
        let key = "launchAtLoginDefaultApplied"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        UserDefaults.standard.set(true, forKey: key)
        set(enabled: true)
    }
}

struct PiperVoice: Identifiable, Hashable {
    let id: String       // model ID sent to CAAL
    let label: String    // display name in UI
}

extension PiperVoice {
    static let all: [PiperVoice] = [
        PiperVoice(id: "speaches-ai/piper-en_US-ryan-high",         label: "Ryan (American Male)"),
        PiperVoice(id: "speaches-ai/piper-en_US-danny-low",         label: "Danny (American Male)"),
        PiperVoice(id: "speaches-ai/piper-en_US-amy-medium",        label: "Amy (American Female)"),
        PiperVoice(id: "speaches-ai/piper-en_GB-alan-medium",       label: "Alan (British Male)"),
        PiperVoice(id: "speaches-ai/piper-en_US-libritts_r-medium", label: "LibriTTS (Neutral)"),
    ]
    static let defaultVoice = all[0]

    /// Compact label for inline picker in the status popover.
    var shortLabel: String {
        label.components(separatedBy: " (").first ?? label
    }
}

enum SoniqueBarLLMProvider: String, CaseIterable, Identifiable {
    case ollama
    case nvidia

    var id: String { rawValue }

    var label: String {
        switch self {
        case .ollama: return "Ollama (Local)"
        case .nvidia: return "NVIDIA NIM (preview)"
        }
    }
}

enum SoniqueBarFallbackPolicy: String, CaseIterable, Identifiable {
    case localOnly = "local_only"
    case providerThenLocal = "provider_then_local"
    case localThenProvider = "local_then_provider"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .localOnly: return "Local only"
        case .providerThenLocal: return "Provider then local"
        case .localThenProvider: return "Local then provider"
        }
    }

    var routingHint: String {
        switch self {
        case .localOnly:
            return "When wired: use only the local stack (e.g. Ollama)."
        case .providerThenLocal:
            return "When wired: try the configured cloud endpoint first, then local."
        case .localThenProvider:
            return "When wired: try local first, then the configured cloud endpoint if needed."
        }
    }
}

class MacSettings: ObservableObject {
    @Published var apiKey: String {
        didSet { UserDefaults.standard.set(apiKey, forKey: "apiKey") }
    }
    @Published var externalURL: String {
        didSet { UserDefaults.standard.set(externalURL, forKey: "externalURL") }
    }
    @Published var caelDirectory: String {
        didSet { UserDefaults.standard.set(caelDirectory, forKey: "caelDirectory") }
    }
    @Published var ttsVoiceId: String {
        didSet { UserDefaults.standard.set(ttsVoiceId, forKey: "ttsVoiceId") }
    }
    @Published var haURL: String {
        didSet { UserDefaults.standard.set(haURL, forKey: "haURL") }
    }
    @Published var haToken: String {
        didSet { UserDefaults.standard.set(haToken, forKey: "haToken") }
    }
    @Published var llmProviderRaw: String {
        didSet { UserDefaults.standard.set(llmProviderRaw, forKey: LLMRoutingStorageKeys.llmProvider) }
    }
    @Published var preferredModelLabel: String {
        didSet { UserDefaults.standard.set(preferredModelLabel, forKey: LLMRoutingStorageKeys.preferredModelLabel) }
    }
    @Published var fallbackPolicyRaw: String {
        didSet { UserDefaults.standard.set(fallbackPolicyRaw, forKey: LLMRoutingStorageKeys.fallbackPolicy) }
    }
    @Published var nvidiaFeatureEnabled: Bool {
        didSet { UserDefaults.standard.set(nvidiaFeatureEnabled, forKey: LLMRoutingStorageKeys.nvidiaFeatureEnabled) }
    }
    @Published var nvidiaBaseURL: String {
        didSet { UserDefaults.standard.set(nvidiaBaseURL, forKey: LLMRoutingStorageKeys.nvidiaBaseURL) }
    }
    /// Which supervisor drives CAAL: the legacy networked Docker stack
    /// (`ContainerManager`) or the bundled embedded runtime (`SidecarManager`).
    /// Defaults to `.embedded` when the bundled tarball is present, `.networked`
    /// otherwise — resolved in `init()` at launch.
    @Published var deploymentMode: SidecarManager.DeploymentMode {
        didSet { UserDefaults.standard.set(deploymentMode.rawValue, forKey: "deploymentMode") }
    }
    @Published var showInDock: Bool {
        didSet { UserDefaults.standard.set(showInDock, forKey: "showInDock") }
    }
    @Published var launchAtLogin: Bool {
        didSet {
            UserDefaults.standard.set(launchAtLogin, forKey: "launchAtLogin")
            LaunchAtLoginManager.set(enabled: launchAtLogin)
        }
    }

    init() {
        self.apiKey        = UserDefaults.standard.string(forKey: "apiKey")        ?? ""
        self.externalURL   = UserDefaults.standard.string(forKey: "externalURL")   ?? ""
        self.caelDirectory = UserDefaults.standard.string(forKey: "caelDirectory") ?? "~/Projects/cael"
        self.ttsVoiceId    = UserDefaults.standard.string(forKey: "ttsVoiceId")    ?? PiperVoice.defaultVoice.id
        self.haURL         = UserDefaults.standard.string(forKey: "haURL")         ?? ""
        self.haToken       = UserDefaults.standard.string(forKey: "haToken")       ?? ""
        self.llmProviderRaw = UserDefaults.standard.string(forKey: LLMRoutingStorageKeys.llmProvider) ?? SoniqueBarLLMProvider.ollama.rawValue
        self.preferredModelLabel = UserDefaults.standard.string(forKey: LLMRoutingStorageKeys.preferredModelLabel) ?? "gemma4"
        self.fallbackPolicyRaw = UserDefaults.standard.string(forKey: LLMRoutingStorageKeys.fallbackPolicy) ?? SoniqueBarFallbackPolicy.localOnly.rawValue
        self.nvidiaFeatureEnabled = UserDefaults.standard.bool(forKey: LLMRoutingStorageKeys.nvidiaFeatureEnabled)
        self.nvidiaBaseURL = UserDefaults.standard.string(forKey: LLMRoutingStorageKeys.nvidiaBaseURL) ?? ""
        self.showInDock    = UserDefaults.standard.bool(forKey: "showInDock")
        self.launchAtLogin = UserDefaults.standard.object(forKey: "launchAtLogin") as? Bool ?? true

        let bundledTarballExists = Bundle.main.url(
            forResource: "python-runtime",
            withExtension: "tar.gz"
        ) != nil
        let stored = UserDefaults.standard.string(forKey: "deploymentMode")
        let fallback: SidecarManager.DeploymentMode = bundledTarballExists ? .embedded : .networked
        self.deploymentMode = stored.flatMap(SidecarManager.DeploymentMode.init(rawValue:)) ?? fallback
    }

    // Always manages local CAAL — configured as soon as the directory is set
    var isConfigured: Bool {
        !caelDirectory.trimmingCharacters(in: .whitespaces).isEmpty
    }

    // Next.js frontend (health, profile, QR, settings)
    var effectiveURL: String { "http://localhost:3100" }

    // FastAPI webhook server (chat, mac-actions, memory, etc.)
    var backendURL: String { "http://localhost:8889" }

    var normalizedExternalURL: String {
        externalURL.hasSuffix("/") ? String(externalURL.dropLast()) : externalURL
    }

    var llmProvider: SoniqueBarLLMProvider {
        get {
            let decoded = SoniqueBarLLMProvider(rawValue: llmProviderRaw) ?? .ollama
            if !nvidiaFeatureEnabled, decoded == .nvidia { return .ollama }
            return decoded
        }
        set { llmProviderRaw = newValue.rawValue }
    }

    var fallbackPolicy: SoniqueBarFallbackPolicy {
        get { SoniqueBarFallbackPolicy(rawValue: fallbackPolicyRaw) ?? .localOnly }
        set { fallbackPolicyRaw = newValue.rawValue }
    }

    var availableProviders: [SoniqueBarLLMProvider] {
        nvidiaFeatureEnabled ? SoniqueBarLLMProvider.allCases : [.ollama]
    }

    /// Idle-style summary aligned with iOS `SoniqueSettings.llmRoutingSummaryLine` (prefs only until #284 ships server-side).
    var llmRoutingSummaryLine: String {
        "\(llmProvider.label) · \(fallbackPolicy.label) · \(preferredModelLabel)"
    }
}
