import Foundation
import AVFoundation
// Using Python FastAPI service instead of direct MLX integration
// import Kokoro

/// Kokoro local TTS provider
/// Uses kokoro-swift for fast, offline, high-quality synthesis
class KokoroProvider: NSObject, VoiceProvider, AVAudioPlayerDelegate {
    let name = "Kokoro"
    let supportsStreaming = false

    var availableVoices: [VoiceOption] {
        // Top-tier American English voices (A/A- grade)
        [
            VoiceOption(id: "af_heart", name: "Heart ❤️", language: "en-US", gender: .female),
            VoiceOption(id: "af_bella", name: "Bella 🔥", language: "en-US", gender: .female),
            VoiceOption(id: "af_nicole", name: "Nicole 🎧", language: "en-US", gender: .female),
            VoiceOption(id: "af_sarah", name: "Sarah", language: "en-US", gender: .female),
            VoiceOption(id: "am_michael", name: "Michael", language: "en-US", gender: .male),
            VoiceOption(id: "am_fenrir", name: "Fenrir", language: "en-US", gender: .male),
            // British English
            VoiceOption(id: "bf_emma", name: "Emma (British)", language: "en-GB", gender: .female),
            VoiceOption(id: "bm_george", name: "George (British)", language: "en-GB", gender: .male)
        ]
    }

    private var audioPlayer: AVAudioPlayer?
    private var currentlySpeaking = false

    // HTTP service URL
    private let serviceURL = "http://localhost:5903"

    // MARK: - Initialization

    /// Get model directory
    private var modelDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SoniqueBar/Kokoro")
    }

    /// Check if Kokoro models are available
    var isAvailable: Bool {
        let segmentedDir = modelDirectory.appendingPathComponent("CoreML_ANE/segmented")
        let configFile = modelDirectory.appendingPathComponent("config.json")

        return FileManager.default.fileExists(atPath: segmentedDir.path) &&
               FileManager.default.fileExists(atPath: configFile.path)
    }

    /// Check if Kokoro service is available
    private func checkService() async -> Bool {
        guard let url = URL(string: "\(serviceURL)/health") else { return false }

        do {
            let (_, response) = try await URLSession.shared.data(from: url)
            return (response as? HTTPURLResponse)?.statusCode == 200
        } catch {
            return false
        }
    }

    // MARK: - VoiceProvider Implementation

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
        // Use configured voice or default to af_bella (best match to Jessica)
        let kokoroVoice = await ConfigManager.shared.config.user.kokoroVoice
        let selectedVoice = voice ?? kokoroVoice ?? "af_bella"

        print("[KokoroProvider] Synthesizing with voice: \(selectedVoice)")

        let startTime = Date()

        // Call Python FastAPI service (http://localhost:5903)
        let url = URL(string: "http://localhost:5903/synthesize")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let requestBody = ["text": text, "voice": selectedVoice]
        request.httpBody = try JSONSerialization.data(withJSONObject: requestBody)

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            throw VoiceError.synthesisFailedError("Kokoro service returned error")
        }

        let synthesisTime = Date().timeIntervalSince(startTime)
        print("[KokoroProvider] Synthesis completed in \(Int(synthesisTime * 1000))ms")

        // Save to temp file
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".wav")

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
        // Check if HTTP service is available
        let healthy = await checkService()
        if !healthy {
            print("[KokoroProvider] Health check failed: Service not available at \(serviceURL)")
        }
        return healthy
    }

    // MARK: - AVAudioPlayerDelegate

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        currentlySpeaking = false
    }
}
