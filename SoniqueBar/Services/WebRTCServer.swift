import Foundation
import WebRTC
import Network

/// WebRTC signaling server for Sonique voice sessions.
/// Manages peer connections from iOS clients and routes audio streams.
@MainActor
class WebRTCServer: ObservableObject {
    @Published var isRunning = false
    @Published var activeConnections: Int = 0

    private var listener: NWListener?
    private var connections: [String: RTCPeerConnection] = [:]
    private let port: NWEndpoint.Port = 8890

    // WebRTC configuration
    private let config: RTCConfiguration = {
        let config = RTCConfiguration()
        config.iceServers = [
            RTCIceServer(urlStrings: ["stun:stun.l.google.com:19302"])
        ]
        return config
    }()

    private let factory: RTCPeerConnectionFactory = {
        RTCInitializeSSL()
        let encoderFactory = RTCDefaultVideoEncoderFactory()
        let decoderFactory = RTCDefaultVideoDecoderFactory()
        return RTCPeerConnectionFactory(
            encoderFactory: encoderFactory,
            decoderFactory: decoderFactory
        )
    }()

    init() {
        setupListener()
    }

    deinit {
        stop()
        RTCCleanupSSL()
    }

    func start() {
        guard !isRunning else { return }

        listener?.start(queue: .main)
        isRunning = true
        print("[WebRTCServer] Started on port \(port)")
    }

    func stop() {
        guard isRunning else { return }

        listener?.cancel()
        connections.values.forEach { $0.close() }
        connections.removeAll()
        isRunning = false
        activeConnections = 0
        print("[WebRTCServer] Stopped")
    }

    private func setupListener() {
        do {
            listener = try NWListener(using: .tcp, on: port)

            listener?.newConnectionHandler = { [weak self] connection in
                self?.handleNewConnection(connection)
            }

            listener?.stateUpdateHandler = { [weak self] state in
                self?.handleListenerStateChange(state)
            }
        } catch {
            print("[WebRTCServer] Failed to create listener: \(error)")
        }
    }

    private func handleNewConnection(_ connection: NWConnection) {
        let connectionID = UUID().uuidString
        print("[WebRTCServer] New connection: \(connectionID)")

        connection.start(queue: .main)

        // TODO: Handle signaling protocol (SDP offer/answer)
        // TODO: Create RTCPeerConnection for this client
        // TODO: Wire audio tracks

        Task {
            await MainActor.run {
                activeConnections += 1
            }
        }
    }

    private func handleListenerStateChange(_ state: NWListener.State) {
        switch state {
        case .ready:
            print("[WebRTCServer] Listener ready")
        case .failed(let error):
            print("[WebRTCServer] Listener failed: \(error)")
            Task {
                await MainActor.run {
                    isRunning = false
                }
            }
        case .cancelled:
            print("[WebRTCServer] Listener cancelled")
        default:
            break
        }
    }

    // MARK: - Signaling

    /// Handle SDP offer from iOS client
    func handleOffer(_ sdp: String, from clientID: String) async throws -> String {
        // TODO: Create peer connection
        // TODO: Set remote description (offer)
        // TODO: Create answer
        // TODO: Return SDP answer

        fatalError("Not implemented")
    }

    /// Handle ICE candidate from iOS client
    func handleICECandidate(_ candidate: String, from clientID: String) async throws {
        // TODO: Add ICE candidate to peer connection

        fatalError("Not implemented")
    }
}

// MARK: - RTCPeerConnectionDelegate

extension WebRTCServer: RTCPeerConnectionDelegate {
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange stateChanged: RTCSignalingState) {
        print("[WebRTCServer] Signaling state: \(stateChanged)")
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didAdd stream: RTCMediaStream) {
        print("[WebRTCServer] Media stream added")

        // TODO: Extract audio track
        // TODO: Send to AudioPipeline for processing
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove stream: RTCMediaStream) {
        print("[WebRTCServer] Media stream removed")
    }

    func peerConnectionShouldNegotiate(_ peerConnection: RTCPeerConnection) {
        print("[WebRTCServer] Should negotiate")
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceConnectionState) {
        print("[WebRTCServer] ICE connection state: \(newState)")

        if newState == .disconnected || newState == .failed {
            // TODO: Clean up connection
        }
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceGatheringState) {
        print("[WebRTCServer] ICE gathering state: \(newState)")
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didGenerate candidate: RTCIceCandidate) {
        print("[WebRTCServer] ICE candidate generated: \(candidate.sdp)")

        // TODO: Send candidate to iOS client via signaling channel
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove candidates: [RTCIceCandidate]) {
        print("[WebRTCServer] ICE candidates removed")
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didOpen dataChannel: RTCDataChannel) {
        print("[WebRTCServer] Data channel opened")
    }
}
