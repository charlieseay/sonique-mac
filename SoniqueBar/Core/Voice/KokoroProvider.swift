import Foundation
import AVFoundation
// import Kokoro  // TODO: Enable once SPM dependency resolved

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

    // Singleton pipeline (cached for session)
    // private static var pipeline: KPipeline?
    private static var pipelineError: Error?

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

    /// Initialize pipeline (lazy, cached)
    private func getPipeline() throws -> Any {
        // Return cached error if initialization failed before
        if let error = Self.pipelineError {
            throw error
        }

        // TODO: Implement once Kokoro SPM dependency is resolved
        throw VoiceError.synthesisFailedError("Kokoro integration pending - SPM dependency needs resolution")

        /* UNCOMMENT ONCE KOKORO PACKAGE IS AVAILABLE:
        // Return cached pipeline if available
        if let pipeline = Self.pipeline {
            return pipeline
        }

        do {
            print("[KokoroProvider] Initializing pipeline...")

            // Load CoreML segmented model
            let model = try SegmentedCoreMLModel(
                segmentedDir: modelDirectory.appendingPathComponent("CoreML_ANE/segmented"),
                configURL: modelDirectory.appendingPathComponent("config.json")
            )

            // Load voices (with auto-download enabled)
            let voices = VoiceLoader(
                baseDirectory: modelDirectory.appendingPathComponent("voices"),
                enableDownload: true
            )

            // Create pipeline
            let pipeline = KPipeline(coreMLSegmentedModel: model, voices: voices)

            Self.pipeline = pipeline
            print("[KokoroProvider] Pipeline initialized successfully")

            return pipeline
        } catch {
            Self.pipelineError = error
            print("[KokoroProvider] Failed to initialize pipeline: \(error)")
            throw VoiceError.synthesisFailedError("Kokoro initialization failed: \(error.localizedDescription)")
        }
        */
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

        // TODO: Implement once Kokoro SPM dependency is resolved
        throw VoiceError.synthesisFailedError("Kokoro integration pending - SPM dependency needs resolution")

        /* UNCOMMENT ONCE KOKORO PACKAGE IS AVAILABLE:
        let startTime = Date()

        // Get pipeline (cached)
        let pipeline = try getPipeline()

        // Synthesize
        let result = try pipeline.synthesize(text: text, voice: selectedVoice)

        let synthesisTime = Date().timeIntervalSince(startTime)
        print("[KokoroProvider] Synthesis completed in \(Int(synthesisTime * 1000))ms")

        // Write to temp file
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".wav")

        try AudioWriter.writeWAV(samples: result.audio, to: tempURL, sampleRate: 24000)

        return tempURL
        */
    }

    func stop() async {
        await MainActor.run {
            audioPlayer?.stop()
            currentlySpeaking = false
        }
    }

    func healthCheck() async -> Bool {
        // Check if models are available and pipeline can initialize
        guard isAvailable else {
            print("[KokoroProvider] Health check failed: Models not found")
            return false
        }

        do {
            _ = try getPipeline()
            return true
        } catch {
            print("[KokoroProvider] Health check failed: \(error)")
            return false
        }
    }

    // MARK: - AVAudioPlayerDelegate

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        currentlySpeaking = false
    }
}
