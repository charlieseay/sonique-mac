import Foundation
import Starscream

/// ElevenLabs streaming TTS client.
/// Converts text to speech via WebSocket and streams audio chunks back.
class TTSStreamer: WebSocketDelegate {
    private var socket: WebSocket?
    private let apiKey: String
    private let voiceID = "21m00Tcm4TlvDq8ikWAM" // Rachel (default voice)

    var onAudioChunk: ((Data) -> Void)?
    var onError: ((Error) -> Void)?
    var onConnected: (() -> Void)?

    init(apiKey: String) {
        self.apiKey = apiKey
    }

    func connect() {
        let urlString = "wss://api.elevenlabs.io/v1/text-to-speech/\(voiceID)/stream-input"
        var request = URLRequest(url: URL(string: urlString)!)
        request.setValue(apiKey, forHTTPHeaderField: "xi-api-key")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        socket = WebSocket(request: request)
        socket?.delegate = self
        socket?.connect()

        print("[TTSStreamer] Connecting to ElevenLabs...")
    }

    func disconnect() {
        socket?.disconnect()
        socket = nil
        print("[TTSStreamer] Disconnected")
    }

    /// Send text to be synthesized
    func speak(_ text: String, completion: @escaping (Result<Void, Error>) -> Void) {
        guard let socket = socket, socket.isConnected else {
            completion(.failure(TTSError.notConnected))
            return
        }

        let message: [String: Any] = [
            "text": text,
            "voice_settings": [
                "stability": 0.5,
                "similarity_boost": 0.75
            ],
            "generation_config": [
                "chunk_length_schedule": [120, 160, 250, 290]
            ]
        ]

        do {
            let data = try JSONSerialization.data(withJSONObject: message)
            socket.write(data: data)
            print("[TTSStreamer] Sent text: \(text.prefix(50))...")
            completion(.success(()))
        } catch {
            completion(.failure(error))
        }
    }

    // MARK: - WebSocketDelegate

    func didReceive(event: Starscream.WebSocketEvent, client: any Starscream.WebSocketClient) {
        switch event {
        case .connected(let headers):
            print("[TTSStreamer] Connected: \(headers)")
            onConnected?()

        case .disconnected(let reason, let code):
            print("[TTSStreamer] Disconnected: \(reason) (code: \(code))")

        case .text(let string):
            print("[TTSStreamer] Received text: \(string)")

        case .binary(let data):
            // This is the MP3 audio chunk
            print("[TTSStreamer] Received audio chunk: \(data.count) bytes")
            onAudioChunk?(data)

        case .error(let error):
            print("[TTSStreamer] Error: \(String(describing: error))")
            if let error = error {
                onError?(error)
            }

        case .cancelled:
            print("[TTSStreamer] Connection cancelled")

        case .ping, .pong, .viabilityChanged, .reconnectSuggested, .peerClosed:
            break
        }
    }
}

// MARK: - Errors

enum TTSError: Error {
    case notConnected
    case invalidResponse
    case audioDecodingFailed
}
