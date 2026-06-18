import Foundation
import ScreenCaptureKit
import AppKit

/// Modern screen capture using ScreenCaptureKit (macOS 12.3+)
/// Provides efficient live screen feed without repeated permission prompts
@available(macOS 12.3, *)
@MainActor
class LiveScreenCapture: NSObject, ObservableObject {
    static let shared = LiveScreenCapture()

    @Published var isCapturing = false
    @Published var lastFrameTime: Date?

    private var stream: SCStream?
    private var streamOutput: StreamOutput?

    // Screen capture configuration
    private let targetFPS = 2  // 2 frames per second (one frame every 500ms)
    private let screenshotDir = "/tmp/sonique-live-screen"

    private override init() {
        super.init()
        setupScreenshotDirectory()
    }

    private func setupScreenshotDirectory() {
        try? FileManager.default.createDirectory(
            atPath: screenshotDir,
            withIntermediateDirectories: true
        )
    }

    /// Start live screen capture
    func startCapture() async throws {
        guard !isCapturing else { return }

        // Get available content (displays and windows)
        let availableContent = try await SCShareableContent.excludingDesktopWindows(
            false,
            onScreenWindowsOnly: true
        )

        // Get main display
        guard let display = availableContent.displays.first else {
            throw CaptureError.noDisplayFound
        }

        // Create filter (capture entire display)
        let filter = SCContentFilter(display: display, excludingWindows: [])

        // Configure stream
        let config = SCStreamConfiguration()
        config.width = Int(display.width)
        config.height = Int(display.height)
        config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(targetFPS))
        config.queueDepth = 3
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.showsCursor = true

        // Create stream
        stream = SCStream(filter: filter, configuration: config, delegate: nil)

        // Create output handler
        streamOutput = StreamOutput(screenshotDir: screenshotDir) { [weak self] in
            Task { @MainActor in
                self?.lastFrameTime = Date()
            }
        }

        // Add stream output
        try stream?.addStreamOutput(
            streamOutput!,
            type: .screen,
            sampleHandlerQueue: DispatchQueue(label: "com.seayniclabs.soniquebar.screencapture")
        )

        // Start capture
        try await stream?.startCapture()
        isCapturing = true

        print("[LiveScreenCapture] Started capturing at \(targetFPS) fps")
    }

    /// Stop live screen capture
    func stopCapture() async throws {
        guard isCapturing else { return }

        try await stream?.stopCapture()
        stream = nil
        streamOutput = nil
        isCapturing = false

        print("[LiveScreenCapture] Stopped capture")
    }

    /// Get path to the most recent frame
    func getLatestFrame() -> String? {
        guard let files = try? FileManager.default.contentsOfDirectory(atPath: screenshotDir) else {
            return nil
        }

        let frames = files
            .filter { $0.hasPrefix("frame-") && $0.hasSuffix(".png") }
            .sorted()

        guard let latest = frames.last else { return nil }
        return "\(screenshotDir)/\(latest)"
    }

    enum CaptureError: Error {
        case noDisplayFound
    }
}

/// Handles incoming screen frames
@available(macOS 12.3, *)
private class StreamOutput: NSObject, SCStreamOutput {
    private let screenshotDir: String
    private let onFrameReceived: () -> Void
    private let maxStoredFrames = 5

    init(screenshotDir: String, onFrameReceived: @escaping () -> Void) {
        self.screenshotDir = screenshotDir
        self.onFrameReceived = onFrameReceived
        super.init()
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen,
              let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            return
        }

        // Convert to NSImage
        let ciImage = CIImage(cvPixelBuffer: imageBuffer)
        let context = CIContext()

        guard let cgImage = context.createCGImage(ciImage, from: ciImage.extent) else {
            return
        }

        let nsImage = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))

        // Save to disk
        let timestamp = Int(Date().timeIntervalSince1970 * 1000)  // milliseconds for uniqueness
        let path = "\(screenshotDir)/frame-\(timestamp).png"

        if let tiffData = nsImage.tiffRepresentation,
           let bitmapImage = NSBitmapImageRep(data: tiffData),
           let pngData = bitmapImage.representation(using: .png, properties: [:]) {
            try? pngData.write(to: URL(fileURLWithPath: path))

            // Cleanup old frames
            cleanupOldFrames()

            // Notify
            onFrameReceived()
        }
    }

    private func cleanupOldFrames() {
        guard let files = try? FileManager.default.contentsOfDirectory(atPath: screenshotDir) else {
            return
        }

        let frames = files
            .filter { $0.hasPrefix("frame-") && $0.hasSuffix(".png") }
            .sorted()

        if frames.count > maxStoredFrames {
            let toDelete = frames.prefix(frames.count - maxStoredFrames)
            for file in toDelete {
                try? FileManager.default.removeItem(atPath: "\(screenshotDir)/\(file)")
            }
        }
    }
}
