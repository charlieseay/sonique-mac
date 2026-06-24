import Foundation
import AppKit

/// macOS system voice provider (NSSpeechSynthesizer)
class SystemVoiceProvider: NSObject, VoiceProvider, NSSpeechSynthesizerDelegate {
    let name = "System Voice"
    let supportsStreaming = false

    var availableVoices: [VoiceOption] {
        NSSpeechSynthesizer.availableVoices.compactMap { voice in
            let attributes = NSSpeechSynthesizer.attributes(forVoice: voice)
            let name = attributes[.name] as? String ?? voice.rawValue
            let language = attributes[.localeIdentifier] as? String ?? "en-US"
            let genderString = attributes[.gender] as? String ?? "neutral"

            let gender: VoiceOption.VoiceGender
            switch genderString.lowercased() {
            case "male", "voicegendermale":
                gender = .male
            case "female", "voicegenderfemale":
                gender = .female
            default:
                gender = .neutral
            }

            return VoiceOption(
                id: voice.rawValue,
                name: name,
                language: language,
                gender: gender
            )
        }
    }

    private var synthesizer: NSSpeechSynthesizer?
    private var currentlySpeaking = false
    private var speechContinuation: CheckedContinuation<Void, Never>?

    func speak(text: String, voice: String?) async {
        await MainActor.run {
            synthesizer = NSSpeechSynthesizer(voice: voice.flatMap { NSSpeechSynthesizer.VoiceName(rawValue: $0) })
            synthesizer?.delegate = self
        }

        await withCheckedContinuation { continuation in
            speechContinuation = continuation
            Task { @MainActor in
                currentlySpeaking = true
                synthesizer?.startSpeaking(text)
            }
        }

        speechContinuation = nil
    }

    func synthesize(text: String, voice: String?) async throws -> URL {
        let voiceName = voice.flatMap { NSSpeechSynthesizer.VoiceName(rawValue: $0) }
        let synth = NSSpeechSynthesizer(voice: voiceName)

        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("system_voice_\(UUID().uuidString).aiff")

        guard synth?.startSpeaking(text, to: tempURL) == true else {
            throw VoiceError.synthesisFailedError("Failed to start synthesis")
        }

        // Wait for synthesis to complete
        while synth?.isSpeaking == true {
            try await Task.sleep(nanoseconds: 100_000_000) // 100ms
        }

        guard FileManager.default.fileExists(atPath: tempURL.path) else {
            throw VoiceError.fileNotFound
        }

        return tempURL
    }

    func stop() async {
        await MainActor.run {
            synthesizer?.stopSpeaking()
            currentlySpeaking = false
            speechContinuation?.resume()
            speechContinuation = nil
        }
    }

    func healthCheck() async -> Bool {
        // System voice is always available on macOS
        return !NSSpeechSynthesizer.availableVoices.isEmpty
    }

    // MARK: - NSSpeechSynthesizerDelegate

    nonisolated func speechSynthesizer(_ sender: NSSpeechSynthesizer, didFinishSpeaking finishedSpeaking: Bool) {
        Task { @MainActor in
            self.currentlySpeaking = false
            self.speechContinuation?.resume()
        }
    }
}
