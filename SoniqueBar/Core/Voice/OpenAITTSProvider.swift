import Foundation
import AVFoundation

/// OpenAI TTS provider
class OpenAITTSProvider: NSObject, VoiceProvider, AVAudioPlayerDelegate {
    let name = "OpenAI TTS"
    let supportsStreaming = false

    var availableVoices: [VoiceOption] {
        [
            VoiceOption(id: "alloy", name: "Alloy", language: "en-US", gender: .neutral),
            VoiceOption(id: "echo", name: "Echo", language: "en-US", gender: .male),
            VoiceOption(id: "fable", name: "Fable", language: "en-US", gender: .male),
            VoiceOption(id: "onyx", name: "Onyx", language: "en-US", gender: .male),
            VoiceOption(id: "nova", name: "Nova", language: "en-US", gender: .female),
            VoiceOption(id: "shimmer", name: "Shimmer", language: "en-US", gender: .female)
        ]
    }

    private var audioPlayer: AVAudioPlayer?
    private var currentlySpeaking = false

    private func getAPIKey() -> String? {
        // Try AppStorage first
        if let key = UserDefaults.standard.string(forKey: "openai_api_key"), !key.isEmpty {
            return key
        }

        // Try environment variable
        if let key = ProcessInfo.processInfo.environment["OPENAI_API_KEY"], !key.isEmpty {
            return key
        }

        return nil
    }

    func speak(text: String, voice: String?) async throws {
        let audioURL = try await synthesize(text: text, voice: voice)

        // Play audio
        try await MainActor.run {
            self.audioPlayer = try AVAudioPlayer(contentsOf: audioURL)
            self.audioPlayer?.delegate = self
            self.currentlySpeaking = true
            self.audioPlayer?.play()
        }

        // Wait for playback to finish
        while currentlySpeaking {
            try await Task.sleep(nanoseconds: 100_000_000) // 100ms
        }

        // Clean up temp file
        try? FileManager.default.removeItem(at: audioURL)
    }

    func synthesize(text: String, voice: String?) async throws -> URL {
        guard let apiKey = getAPIKey() else {
            throw VoiceError.authenticationFailed
        }

        let selectedVoice = voice ?? "alloy"

        guard let url = URL(string: "https://api.openai.com/v1/audio/speech") else {
            throw VoiceError.synthesisFailedError("Invalid URL")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let payload: [String: Any] = [
            "model": "tts-1",
            "input": text,
            "voice": selectedVoice
        ]

        request.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw VoiceError.synthesisFailedError("Invalid response")
        }

        guard httpResponse.statusCode == 200 else {
            let errorMessage = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw VoiceError.synthesisFailedError("HTTP \(httpResponse.statusCode): \(errorMessage)")
        }

        // Save audio to temp file
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("openai_tts_\(UUID().uuidString).mp3")

        try data.write(to: tempURL)

        return tempURL
    }

    func stop() async {
        await MainActor.run {
            audioPlayer?.stop()
            currentlySpeaking = false
        }
    }

    func healthCheck() async -> Bool {
        guard let apiKey = getAPIKey(), !apiKey.isEmpty else {
            return false
        }

        // Test with minimal text
        do {
            let url = try await synthesize(text: "test", voice: nil)
            try? FileManager.default.removeItem(at: url)
            return true
        } catch {
            return false
        }
    }

    // MARK: - AVAudioPlayerDelegate

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in
            self.currentlySpeaking = false
        }
    }
}
