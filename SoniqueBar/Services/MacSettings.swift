import Foundation

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
    /// Which supervisor drives CAAL: the legacy networked Docker stack
    /// (`ContainerManager`) or the bundled embedded runtime (`SidecarManager`).
    /// Defaults to `.embedded` when the bundled tarball is present, `.networked`
    /// otherwise — resolved in `init()` at launch.
    @Published var deploymentMode: SidecarManager.DeploymentMode {
        didSet { UserDefaults.standard.set(deploymentMode.rawValue, forKey: "deploymentMode") }
    }

    init() {
        self.apiKey        = UserDefaults.standard.string(forKey: "apiKey")        ?? ""
        self.externalURL   = UserDefaults.standard.string(forKey: "externalURL")   ?? ""
        self.caelDirectory = UserDefaults.standard.string(forKey: "caelDirectory") ?? "~/Projects/cael"
        self.ttsVoiceId    = UserDefaults.standard.string(forKey: "ttsVoiceId")    ?? PiperVoice.defaultVoice.id

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

    // Always localhost:3100 — CAAL frontend port (3000 avoided to not conflict with other local services)
    var effectiveURL: String { "http://localhost:3100" }

    var normalizedExternalURL: String {
        externalURL.hasSuffix("/") ? String(externalURL.dropLast()) : externalURL
    }
}
