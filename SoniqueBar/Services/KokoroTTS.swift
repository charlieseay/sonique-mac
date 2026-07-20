import Foundation
import os.log
import Kokoro

/// Native Kokoro TTS service using kokoro-swift
/// Provides on-device TTS with Jessica voice (af_jessica)
class KokoroTTS {
    private let logger = Logger(subsystem: "com.seayniclabs.soniquebar", category: "KokoroTTS")

    // Singleton
    static let shared = KokoroTTS()

    private var pipeline: KPipeline?
    private let weightsDir = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Projects/sonique-mac/Kokoro/MLX_GPU")

    private init() {
        logger.info("[KokoroTTS] Initializing...")
        do {
            let configURL = weightsDir.appendingPathComponent("config.json")
            let weightsURL = weightsDir.appendingPathComponent("kokoro-v1_0.safetensors")
            let voicesDir = weightsDir.appendingPathComponent("voices")

            // Check if weights exist
            guard FileManager.default.fileExists(atPath: configURL.path) else {
                logger.error("[KokoroTTS] Config not found at \(configURL.path)")
                logger.error("[KokoroTTS] Download weights from: https://huggingface.co/mweinbach/Kokoro-82M-Swift")
                return
            }

            let model = try KModel(configURL: configURL, weightsURL: weightsURL)
            let voices = VoiceLoader(baseDirectory: voicesDir, enableDownload: true)
            self.pipeline = KPipeline(model: model, voices: voices)

            logger.info("[KokoroTTS] Initialized with MLX backend")
        } catch {
            logger.error("[KokoroTTS] Initialization failed: \(error.localizedDescription)")
        }
    }

    /// Synthesize speech from text
    /// Returns PCM audio data (24kHz mono 16-bit)
    func synthesize(text: String, voice: String = "af_jessica") async throws -> Data {
        logger.info("[KokoroTTS] Synthesizing: \(text.prefix(50))")

        guard let pipeline = pipeline else {
            throw KokoroError.notInitialized
        }

        return try await Task {
            // Run synthesis on background thread (KPipeline is synchronous)
            let result = try pipeline.synthesize(text: text, voice: voice, speed: 1.0)

            // Convert Float32 samples to 16-bit PCM
            let pcmData = self.floatToPCM16(samples: result.audio)

            logger.info("[KokoroTTS] Generated \(result.audio.count) samples (\(pcmData.count) bytes PCM)")
            return pcmData
        }.value
    }

    /// Convert Float32 audio samples to 16-bit PCM Data
    private func floatToPCM16(samples: [Float]) -> Data {
        var pcmData = Data(capacity: samples.count * 2)
        for sample in samples {
            // Clamp to [-1.0, 1.0] and convert to Int16 range
            let clamped = max(-1.0, min(1.0, sample))
            let int16Value = Int16(clamped * Float(Int16.max))
            withUnsafeBytes(of: int16Value.littleEndian) { pcmData.append(contentsOf: $0) }
        }
        return pcmData
    }

    enum KokoroError: Error {
        case notInitialized
        case synthesisError(String)
    }
}
