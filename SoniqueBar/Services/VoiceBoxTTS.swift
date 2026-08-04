import Foundation
import os.log

/// VoiceBox TTS service - HTTP client to local VoiceBox server
/// Port 17493, POST /speak endpoint
class VoiceBoxTTS {
    private let logger = Logger(subsystem: "com.seayniclabs.soniquebar", category: "VoiceBoxTTS")

    // Singleton
    static let shared = VoiceBoxTTS()

    private let baseURL: String
    private let defaultProfile: String

    // Configuration from UserDefaults (set via Settings UI)
    private var speechSpeed: Float {
        Float(UserDefaults.standard.double(forKey: "tts.voicebox.speed").isZero ? 1.0 : UserDefaults.standard.double(forKey: "tts.voicebox.speed"))
    }

    private var voiceProfile: String {
        UserDefaults.standard.string(forKey: "tts.voicebox.profile") ?? "default"
    }

    private init() {
        logger.info("[VoiceBoxTTS] Initializing...")

        // VoiceBox server URL (configurable via settings, default: localhost:17493)
        self.baseURL = UserDefaults.standard.string(forKey: "tts.voicebox.url") ?? "http://127.0.0.1:17493"
        self.defaultProfile = "default"  // VoiceBox default profile

        logger.info("[VoiceBoxTTS] VoiceBox server: \(self.baseURL)")
    }

    /// Synthesize speech from text using VoiceBox HTTP API
    /// Returns PCM audio data (format depends on VoiceBox config, typically 24kHz mono 16-bit)
    func synthesize(text: String, voice: String? = nil, speed: Float? = nil) async throws -> Data {
        let profileToUse = voice ?? voiceProfile
        let speedToUse = speed ?? speechSpeed
        logger.info("[VoiceBoxTTS] Synthesizing: \(text.prefix(50)) [profile: \(profileToUse), speed: \(speedToUse)]")

        // VoiceBox /speak endpoint
        guard let url = URL(string: "\(baseURL)/speak") else {
            throw VoiceBoxError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("soniquebar", forHTTPHeaderField: "X-Voicebox-Client-Id")
        request.timeoutInterval = 30

        let payload: [String: Any] = [
            "text": text,
            "profile": profileToUse,
            "language": "en",
            "speed": speedToUse
        ]

        guard let jsonData = try? JSONSerialization.data(withJSONObject: payload) else {
            throw VoiceBoxError.serializationFailed
        }

        request.httpBody = jsonData

        do {
            let (data, response) = try await URLSession.shared.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse else {
                throw VoiceBoxError.invalidResponse
            }

            logger.info("[VoiceBoxTTS] HTTP \(httpResponse.statusCode), received \(data.count) bytes")

            guard httpResponse.statusCode == 200 else {
                if let errorString = String(data: data, encoding: .utf8) {
                    logger.error("[VoiceBoxTTS] Server error: \(errorString)")
                }
                throw VoiceBoxError.httpError(httpResponse.statusCode)
            }

            // VoiceBox returns audio directly (format in Content-Type header)
            let contentType = httpResponse.value(forHTTPHeaderField: "Content-Type") ?? "audio/wav"
            logger.info("[VoiceBoxTTS] Content-Type: \(contentType)")

            // If WAV, extract PCM data (skip 44-byte header)
            if contentType.contains("wav") && data.count > 44 {
                let pcmData = data.suffix(from: 44)
                logger.info("[VoiceBoxTTS] Generated \(pcmData.count) bytes PCM from WAV")
                return pcmData
            } else {
                // Already PCM or other format - return as-is
                logger.info("[VoiceBoxTTS] Generated \(data.count) bytes audio")
                return data
            }
        } catch let error as VoiceBoxError {
            throw error
        } catch {
            logger.error("[VoiceBoxTTS] Request failed: \(error.localizedDescription)")
            throw VoiceBoxError.networkError(error.localizedDescription)
        }
    }

    /// Check if VoiceBox server is reachable
    func healthCheck() async -> Bool {
        guard let url = URL(string: "\(baseURL)/health") else {
            return false
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 5

        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            if let httpResponse = response as? HTTPURLResponse {
                return httpResponse.statusCode == 200
            }
            return false
        } catch {
            logger.error("[VoiceBoxTTS] Health check failed: \(error.localizedDescription)")
            return false
        }
    }

    enum VoiceBoxError: Error {
        case invalidURL
        case serializationFailed
        case invalidResponse
        case httpError(Int)
        case networkError(String)
    }
}
