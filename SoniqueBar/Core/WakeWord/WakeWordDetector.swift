import Foundation
import AVFoundation
import AppKit

/// Protocol for wake word detection
protocol WakeWordDetector: Sendable {
    var isListening: Bool { get }
    var wakeWords: [String] { get }

    /// Start listening for wake word
    func startListening() async throws

    /// Stop listening
    func stopListening() async

    /// Set callback for wake word detection
    func onWakeWord(_ callback: @escaping @Sendable (String) -> Void)
}

/// Wake word detection errors
enum WakeWordError: Error, LocalizedError {
    case notAvailable
    case permissionDenied
    case microphoneNotFound
    case alreadyListening

    var errorDescription: String? {
        switch self {
        case .notAvailable:
            return "Wake word detection not available"
        case .permissionDenied:
            return "Microphone permission denied"
        case .microphoneNotFound:
            return "No microphone found"
        case .alreadyListening:
            return "Already listening for wake word"
        }
    }
}

/// Basic wake word detector using keyword spotting
/// TODO: Integrate Porcupine SDK for better accuracy
@MainActor
class BasicWakeWordDetector: NSObject, WakeWordDetector {
    private(set) var isListening = false
    let wakeWords = ["hey quinn", "quinn", "okay quinn"]

    private var audioEngine: AVAudioEngine?
    private var recognitionRequest: AVAudioInputNode?
    private var wakeWordCallback: (@Sendable (String) -> Void)?

    func onWakeWord(_ callback: @escaping @Sendable (String) -> Void) {
        wakeWordCallback = callback
    }

    func startListening() async throws {
        guard !isListening else {
            throw WakeWordError.alreadyListening
        }

        // Request microphone permission
        let authorized = await withCheckedContinuation { continuation in
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                continuation.resume(returning: granted)
            }
        }

        guard authorized else {
            throw WakeWordError.permissionDenied
        }

        // Set up audio engine
        audioEngine = AVAudioEngine()
        guard let audioEngine = audioEngine else {
            throw WakeWordError.notAvailable
        }

        let inputNode = audioEngine.inputNode
        let recordingFormat = inputNode.outputFormat(forBus: 0)

        // Install tap on audio input
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: recordingFormat) { [weak self] buffer, time in
            Task { @MainActor in
                self?.processAudioBuffer(buffer)
            }
        }

        audioEngine.prepare()

        do {
            try audioEngine.start()
            isListening = true
            print("[WakeWord] Started listening for: \(wakeWords.joined(separator: ", "))")
        } catch {
            throw WakeWordError.notAvailable
        }
    }

    func stopListening() async {
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine?.stop()
        audioEngine = nil
        isListening = false
        print("[WakeWord] Stopped listening")
    }

    // MARK: - Audio Processing

    private func processAudioBuffer(_ buffer: AVAudioPCMBuffer) {
        // Basic keyword spotting placeholder
        // TODO: Integrate Porcupine for real wake word detection
        // For now, this is a stub that would need actual speech recognition

        // In production, this would:
        // 1. Convert audio buffer to PCM samples
        // 2. Feed to Porcupine wake word engine
        // 3. Trigger callback on detection

        // Placeholder for demonstration
        // Real implementation requires Porcupine SDK integration
    }
}

/// Porcupine-based wake word detector
/// Requires: pod 'Porcupine-iOS' or manual SDK integration
class PorcupineWakeWordDetector: NSObject, WakeWordDetector {
    private(set) var isListening = false
    let wakeWords = ["hey quinn", "quinn"]

    private var wakeWordCallback: (@Sendable (String) -> Void)?

    func onWakeWord(_ callback: @escaping @Sendable (String) -> Void) {
        wakeWordCallback = callback
    }

    func startListening() async throws {
        // TODO: Implement Porcupine integration
        // Reference: https://github.com/Picovoice/porcupine/tree/master/binding/ios
        //
        // Steps:
        // 1. Initialize Porcupine with custom wake word model
        // 2. Start audio capture
        // 3. Process audio frames through Porcupine
        // 4. Trigger callback on detection

        throw WakeWordError.notAvailable
    }

    func stopListening() async {
        // TODO: Stop Porcupine and audio capture
    }
}

/// Wake word manager - coordinates detection and actions
@MainActor
class WakeWordManager: ObservableObject {
    static let shared = WakeWordManager()

    @Published var isEnabled: Bool = false
    @Published private(set) var isListening: Bool = false

    private var detector: (any WakeWordDetector)?
    private let commandServer = CommandServer.shared

    private init() {}

    func enable() async throws {
        guard !isEnabled else { return }

        // Use basic detector for now (TODO: switch to Porcupine when integrated)
        detector = BasicWakeWordDetector()

        detector?.onWakeWord { [weak self] wakeWord in
            Task { @MainActor in
                await self?.handleWakeWord(wakeWord)
            }
        }

        try await detector?.startListening()

        isEnabled = true
        isListening = detector?.isListening ?? false

        print("[WakeWordManager] Wake word detection enabled")
    }

    func disable() async {
        guard isEnabled else { return }

        await detector?.stopListening()
        detector = nil

        isEnabled = false
        isListening = false

        print("[WakeWordManager] Wake word detection disabled")
    }

    private func handleWakeWord(_ wakeWord: String) async {
        print("[WakeWordManager] Wake word detected: \(wakeWord)")

        // Play acknowledgment sound
        NSSound.beep()

        // TODO: Start listening for command
        // This would:
        // 1. Play acknowledgment chime
        // 2. Start recording user command
        // 3. Send to CommandServer when silence detected
        // 4. Speak response via VoiceRouter
    }
}
