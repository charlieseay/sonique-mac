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
    @Published var defaultProvider: String = "elevenlabs"  // Using ElevenLabs until Kokoro SPM resolved
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
            ElevenLabsProvider(),     // Cloud TTS (primary)
            OpenAITTSProvider(),      // Alternative cloud
            SystemVoiceProvider()     // System fallback
        ]
    }

    /// Load TTS provider preference from config
    private func loadProviderFromConfig() {
        // No config manager for now - using hardcoded defaults
    }

    /// Update config when provider changes
    func setProvider(_ providerName: String) {
        defaultProvider = providerName
        // Config persistence removed - just update in-memory
    }

    /// Get provider by name
    func getProvider(_ name: String) -> (any VoiceProvider)? {
        providers.first { $0.name.lowercased() == name.lowercased() }
    }

    /// Speak with default provider, falling back to ElevenLabs if the primary provider is unavailable.
    func speak(text: String, voice: String? = nil) async throws {
        guard let provider = getProvider(defaultProvider) else {
            throw VoiceError.notAvailable
        }

        let isHealthy = await provider.healthCheck()
        if !isHealthy && defaultProvider != "elevenlabs" {
            print("[VoiceRouter] \(defaultProvider) unavailable, falling back to ElevenLabs")
            if let fallback = getProvider("elevenlabs") {
                let fallbackVoice = voice ?? defaultVoice["elevenlabs"]
                try await fallback.speak(text: text, voice: fallbackVoice)
                return
            }
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
