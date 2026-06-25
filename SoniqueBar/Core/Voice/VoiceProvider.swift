import Foundation

/// Protocol for text-to-speech providers
protocol VoiceProvider: Sendable {
    var name: String { get }
    var availableVoices: [VoiceOption] { get }
    var supportsStreaming: Bool { get }

    /// Speak text aloud
    func speak(text: String, voice: String?) async throws

    /// Generate audio file from text
    func synthesize(text: String, voice: String?) async throws -> URL

    /// Stop current speech
    func stop() async

    /// Check if provider is available
    func healthCheck() async -> Bool
}

/// Voice option
struct VoiceOption: Identifiable, Hashable {
    let id: String
    let name: String
    let language: String
    let gender: VoiceGender

    enum VoiceGender: String {
        case male
        case female
        case neutral
    }
}

/// Voice provider errors
enum VoiceError: Error, LocalizedError {
    case notAvailable
    case authenticationFailed
    case invalidVoice(String)
    case synthesisFailedError(String)
    case fileNotFound

    var errorDescription: String? {
        switch self {
        case .notAvailable:
            return "Voice provider not available"
        case .authenticationFailed:
            return "Authentication failed"
        case .invalidVoice(let voice):
            return "Invalid voice: \(voice)"
        case .synthesisFailedError(let message):
            return "Synthesis failed: \(message)"
        case .fileNotFound:
            return "Audio file not found"
        }
    }
}

/// Router for selecting voice provider
@MainActor
class VoiceRouter: ObservableObject {
    static let shared = VoiceRouter()

    @Published private(set) var providers: [any VoiceProvider] = []
    @Published var defaultProvider: String = "elevenlabs"  // TODO: Change to "kokoro" once integrated
    @Published var defaultVoice: [String: String] = [
        "elevenlabs": "cgSgspJ2msm6clMCkdW9", // Jessica
        "kokoro": "af_bella", // Best match to Jessica
        "openai": "alloy",
        "system": "Samantha"
    ]

    private init() {
        registerProviders()
        loadProviderFromConfig()
    }

    private func registerProviders() {
        providers = [
            KokoroProvider(),         // NEW: Local TTS (will integrate next)
            ElevenLabsProvider(),     // Cloud TTS (current default)
            OpenAITTSProvider(),      // Alternative cloud
            SystemVoiceProvider()     // System fallback
        ]
    }

    /// Load TTS provider preference from config
    private func loadProviderFromConfig() {
        let config = ConfigManager.shared.config.user
        defaultProvider = config.ttsProvider.rawValue

        // Load voice preferences
        if let elevenLabsVoice = config.elevenLabsVoiceID {
            defaultVoice["elevenlabs"] = elevenLabsVoice
        }
        if let kokoroVoice = config.kokoroVoice {
            defaultVoice["kokoro"] = kokoroVoice
        }
    }

    /// Update config when provider changes
    func setProvider(_ providerName: String) {
        defaultProvider = providerName
        // Update config
        Task {
            await MainActor.run {
                if let provider = UserConfig.TTSProvider(rawValue: providerName) {
                    ConfigManager.shared.config.user.ttsProvider = provider
                    ConfigManager.shared.save()
                }
            }
        }
    }

    /// Get provider by name
    func getProvider(_ name: String) -> (any VoiceProvider)? {
        providers.first { $0.name.lowercased() == name.lowercased() }
    }

    /// Speak with default provider
    func speak(text: String, voice: String? = nil) async throws {
        guard let provider = getProvider(defaultProvider) else {
            throw VoiceError.notAvailable
        }

        let selectedVoice = voice ?? defaultVoice[defaultProvider]
        try await provider.speak(text: text, voice: selectedVoice)
    }

    /// Speak with specific provider
    func speak(text: String, provider providerName: String, voice: String? = nil) async throws {
        guard let provider = getProvider(providerName) else {
            throw VoiceError.notAvailable
        }

        let selectedVoice = voice ?? defaultVoice[providerName]
        try await provider.speak(text: text, voice: selectedVoice)
    }

    /// Stop all speech
    func stopAll() async {
        for provider in providers {
            await provider.stop()
        }
    }

    /// Health check all providers
    func healthCheckAll() async -> [String: Bool] {
        var results: [String: Bool] = [:]

        for provider in providers {
            let healthy = await provider.healthCheck()
            results[provider.name] = healthy
        }

        return results
    }
}
