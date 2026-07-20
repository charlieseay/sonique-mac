import Foundation
import os.log

/// Native Kokoro TTS service using KokoroCLI subprocess
/// Provides on-device TTS with Jessica voice (af_jessica)
class KokoroTTS {
    private let logger = Logger(subsystem: "com.seayniclabs.soniquebar", category: "KokoroTTS")

    // Singleton
    static let shared = KokoroTTS()

    private let cliPath: String
    private let weightsDir: String

    // Configuration from UserDefaults (set via Settings UI)
    private var speechSpeed: Float {
        Float(UserDefaults.standard.double(forKey: "tts.kokoro.speed").isZero ? 1.02 : UserDefaults.standard.double(forKey: "tts.kokoro.speed"))
    }

    private var defaultVoice: String {
        UserDefaults.standard.string(forKey: "tts.kokoro.voice") ?? "af_jessica"
    }

    private init() {
        logger.info("[KokoroTTS] Initializing...")

        // Path to xcodebuild KokoroCLI binary (required for Metal shaders)
        let homeDir = FileManager.default.homeDirectoryForCurrentUser.path
        self.cliPath = "\(homeDir)/Library/Developer/Xcode/DerivedData/Kokoro-bucjbiopclclewcdvhstvyngclfr/Build/Products/Release/KokoroCLI"
        self.weightsDir = "\(homeDir)/Projects/sonique-mac/Kokoro/MLX_GPU"

        // Verify CLI exists
        if FileManager.default.fileExists(atPath: self.cliPath) {
            logger.info("[KokoroTTS] ✓ Found KokoroCLI at \(self.cliPath)")
        } else {
            logger.error("[KokoroTTS] ❌ KokoroCLI not found at \(self.cliPath)")
            logger.error("[KokoroTTS] Build with: cd ~/Projects/sonique-mac/Kokoro && xcodebuild -scheme KokoroCLI -destination 'platform=macOS' -configuration Release build")
        }
    }

    /// Synthesize speech from text using KokoroCLI subprocess
    /// Returns PCM audio data (24kHz mono 16-bit)
    func synthesize(text: String, voice: String? = nil, speed: Float? = nil) async throws -> Data {
        let voiceToUse = voice ?? defaultVoice
        let speedToUse = speed ?? speechSpeed
        logger.info("[KokoroTTS] Synthesizing: \(text.prefix(50)) [voice: \(voiceToUse), speed: \(speedToUse)]")

        guard FileManager.default.fileExists(atPath: cliPath) else {
            throw KokoroError.cliNotFound
        }

        return try await withCheckedThrowingContinuation { continuation in
            let tempOutput = "/tmp/kokoro-\(UUID().uuidString).wav"

            let process = Process()
            process.executableURL = URL(fileURLWithPath: cliPath)
            process.arguments = [
                "--text", text,
                "--voice", voiceToUse,
                "--output", tempOutput,
                "--weights-dir", weightsDir,
                "--speed", String(speedToUse),
                "--auto-download"
            ]

            let pipe = Pipe()
            process.standardError = pipe

            do {
                try process.run()
                process.waitUntilExit()

                if process.terminationStatus == 0 {
                    // Read WAV file and extract PCM data
                    let wavData = try Data(contentsOf: URL(fileURLWithPath: tempOutput))

                    // WAV header is 44 bytes, PCM data follows
                    guard wavData.count > 44 else {
                        throw KokoroError.synthesisError("WAV file too small")
                    }

                    let pcmData = wavData.suffix(from: 44)
                    logger.info("[KokoroTTS] Generated \(pcmData.count) bytes PCM")

                    // Clean up temp file
                    try? FileManager.default.removeItem(atPath: tempOutput)

                    continuation.resume(returning: Data(pcmData))
                } else {
                    let errorData = pipe.fileHandleForReading.readDataToEndOfFile()
                    let errorString = String(data: errorData, encoding: .utf8) ?? "Unknown error"
                    logger.error("[KokoroTTS] CLI failed: \(errorString)")
                    continuation.resume(throwing: KokoroError.synthesisError(errorString))
                }
            } catch {
                logger.error("[KokoroTTS] Process error: \(error.localizedDescription)")
                continuation.resume(throwing: error)
            }
        }
    }

    enum KokoroError: Error {
        case cliNotFound
        case synthesisError(String)
    }
}
