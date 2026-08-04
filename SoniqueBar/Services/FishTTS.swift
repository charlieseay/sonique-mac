import Foundation
import os.log

/// Fish Speech TTS service - HTTP client to bundled Fish Speech server
/// Port 3000, OpenAI-compatible API
class FishTTS {
    private let logger = Logger(subsystem: "com.seayniclabs.soniquebar", category: "FishTTS")

    // Singleton
    static let shared = FishTTS()

    private let baseURL: String
    private let defaultVoice: String

    // Configuration from UserDefaults (set via Settings UI)
    private var speechSpeed: Float {
        Float(UserDefaults.standard.double(forKey: "tts.fish.speed").isZero ? 1.0 : UserDefaults.standard.double(forKey: "tts.fish.speed"))
    }

    private var voiceName: String {
        UserDefaults.standard.string(forKey: "tts.fish.voice") ?? "default"
    }

    private init() {
        logger.info("[FishTTS] Initializing...")

        // Fish Speech server URL (bundled, local)
        self.baseURL = "http://127.0.0.1:3000"
        self.defaultVoice = "default"

        logger.info("[FishTTS] Fish Speech server: \(self.baseURL)")
    }

    /// Synthesize speech from text using Fish Speech OpenAI-compatible API
    /// Returns PCM audio data (16kHz mono 16-bit)
    func synthesize(text: String, voice: String? = nil, speed: Float? = nil) async throws -> Data {
        let voiceToUse = voice ?? voiceName
        let speedToUse = speed ?? speechSpeed
        logger.info("[FishTTS] Synthesizing: \(text.prefix(50)) [voice: \(voiceToUse), speed: \(speedToUse)]")

        // Fish Speech uses OpenAI-compatible /v1/audio/speech endpoint
        guard let url = URL(string: "\(baseURL)/v1/audio/speech") else {
            throw FishError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 30

        let payload: [String: Any] = [
            "input": text,
            "voice": voiceToUse,
            "model": "tts-1",  // OpenAI-compatible model name
            "response_format": "wav",  // Fish returns WAV
            "speed": speedToUse
        ]

        guard let jsonData = try? JSONSerialization.data(withJSONObject: payload) else {
            throw FishError.serializationFailed
        }

        request.httpBody = jsonData

        do {
            let (data, response) = try await URLSession.shared.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse else {
                throw FishError.invalidResponse
            }

            logger.info("[FishTTS] HTTP \(httpResponse.statusCode), received \(data.count) bytes")

            guard httpResponse.statusCode == 200 else {
                if let errorString = String(data: data, encoding: .utf8) {
                    logger.error("[FishTTS] Server error: \(errorString)")
                }
                throw FishError.httpError(httpResponse.statusCode)
            }

            // Fish returns WAV, extract PCM data (skip 44-byte header)
            if data.count > 44 && data.prefix(4) == Data([0x52, 0x49, 0x46, 0x46]) {  // "RIFF"
                let pcmData = data.suffix(from: 44)
                logger.info("[FishTTS] Generated \(pcmData.count) bytes PCM from WAV")
                return pcmData
            } else {
                // Already PCM or unknown format - return as-is
                logger.info("[FishTTS] Generated \(data.count) bytes audio")
                return data
            }
        } catch let error as FishError {
            throw error
        } catch {
            logger.error("[FishTTS] Request failed: \(error.localizedDescription)")
            throw FishError.networkError(error.localizedDescription)
        }
    }

    /// Check if Fish TTS is reachable
    func healthCheck() async -> Bool {
        guard let url = URL(string: "\(baseURL)/v1/voices") else {
            return false
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 5

        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            if let httpResponse = response as? HTTPURLResponse {
                let healthy = httpResponse.statusCode == 200
                if !healthy {
                    logger.warning("[FishTTS] Health check failed: HTTP \(httpResponse.statusCode)")
                }
                return healthy
            }
            return false
        } catch {
            logger.error("[FishTTS] Health check error: \(error.localizedDescription)")
            return false
        }
    }

    enum FishError: Error {
        case invalidURL
        case serializationFailed
        case invalidResponse
        case httpError(Int)
        case networkError(String)
    }
}
