//
//  EmbeddedTTSProvider.swift
//  SoniqueBar
//
//  Created by Claude on 2026-06-29.
//  TTS provider using embedded PyInstaller binary (App Store compatible).
//

import Foundation
import AVFoundation
import os.log

/// TTS provider that uses an embedded Python binary for Kokoro TTS.
/// Communicates via stdin/stdout pipes (no network required).
class EmbeddedTTSProvider: NSObject {
    private let logger = Logger(subsystem: "com.seayniclabs.SoniqueBar", category: "EmbeddedTTS")

    private var process: Process?
    private var stdinPipe = Pipe()
    private var stdoutPipe = Pipe()
    private var stderrPipe = Pipe()

    private var isReady = false
    private var startupQueue = DispatchQueue(label: "com.seayniclabs.soniquebar.tts.startup")

    // MARK: - Debug Logging

    private func logToFile(_ path: URL, _ message: String) {
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let line = "[\(timestamp)] \(message)\n"
        if let data = line.data(using: .utf8) {
            if FileManager.default.fileExists(atPath: path.path) {
                if let handle = try? FileHandle(forWritingTo: path) {
                    handle.seekToEndOfFile()
                    handle.write(data)
                    try? handle.close()
                }
            } else {
                try? data.write(to: path)
            }
        }
    }

    // MARK: - Lifecycle

    func start() throws {
        logger.info("Starting embedded TTS engine...")

        // Log to file for debugging
        let logPath = FileManager.default.temporaryDirectory.appendingPathComponent("embedded-tts-debug.log")
        logToFile(logPath, "=== TTS Engine Start ===")
        logToFile(logPath, "Timestamp: \(Date())")

        // Find the embedded binary
        guard let binaryPath = Bundle.main.path(forResource: "sonique-tts", ofType: nil) else {
            logToFile(logPath, "ERROR: Binary not found in bundle")
            throw TTSError.binaryNotFound
        }

        logger.info("Binary found at: \(binaryPath)")
        logToFile(logPath, "Binary path: \(binaryPath)")

        // Create process
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: binaryPath)

        // Set working directory to Resources folder (binary needs to run from there)
        if let resourcesPath = Bundle.main.resourcePath {
            proc.currentDirectoryURL = URL(fileURLWithPath: resourcesPath)
            logger.info("Working directory set to: \(resourcesPath)")
        }

        proc.standardInput = stdinPipe
        proc.standardOutput = stdoutPipe
        proc.standardError = stderrPipe

