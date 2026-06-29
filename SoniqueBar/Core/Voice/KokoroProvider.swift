import Foundation
import AVFoundation

/// Kokoro local TTS provider
/// Uses embedded standalone binary for App Store-compatible, offline TTS
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
    private var ttsEngine: EmbeddedTTSProvider?

    // MARK: - Initialization

    private func startEngineIfNeeded() async throws {
        if ttsEngine == nil {
            ttsEngine = EmbeddedTTSProvider()
        }
        do {
            try ttsEngine?.start()
            print("[KokoroProvider] ✅ Embedded TTS engine started successfully")
        } catch {
            print("[KokoroProvider] ❌ Failed to start embedded TTS: \(error)")
            throw error
        }
    }

    var isAvailable: Bool {
        // Always available - binary is embedded in app bundle
        return true
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

        print("[KokoroProvider] 🎙️ Synthesizing '\(text.prefix(50))...' with voice: \(selectedVoice)")

        let startTime = Date()

        // Ensure embedded engine is running
        do {
            try await startEngineIfNeeded()
        } catch {
            print("[KokoroProvider] ❌ Failed to start engine: \(error)")
            throw error
        }

        // Synthesize using embedded binary
        guard let buffer = try await ttsEngine?.synthesize(text: text, voice: selectedVoice) else {
            print("[KokoroProvider] ❌ Synthesis returned nil")
            throw VoiceError.synthesisFailedError("Failed to synthesize audio")
        }

        let synthesisTime = Date().timeIntervalSince(startTime)
        print("[KokoroProvider] ✅ Synthesis completed in \(Int(synthesisTime * 1000))ms")

        // Convert buffer to WAV file
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".wav")

        try writeBufferToWAV(buffer: buffer, url: tempURL)

        return tempURL
    }

    private func writeBufferToWAV(buffer: AVAudioPCMBuffer, url: URL) throws {
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: buffer.format.sampleRate,
            AVNumberOfChannelsKey: buffer.format.channelCount,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false
        ]
        let audioFile = try AVAudioFile(forWriting: url, settings: settings)
        try audioFile.write(from: buffer)
    }

    func stop() async {
        await MainActor.run {
            audioPlayer?.stop()
            currentlySpeaking = false
        }
    }

    func healthCheck() async -> Bool {
        // Embedded binary is always available
        return true
    }

    deinit {
        // Shutdown engine on cleanup
        ttsEngine?.shutdown()
    }

    // MARK: - AVAudioPlayerDelegate

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        currentlySpeaking = false
    }
}
