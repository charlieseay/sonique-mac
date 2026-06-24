import Foundation
import AVFoundation

/// ElevenLabs TTS provider
class ElevenLabsProvider: NSObject, VoiceProvider, AVAudioPlayerDelegate {
    let name = "ElevenLabs"
    let supportsStreaming = false

    var availableVoices: [VoiceOption] {
        // Common ElevenLabs voices
        [
            VoiceOption(id: "21m00Tcm4TlvDq8ikWAM", name: "Rachel", language: "en-US", gender: .female),
            VoiceOption(id: "AZnzlk1XvdvUeBnXmlld", name: "Domi", language: "en-US", gender: .female),
            VoiceOption(id: "EXAVITQu4vr4xnSDxMaL", name: "Bella", language: "en-US", gender: .female),
            VoiceOption(id: "ErXwobaYiN019PkySvjV", name: "Antoni", language: "en-US", gender: .male),
            VoiceOption(id: "MF3mGyEYCl7XYWbV9V6O", name: "Elli", language: "en-US", gender: .female),
            VoiceOption(id: "TxGEqnHWrfWFTfGW9XjX", name: "Josh", language: "en-US", gender: .male)
        ]
    }

    private var audioPlayer: AVAudioPlayer?
    private var currentlySpeaking = false

    private func getAPIKey() -> String? {
        // Try multiple locations
        let paths = [
            NSHomeDirectory() + "/Library/Application Support/SoniqueBar/elevenlabs_api_key",
            "/Volumes/data/secrets/elevenlabs_api_key"
        ]

        for path in paths {
            if let key = try? String(contentsOfFile: path, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines),
               !key.isEmpty {
                return key
            }
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

        // Use default voice if none specified (from AppStorage or fallback)
        let voiceID = voice ?? UserDefaults.standard.string(forKey: "elevenlabs_voice_id") ?? "21m00Tcm4TlvDq8ikWAM" // Rachel

        let urlString = "https://api.elevenlabs.io/v1/text-to-speech/\(voiceID)"
        guard let url = URL(string: urlString) else {
            throw VoiceError.synthesisFailedError("Invalid URL")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "xi-api-key")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let payload: [String: Any] = [
            "text": text,
            "model_id": "eleven_monolingual_v1",
            "voice_settings": [
                "stability": 0.5,
                "similarity_boost": 0.75
            ]
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
            .appendingPathComponent("elevenlabs_\(UUID().uuidString).mp3")

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
