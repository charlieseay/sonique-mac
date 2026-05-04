import Foundation
import AVFoundation

/// Manages voice playback for the CAAL backend.
/// Calls /api/chat/voice to get audio responses and plays them through system audio.
@MainActor
class VoiceManager: NSObject, ObservableObject, AVAudioPlayerDelegate {
    @Published var isPlaying = false
    @Published var error: String?

    private let sessionId = "sonique-main"
    private var backendURL: String = "http://localhost:8891"
    private var apiKey: String = ""
    private var audioPlayer: AVAudioPlayer?

    func configure(backendURL: String, apiKey: String) {
        self.backendURL = backendURL
        self.apiKey = apiKey
    }

    /// Fetch voice response for the given text and play it.
    func playVoice(for text: String) async {
        guard !text.isEmpty else { return }

        do {
            let audioData = try await fetchVoiceAudio(for: text)
            try playAudio(data: audioData)
            isPlaying = true
            error = nil
        } catch {
            self.error = error.localizedDescription
            isPlaying = false
        }
    }

    // MARK: - Private

    private func fetchVoiceAudio(for text: String) async throws -> Data {
        guard let url = URL(string: "\(backendURL)/api/chat/voice") else {
            throw NSError(domain: "VoiceManager", code: 1, userInfo: [NSLocalizedDescriptionKey: "Invalid backend URL"])
        }

        let body = try JSONSerialization.data(withJSONObject: [
            "text": text,
            "session_id": sessionId,
        ])

        var req = URLRequest(url: url, timeoutInterval: 30)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !apiKey.isEmpty {
            req.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        }
        req.httpBody = body

        let (data, response) = try await URLSession.shared.data(for: req)

        guard let httpResponse = response as? HTTPURLResponse, (200...299).contains(httpResponse.statusCode) else {
            throw NSError(domain: "VoiceManager", code: 2, userInfo: [NSLocalizedDescriptionKey: "Voice API returned error"])
        }

        return data
    }

    private func playAudio(data: Data) throws {
        let player = try AVAudioPlayer(data: data, fileTypeHint: AVFileType.wav.rawValue)
        player.delegate = self
        player.volume = 1.0
        player.prepareToPlay()
        guard player.play() else {
            throw NSError(
                domain: "VoiceManager",
                code: 3,
                userInfo: [NSLocalizedDescriptionKey: "Audio engine did not start playback"]
            )
        }
        audioPlayer = player
    }

    // MARK: - AVAudioPlayerDelegate

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in
            self.isPlaying = false
        }
    }

    nonisolated func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        Task { @MainActor in
            self.error = error?.localizedDescription ?? "Audio decode error"
            self.isPlaying = false
        }
    }
}
