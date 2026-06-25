import Foundation
import AVFoundation

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

    // MARK: - Initialization

    /// Check if Kokoro is ready to use
    var isAvailable: Bool {
        // TODO: Check if kokoro-swift package is available and models downloaded
        // For now, return true and handle errors during synthesis
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
        let selectedVoice = voice ?? UserDefaults.standard.string(forKey: "kokoro_voice") ?? "af_bella"

        // TODO: Integrate with kokoro-swift package
        // For now, throw error with helpful message
        throw VoiceError.synthesisFailedError("""
            Kokoro integration pending. Implementation steps:
            1. Add kokoro-swift as SPM dependency
            2. Download model weights from HuggingFace
            3. Initialize KPipeline with CoreML backend
            4. Call pipeline.synthesize(text: "\(text)", voice: "\(selectedVoice)")

            Expected synthesis time: <300ms on M4 Pro
            Model size: ~400 MB (one-time download)
            """)
    }

    func stop() async {
        await MainActor.run {
            audioPlayer?.stop()
            currentlySpeaking = false
        }
    }

    func healthCheck() async -> Bool {
        // Check if Kokoro models are available
        // For now, return true (will handle download during first synthesis)
        return isAvailable
    }

    // MARK: - AVAudioPlayerDelegate

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        currentlySpeaking = false
    }
}

// MARK: - Kokoro Integration Notes

/*
 Integration Plan:

 1. Add SPM dependency to Package.swift:
    .package(url: "https://github.com/mweinbach/kokoro-swift.git", from: "0.1.0")

 2. Download model weights (one-time setup):
    - Download from: https://huggingface.co/mweinbach/Kokoro-82M-Swift
    - Save to: ~/Library/Application Support/SoniqueBar/Kokoro/
    - CoreML ANE segmented model (4 mlpackage files) for best performance

 3. Initialize in synthesize():
    ```swift
    import Kokoro

    // Load model (singleton, cache for session)
    static var pipeline: KPipeline?

    if pipeline == nil {
        let modelDir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SoniqueBar/Kokoro")

        let model = try SegmentedCoreMLModel(
            segmentedDir: modelDir.appendingPathComponent("CoreML_ANE/segmented"),
            configURL: modelDir.appendingPathComponent("config.json")
        )

        let voices = VoiceLoader(
            baseDirectory: modelDir.appendingPathComponent("voices"),
            enableDownload: true  // auto-download missing voices
        )

        pipeline = KPipeline(coreMLSegmentedModel: model, voices: voices)
    }

    // Synthesize
    let result = try pipeline!.synthesize(text: text, voice: selectedVoice)

    // Write to temp file
    let tempURL = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString + ".wav")
    try AudioWriter.writeWAV(samples: result.audio, to: tempURL, sampleRate: 24000)

    return tempURL
    ```

 4. Voice Downloads:
    - Voices download on-demand from HuggingFace
    - ~50 MB per voice
    - Recommended: pre-download af_bella + af_heart during first launch

 5. Performance:
    - First synthesis: ~1s (loads model)
    - Subsequent: <300ms (M4 Pro)
    - Memory: +100-150 MB during synthesis

 6. Error Handling:
    - Model not found → prompt user to download
    - Voice not found → auto-download or fallback to af_heart
    - Synthesis failure → fallback to SystemVoiceProvider
 */