        // Monitor stderr for READY signal and logs
        stderrPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }

            if let line = String(data: data, encoding: .utf8) {
                self?.logger.debug("[TTS stderr] \(line.trimmingCharacters(in: .whitespacesAndNewlines))")

                if line.contains("READY") {
                    self?.isReady = true
                    self?.logger.info("✅ TTS engine ready")
                }
            }
        }

        // Handle process termination
        proc.terminationHandler = { [weak self] proc in
            self?.logger.warning("TTS process terminated with exit code: \(proc.terminationStatus)")
            self?.isReady = false
        }

        // Start process
        do {
            try proc.run()
            self.process = proc
            logger.info("TTS process started (PID: \(proc.processIdentifier))")
            logToFile(logPath, "Process started (PID: \(proc.processIdentifier))")
        } catch {
            logToFile(logPath, "ERROR: Failed to start process: \(error)")
            throw error
        }

        // Wait for READY signal (timeout after 30 seconds)
        logToFile(logPath, "Waiting for READY signal...")
        let deadline = DispatchTime.now() + .seconds(30)
        while !isReady && DispatchTime.now() < deadline {
            Thread.sleep(forTimeInterval: 0.1)
        }

        if isReady {
            logToFile(logPath, "✅ READY signal received")
        } else {
            logToFile(logPath, "❌ Timeout waiting for READY signal")
            throw TTSError.startupTimeout
        }
    }

    func shutdown() {
        logger.info("Shutting down TTS engine...")

        // Close pipes
        stdinPipe.fileHandleForWriting.closeFile()

        // Terminate process
        process?.terminate()

        // Wait for graceful exit (5 second timeout)
        let deadline = DispatchTime.now() + .seconds(5)
        while process?.isRunning == true && DispatchTime.now() < deadline {
            Thread.sleep(forTimeInterval: 0.1)
        }

        // Force kill if still running
        if process?.isRunning == true {
            logger.warning("Force killing TTS process")
            process?.interrupt()
        }

        isReady = false
        process = nil

        logger.info("TTS engine shut down")
    }

    // MARK: - Synthesis

    func synthesize(text: String, voice: String = "af_bella") async throws -> AVAudioPCMBuffer {
        guard isReady else {
            throw TTSError.engineNotReady
        }

        logger.info("Synthesizing text (\(text.count) chars) with voice: \(voice)")

        return try await withCheckedThrowingContinuation { continuation in
            startupQueue.async { [weak self] in
                guard let self = self else {
                    continuation.resume(throwing: TTSError.engineNotReady)
                    return
                }

                do {
                    // Create request
                    let request: [String: String] = ["text": text, "voice": voice]
                    let jsonData = try JSONEncoder().encode(request)

                    // Send request (JSON line)
                    var lineData = jsonData
                    lineData.append(0x0A) // newline
                    self.stdinPipe.fileHandleForWriting.write(lineData)

                    // Read response: 4-byte length + audio bytes
                    let lengthData = self.stdoutPipe.fileHandleForReading.readData(ofLength: 4)
                    guard lengthData.count == 4 else {
                        throw TTSError.invalidResponse("Failed to read length prefix")
                    }

                    let length = lengthData.withUnsafeBytes { $0.load(as: UInt32.self).bigEndian }
                    self.logger.debug("Reading \(length) bytes of audio data")

                    // Read audio data
                    let audioData = self.stdoutPipe.fileHandleForReading.readData(ofLength: Int(length))
                    guard audioData.count == length else {
                        throw TTSError.invalidResponse("Expected \(length) bytes, got \(audioData.count)")
                    }

                    // Convert to AVAudioPCMBuffer
                    let buffer = try self.convertToAudioBuffer(audioData)

                    self.logger.info("✅ Synthesized \(buffer.frameLength) frames (\(String(format: "%.2f", Float(buffer.frameLength) / 24000.0))s)")

                    continuation.resume(returning: buffer)
                } catch {
                    self.logger.error("Synthesis failed: \(error.localizedDescription)")
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    // MARK: - Audio Conversion

    private func convertToAudioBuffer(_ data: Data) throws -> AVAudioPCMBuffer {
        // Audio is float32 samples at 24kHz
        let sampleRate: Double = 24000
        let channelCount = 1

        // Convert bytes to float32 array
        let floatCount = data.count / MemoryLayout<Float>.size
        var samples = [Float](repeating: 0, count: floatCount)
        _ = samples.withUnsafeMutableBytes { data.copyBytes(to: $0) }

        // Create audio format
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: AVAudioChannelCount(channelCount),
            interleaved: false
        ) else {
            throw TTSError.audioConversionFailed("Failed to create audio format")
        }

        // Create buffer
        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: AVAudioFrameCount(floatCount)
        ) else {
            throw TTSError.audioConversionFailed("Failed to create audio buffer")
        }

        buffer.frameLength = AVAudioFrameCount(floatCount)

        // Copy samples
        guard let channelData = buffer.floatChannelData else {
            throw TTSError.audioConversionFailed("No channel data")
        }

        for i in 0..<floatCount {
            channelData[0][i] = samples[i]
        }

        return buffer
    }
}

// MARK: - Errors

enum TTSError: LocalizedError {
    case binaryNotFound
    case startupTimeout
    case engineNotReady
    case invalidResponse(String)
    case audioConversionFailed(String)

    var errorDescription: String? {
        switch self {
        case .binaryNotFound:
            return "Embedded TTS binary not found in app bundle"
        case .startupTimeout:
            return "TTS engine failed to start within 30 seconds"
        case .engineNotReady:
            return "TTS engine not ready"
        case .invalidResponse(let msg):
            return "Invalid TTS response: \(msg)"
        case .audioConversionFailed(let msg):
            return "Audio conversion failed: \(msg)"
        }
    }
}
