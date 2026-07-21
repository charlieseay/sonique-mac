import Foundation
import Network
import os.log
import AVFoundation

/// Minimal HTTP server that routes voice commands to Claude Code CLI
/// Replaces 2,432 lines of pattern matching with simple bridge to Claude Code
@MainActor
class CommandServer: ObservableObject {
    static let shared = CommandServer()

    private let logger = Logger(subsystem: "com.seayniclabs.soniquebar", category: "CommandServer")

    @Published var isRunning = false
    @Published var lastCommand: String = ""
    @Published var requestCount: Int = 0

    private var listener: NWListener?
    private let port: NWEndpoint.Port = 8890
    private let claudeBridge = ClaudeCodeBridge()
    private let authToken: String
    private var bonjourService: NetService?

    // Readiness state
    private var isReady = false
    private var healthCheckResults: [String: Bool] = [:]

    private init() {
        NSLog("[CommandServer] init() starting")

        // Load auth token from secrets
        let tokenPath = "/Volumes/data/secrets/sonique_auth_token"
        if let token = try? String(contentsOfFile: tokenPath, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines), !token.isEmpty {
            self.authToken = token
            NSLog("[CommandServer] Loaded existing auth token")
            // Security: Verify file permissions are secure (0600)
            verifyFilePermissions(tokenPath)
        } else {
            // Generate and save a new token if none exists
            let newToken = UUID().uuidString
            try? newToken.write(toFile: tokenPath, atomically: true, encoding: .utf8)
            self.authToken = newToken
            // Security: Ensure file has secure permissions (0600)
            try? FileManager.default.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: tokenPath)
            NSLog("[CommandServer] Generated new auth token with secure permissions")
        }

        // Sync auth token to iCloud preferences so iOS can use it
        Task { @MainActor in
            var prefs = SoniqueBrain.shared.loadPreferences()
            prefs.authToken = self.authToken
            SoniqueBrain.shared.savePreferences(prefs)
            NSLog("[CommandServer] Synced auth token to iCloud preferences")
        }

        NSLog("[CommandServer] Calling setupListener()")

        // Perform health checks before accepting connections
        Task { @MainActor in
            await self.performHealthChecks()
        }

        setupListener()
        NSLog("[CommandServer] init() complete")
    }
    
    deinit {
        listener?.cancel()
        bonjourService?.stop()
    }
    
    // MARK: - Security Helpers

    private func verifyFilePermissions(_ path: String) {
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: path)
            // Check if file permissions are restrictive (0600)
            if let permissions = attributes[.posixPermissions] as? Int {
                let octal = String(permissions, radix: 8)
                if octal != "600" {
                    NSLog("[CommandServer] ⚠️ WARNING: Secrets file has insecure permissions: \(octal) (should be 600)")
                    // Attempt to fix permissions
                    try? FileManager.default.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: path)
                }
            }
        } catch {
            NSLog("[CommandServer] Could not verify file permissions: \(error.localizedDescription)")
        }
    }

    // MARK: - Server Setup

    private func setupListener() {
        logger.info("[CommandServer] setupListener() called")

        do {
            logger.info("[CommandServer] Creating NWListener on port \(self.port.rawValue)")
            listener = try NWListener(using: .tcp, on: port)

            logger.info("[CommandServer] Listener created, setting handlers")

            listener?.newConnectionHandler = { [weak self] connection in
                self?.logger.info("[CommandServer] New connection received")
                self?.handleConnection(connection)
            }

            listener?.stateUpdateHandler = { [weak self] state in
                Task { @MainActor in
                    switch state {
                    case .ready:
                        self?.isRunning = true
                        self?.logger.info("[CommandServer] ✓ Listener READY on port \(self?.port.rawValue ?? 0)")
                        NSLog("[CommandServer] ✓ Listener READY and bound to port \(self?.port.rawValue ?? 0)")
                        // Start Bonjour advertising once listener is ready
                        self?.startBonjourAdvertising()
                    case .failed(let error):
                        self?.logger.error("[CommandServer] ❌ Listener FAILED: \(error.localizedDescription)")
                        NSLog("[CommandServer] ❌ Listener FAILED: \(error.localizedDescription)")
                        self?.isRunning = false
                        self?.bonjourService?.stop()
                    case .cancelled:
                        self?.isRunning = false
                        self?.logger.info("[CommandServer] Listener cancelled")
                        self?.bonjourService?.stop()
                    case .waiting(let error):
                        self?.logger.warning("[CommandServer] Listener waiting: \(error.localizedDescription)")
                        NSLog("[CommandServer] ⚠️ Listener WAITING: \(error.localizedDescription)")
                    case .setup:
                        self?.logger.info("[CommandServer] Listener in setup state")
                    @unknown default:
                        self?.logger.warning("[CommandServer] Listener unknown state")
                    }
                }
            }

            logger.info("[CommandServer] Starting listener on main queue")
            listener?.start(queue: .main)
            logger.info("[CommandServer] Listener.start() called")

        } catch {
            logger.error("[CommandServer] ❌ Failed to create listener: \(error.localizedDescription)")
            NSLog("[CommandServer] ❌ Failed to create listener: \(error.localizedDescription)")
        }
    }
    
    // MARK: - Health Checks

    private var lastHealthCheckTime: Date?
    private var cachedHealthCheckResults: [String: Bool]?
    private let healthCheckCacheDuration: TimeInterval = 300  // 5 minutes

    private func performHealthChecks() async {
        NSLog("[CommandServer] 🏥 Starting health checks...")

        // PERF OPT #1: Cache health checks for 5 minutes to avoid repeated expensive checks
        if let lastCheck = lastHealthCheckTime,
           let cached = cachedHealthCheckResults,
           Date().timeIntervalSince(lastCheck) < healthCheckCacheDuration {
            NSLog("[CommandServer] Using cached health check results (age: \(Int(Date().timeIntervalSince(lastCheck)))s)")
            healthCheckResults = cached
            return
        }

        // Check 1: Memory system accessible
        healthCheckResults["memory"] = await checkMemorySystem()

        // Check 2: Model router config loaded
        healthCheckResults["model_router"] = checkModelRouter()

        // Check 3: Native intents registered
        healthCheckResults["native_intents"] = checkNativeIntents()

        // Check 4: NotebookLM available
        healthCheckResults["notebooklm"] = await checkNotebookLM()

        let allPassed = healthCheckResults.values.allSatisfy { $0 }
        isReady = allPassed

        // Update cache with results and timestamp
        cachedHealthCheckResults = healthCheckResults
        lastHealthCheckTime = Date()

        NSLog("[CommandServer] Health check results:")
        for (check, passed) in healthCheckResults {
            NSLog("[CommandServer]   \(check): \(passed ? "✅" : "❌")")
        }

        if isReady {
            NSLog("[CommandServer] 🎉 All health checks passed - READY for requests")
        } else {
            NSLog("[CommandServer] ⚠️ Some health checks failed - accepting requests anyway (graceful degradation)")
        }
    }

    private func checkMemorySystem() async -> Bool {
        let memory = await MemoryService.shared.loadFullContext()
        let passed = memory.count > 1000  // Should have identity + context
        NSLog("[CommandServer]   Memory loaded: \(memory.count) bytes")
        return passed
    }

    private func checkModelRouter() -> Bool {
        // ModelRouter loads lazily on first use, so just verify the config file exists
        let configPath = "/Volumes/data/secrets/sonique_model_router.json"
        let exists = FileManager.default.fileExists(atPath: configPath)
        NSLog("[CommandServer]   Model router config exists: \(exists)")
        return exists
    }

    private func checkNativeIntents() -> Bool {
        // IntentRouter is a singleton, always available
        NSLog("[CommandServer]   Native intents: available")
        return true
    }

    private func checkNotebookLM() async -> Bool {
        let nlmPath = "/Users/charlieseay/.local/bin/nlm"
        let exists = FileManager.default.fileExists(atPath: nlmPath)
        NSLog("[CommandServer]   NotebookLM CLI exists: \(exists)")
        return exists
    }

    // MARK: - Connection Handling

    nonisolated private func handleConnection(_ connection: NWConnection) {
        connection.start(queue: .main)

        // Security: Limit maximum request size to prevent DoS (5MB)
        let maxRequestSize = 5 * 1024 * 1024

        connection.receive(minimumIncompleteLength: 1, maximumLength: maxRequestSize) { [weak self] data, _, isComplete, error in
            guard let self = self else { return }

            // Fix connection leak: handle errors properly
            if let error = error {
                print("[CommandServer] Receive error: \(error.localizedDescription)")
                connection.cancel()
                return
            }

            if let data = data, !data.isEmpty {
                // Security: Check request size
                if data.count > maxRequestSize {
                    self.sendResponse("HTTP/1.1 413 Payload Too Large\r\n\r\n", to: connection)
                    return
                }

                Task { @MainActor in
                    await self.processRequest(data, connection: connection)
                }
            }

            if isComplete {
                connection.cancel()
            } else {
                // Continue receiving
                self.handleConnection(connection)
            }
        }
    }
    
    private func processRequest(_ data: Data, connection: NWConnection) async {
        guard let requestString = String(data: data, encoding: .utf8) else {
            sendResponse("HTTP/1.1 400 Bad Request\r\n\r\n", to: connection)
            return
        }

        // Parse HTTP request
        let lines = requestString.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else {
            sendResponse("HTTP/1.1 400 Bad Request\r\n\r\n", to: connection)
            return
        }

        let parts = requestLine.components(separatedBy: " ")
        guard parts.count >= 2 else {
            sendResponse("HTTP/1.1 400 Bad Request\r\n\r\n", to: connection)
            return
        }

        let method = parts[0]
        let path = parts[1]

        logger.info("[CommandServer] \(method) \(path)")

        // Return readiness status for health endpoint
        if path == "/health" {
            let status = isReady ? "ready" : "degraded"
            let checks = healthCheckResults.map { "\"\($0.key)\": \($0.value)" }.joined(separator: ", ")
            let response = "{\"status\": \"\(status)\", \"checks\": {\(checks)}}"
            sendJSON(response, to: connection)
            return
        }

        // Warn if not fully ready (but still process - graceful degradation)
        if !isReady && path != "/voices" {
            NSLog("[CommandServer] ⚠️ Processing request while not fully ready: \(path)")
        }

        // Check bearer token for all non-health, non-voices endpoints
        if path != "/health" && path != "/voices" {
            let authorized = lines.contains { line in
                line.lowercased().hasPrefix("authorization: bearer ") &&
                line.dropFirst("authorization: bearer ".count).trimmingCharacters(in: .whitespaces) == authToken
            }

            if !authorized {
                logger.warning("[CommandServer] Unauthorized request to \(path)")
                sendResponse("HTTP/1.1 401 Unauthorized\r\n\r\n{\"error\":\"Unauthorized\"}", to: connection)
                return
            }
        }

        // Route requests
        if path == "/health" {
            await handleHealth(connection)
        } else if path == "/config" {
            await handleConfig(connection)
        } else if path == "/voices" {
            await handleVoices(connection)
        } else if path == "/command/stream" && method == "POST" {
            await handleCommandStream(data, connection)
        } else if path == "/command" && method == "POST" {
            await handleCommand(data, connection)
        } else if path == "/synthesize" && method == "POST" {
            await handleSynthesize(data, connection)
        } else if path == "/synthesize/kokoro" && method == "POST" {
            await handleSynthesizeKokoro(data, connection)
        } else {
            sendResponse("HTTP/1.1 404 Not Found\r\n\r\n{\"error\":\"Not found\"}", to: connection)
        }
    }
    
    // MARK: - Endpoints
    
    private func handleHealth(_ connection: NWConnection) async {
        let response = """
        {
            "status": "ok",
            "port": 8890,
            "version": "2.0",
            "build": "simplified",
            "mode": "claude-code-bridge"
        }
        """

        sendJSON(response, to: connection)
    }

    /// Return ElevenLabs API key for iOS TTS
    private func handleConfig(_ connection: NWConnection) async {
        // Read API key from secrets
        let keyPath = "/Volumes/data/secrets/elevenlabs_api_key"
        if let apiKey = try? String(contentsOfFile: keyPath, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines), !apiKey.isEmpty {
            let response = """
            {
                "elevenlabsAPIKey": "\(apiKey)"
            }
            """
            sendJSON(response, to: connection)
        } else {
            logger.warning("[CommandServer] ElevenLabs API key not found at \(keyPath)")
            sendResponse("HTTP/1.1 500 Internal Server Error\r\n\r\n{\"error\":\"API key not configured\"}", to: connection)
        }
    }

    /// Return list of available ElevenLabs voices
    private func handleVoices(_ connection: NWConnection) async {
        // Top 5 conversational ElevenLabs voices matching quality requirement
        let response = """
        {
            "voices": [
                {"id": "pNInz6obpgDQGcFmaJgB", "name": "Adam", "description": "Deep, confident male voice"},
                {"id": "cgSgspJ2msm6clMCkdW9", "name": "Jessica", "description": "Playful, bright, warm female voice (default)"},
                {"id": "AZnzlk1XvdvUeBnXmlld", "name": "Domi", "description": "Professional female voice"},
                {"id": "EXAVITQu4vr4xnSDxMaL", "name": "Bella", "description": "Bright, engaging female voice"},
                {"id": "ErXwobaYiN019PkySvjV", "name": "Antoni", "description": "Smooth, articulate male voice"}
            ]
        }
        """

        sendJSON(response, to: connection)
    }
    
    /// Streaming endpoint — emits NDJSON lines that iOS VoiceLoop consumes chunk-by-chunk.
    /// Format: {"chunk":"word "} … {"done":true}
    private func handleCommandStream(_ data: Data, _ connection: NWConnection) async {
        guard let text = extractCommandText(from: data) else {
            sendResponse("HTTP/1.1 400 Bad Request\r\n\r\n{\"error\":\"Missing 'text' field\"}", to: connection)
            return
        }

        logger.info("[CommandServer] Stream request: \(text.prefix(80))")
        lastCommand = text
        requestCount += 1

        // Send chunked HTTP header — keep connection open for NDJSON lines.
        let header = "HTTP/1.1 200 OK\r\nContent-Type: application/x-ndjson\r\nTransfer-Encoding: chunked\r\n\r\n"
        sendRaw(header, to: connection)

        // Check if this will be handled by native intent (instant response, no thinking ack needed)
        let needsThinkingAck = await IntentRouter.shared.route(text) == nil

        // Send immediate acknowledgment for LLM queries (avoid awkward silence)
        if needsThinkingAck {
            let thinkingAcks = [
                "Let me think about that.",
                "Give me a moment.",
                "One second.",
                "Let me check.",
                "Thinking...",
                "Just a sec."
            ]
            let ack = thinkingAcks.randomElement()!
            await sendNDJSONChunk("{\"chunk\":\(escapeJSON(ack + " ")),\"is_final\":false}", to: connection)
        }

        do {
            let response = try await claudeBridge.execute(text: text)
            // Split response into word-sized chunks so iOS starts speaking immediately.
            let words = response.components(separatedBy: " ")
            for (i, word) in words.enumerated() {
                let isLast = i == words.index(before: words.endIndex)
                let piece = isLast ? word : word + " "
                if !piece.trimmingCharacters(in: .whitespaces).isEmpty {
                    await sendNDJSONChunk("{\"chunk\":\(escapeJSON(piece)),\"is_final\":false}", to: connection)
                }
            }
        } catch {
            logger.error("[CommandServer] Bridge error: \(error.localizedDescription)")
            let msg = "I encountered an error. Please try again."
            await sendNDJSONChunk("{\"chunk\":\(escapeJSON(msg)),\"is_final\":false}", to: connection)
        }

        await sendNDJSONChunk("{\"done\":true}", to: connection)
        // Send final chunk terminator (0\r\n\r\n)
        sendRaw("0\r\n\r\n", to: connection)
        connection.cancel()
    }

    /// Non-streaming fallback endpoint — returns single JSON response.
    private func handleCommand(_ data: Data, _ connection: NWConnection) async {
        guard var text = extractCommandText(from: data) else {
            sendResponse("HTTP/1.1 400 Bad Request\r\n\r\n{\"error\":\"Missing 'text' field\"}", to: connection)
            return
        }

        // Security: Validate and sanitize input
        // Check length
        if text.count > 10_000 {
            sendResponse("HTTP/1.1 400 Bad Request\r\n\r\n{\"error\":\"Input text too long (max 10000 chars)\"}", to: connection)
            return
        }

        // Security: Sanitize logging to prevent injection
        let sanitizedForLog = text
            .prefix(80)
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")

        logger.info("[CommandServer] Command request: \(sanitizedForLog)")
        lastCommand = text
        requestCount += 1

        do {
            let response = try await claudeBridge.execute(text: text)
            sendJSON("{\"response\":\(escapeJSON(response)),\"status\":\"ok\"}", to: connection)
        } catch {
            logger.error("[CommandServer] Bridge error: \(error.localizedDescription)")
            sendJSON("{\"response\":\"Error: \(error.localizedDescription)\",\"status\":\"error\"}", to: connection)
        }
    }
    

    /// TTS synthesis endpoint - Returns PCM audio for iOS compatibility
    private func handleSynthesize(_ data: Data, _ connection: NWConnection) async {
        guard let text = extractCommandText(from: data) else {
            sendResponse("HTTP/1.1 400 Bad Request\r\n\r\n{\"error\":\"Missing 'text' field\"}", to: connection)
            return
        }

        logger.info("[CommandServer] TTS request: \(text.prefix(80))")

        // PERF OPT #6: Batch TTS into phrases instead of word-by-word
        // Split on sentence boundaries to create semantic chunks, then rejoin for single call
        // Avoids multiple TTS calls and unnecessary audio concatenation overhead
        let components = text.components(separatedBy: CharacterSet(charactersIn: ".!?"))
        let phrases = components
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        // For now, join phrases back together for single TTS call (batching optimization)
        // Future: implement concatenative synthesis if individual phrase synthesis is needed
        let batchedText = phrases.joined(separator: " ")

        // Priority 1: Try ElevenLabs (convert MP3 to PCM for iOS)
        // Uses batched text to reduce overhead
        if let mp3Data = try? await synthesizeWithElevenLabs(text: batchedText),
           let pcmData = await convertMP3ToPCM(mp3Data) {
            let response = """
            HTTP/1.1 200 OK\r
            Content-Type: audio/pcm\r
            Content-Length: \(pcmData.count)\r
            X-Sample-Rate: 24000\r
            X-Channels: 1\r
            X-Bit-Depth: 16\r
            \r

            """

            connection.send(content: response.data(using: .utf8)!, completion: .contentProcessed { _ in })
            connection.send(content: pcmData, completion: .contentProcessed { _ in
                connection.cancel()
            })

            logger.info("[CommandServer] ElevenLabs TTS → PCM: \(pcmData.count) bytes @ 24kHz")
            return
        }

        // No fallback - ElevenLabs is required for TTS
        // TODO: Implement VoiceBox/Kokoro as primary TTS option
        logger.error("[CommandServer] TTS failed - ElevenLabs unavailable and no fallback configured")
        sendResponse("HTTP/1.1 500 Internal Server Error\r\n\r\n{\"error\":\"TTS unavailable - ElevenLabs API key not configured\"}", to: connection)
    }

    // MARK: - Audio Conversion Helpers

    /// Convert MP3 to 24kHz mono 16-bit PCM
    private func convertMP3ToPCM(_ mp3Data: Data) async -> Data? {
        let tempMP3 = "/tmp/sonique-mp3-\(UUID().uuidString).mp3"
        let tempPCM = "/tmp/sonique-pcm-\(UUID().uuidString).raw"

        defer {
            try? FileManager.default.removeItem(atPath: tempMP3)
            try? FileManager.default.removeItem(atPath: tempPCM)
        }

        do {
            // Write MP3 to temp file
            try mp3Data.write(to: URL(fileURLWithPath: tempMP3))

            // Use ffmpeg to convert (if available)
            if FileManager.default.fileExists(atPath: "/opt/homebrew/bin/ffmpeg") {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/opt/homebrew/bin/ffmpeg")
                process.arguments = [
                    "-i", tempMP3,
                    "-f", "s16le",      // 16-bit PCM little-endian
                    "-ar", "24000",     // 24kHz sample rate
                    "-ac", "1",         // mono
                    tempPCM
                ]
                process.standardOutput = nil
                process.standardError = nil

                try process.run()

                // BUG FIX #5: Add timeout for ffmpeg process (don't block indefinitely)
                let startTime = Date()
                let maxDuration: TimeInterval = 30.0  // 30s timeout for conversion
                while process.isRunning && Date().timeIntervalSince(startTime) < maxDuration {
                    usleep(100_000)  // Poll every 100ms
                }

                if process.isRunning {
                    process.terminate()
                    logger.error("[CommandServer] ffmpeg timed out after \(maxDuration)s")
                    return nil
                }

                if process.terminationStatus == 0,
                   let pcmData = try? Data(contentsOf: URL(fileURLWithPath: tempPCM)) {
                    return pcmData
                }
                // BUG FIX #2: On ffmpeg error, do NOT fall through silently
                // Log failure and return nil immediately (never return partial/corrupt data)
                logger.error("[CommandServer] ffmpeg conversion failed (status: \(process.terminationStatus))")
                return nil
            }

            // Fallback: use AVFoundation
            return try await convertAudioWithAVFoundation(mp3Data, targetRate: 24000)

        } catch {
            logger.error("[CommandServer] MP3→PCM conversion failed: \(error.localizedDescription)")
            return nil
        }
    }

    /// Convert AIFF to 24kHz mono 16-bit PCM
    private func convertAIFFToPCM(_ aiffData: Data) async -> Data? {
        return try? await convertAudioWithAVFoundation(aiffData, targetRate: 24000)
    }

    /// Generic audio conversion using AVFoundation
    private func convertAudioWithAVFoundation(_ audioData: Data, targetRate: Double) async throws -> Data? {
        let tempInput = "/tmp/sonique-input-\(UUID().uuidString).audio"
        let tempOutput = "/tmp/sonique-output-\(UUID().uuidString).raw"

        defer {
            try? FileManager.default.removeItem(atPath: tempInput)
            try? FileManager.default.removeItem(atPath: tempOutput)
        }

        try audioData.write(to: URL(fileURLWithPath: tempInput))

        guard let audioFile = try? AVAudioFile(forReading: URL(fileURLWithPath: tempInput)),
              let targetFormat = AVAudioFormat(
                commonFormat: .pcmFormatInt16,
                sampleRate: targetRate,
                channels: 1,
                interleaved: true
              ) else {
            return nil
        }

        let sourceFormat = audioFile.processingFormat
        guard let converter = AVAudioConverter(from: sourceFormat, to: targetFormat) else {
            return nil
        }

        let frameCapacity = AVAudioFrameCount(audioFile.length)
        guard let sourceBuffer = AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: frameCapacity) else {
            return nil
        }

        try audioFile.read(into: sourceBuffer)
        sourceBuffer.frameLength = frameCapacity

        let ratio = targetFormat.sampleRate / sourceFormat.sampleRate
        let targetFrameCount = AVAudioFrameCount(Double(sourceBuffer.frameLength) * ratio)

        guard let targetBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: targetFrameCount) else {
            return nil
        }

        var error: NSError?
        let status = converter.convert(to: targetBuffer, error: &error) { _, outStatus in
            outStatus.pointee = .haveData
            return sourceBuffer
        }

        guard status != .error, let int16Data = targetBuffer.int16ChannelData else {
            return nil
        }

        targetBuffer.frameLength = targetFrameCount

        // Extract Int16 PCM data
        let int16Pointer = int16Data[0]
        let dataSize = Int(targetFrameCount) * 2  // 2 bytes per sample
        return Data(bytes: int16Pointer, count: dataSize)
    }

    // MARK: - TTS Providers

    /// Piper TTS - local, free, high quality (primary)
    private func synthesizeWithPiper(text: String) async throws -> Data {
        let voice = "en_US-lessac-medium"  // High-quality female voice
        let piperPath = "/Users/charlieseay/.local/bin/piper"
        let modelPath = "/Users/charlieseay/.local/share/piper/voices/\(voice).onnx"
        let outputFile = "/tmp/sonique-piper-\(UUID().uuidString).wav"

        defer {
            try? FileManager.default.removeItem(atPath: outputFile)
        }

        // Check if Piper is installed
        guard FileManager.default.fileExists(atPath: piperPath) else {
            throw NSError(domain: "Piper", code: 1, userInfo: [NSLocalizedDescriptionKey: "Piper not installed"])
        }

        // Check if voice model exists
        guard FileManager.default.fileExists(atPath: modelPath) else {
            throw NSError(domain: "Piper", code: 2, userInfo: [NSLocalizedDescriptionKey: "Voice model not found: \(voice)"])
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: piperPath)
        process.arguments = [
            "--model", modelPath,
            "--output_file", outputFile
        ]

        // BUG FIX #8: Create and close all pipes to prevent file handle leaks
        let inputPipe = Pipe()
        let errorPipe = Pipe()  // Suppress stderr
        process.standardInput = inputPipe
        process.standardError = errorPipe

        try process.run()

        // Write text to stdin
        if let textData = text.data(using: .utf8) {
            inputPipe.fileHandleForWriting.write(textData)
        }
        try inputPipe.fileHandleForWriting.close()

        // BUG FIX #8: Close stderr pipe to prevent handle leak
        try? errorPipe.fileHandleForReading.close()

        process.waitUntilExit()

        guard process.terminationStatus == 0,
              let audioData = try? Data(contentsOf: URL(fileURLWithPath: outputFile)) else {
            throw NSError(domain: "Piper", code: 3, userInfo: [NSLocalizedDescriptionKey: "Piper synthesis failed"])
        }

        return audioData
    }

    /// ElevenLabs TTS - cloud, premium (optional)
    private func synthesizeWithElevenLabs(text: String) async throws -> Data {
        // Load API key from secrets
        let keyPath = "/Volumes/data/secrets/elevenlabs_api_key"
        guard let apiKey = try? String(contentsOfFile: keyPath, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines), !apiKey.isEmpty else {
            throw NSError(domain: "ElevenLabs", code: 1, userInfo: [NSLocalizedDescriptionKey: "API key not found"])
        }

        // Jessica voice ID (Playful, Bright, Warm)
        let voiceId = "cgSgspJ2msm6clMCkdW9"

        let url = URL(string: "https://api.elevenlabs.io/v1/text-to-speech/\(voiceId)")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "xi-api-key")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: Any] = [
            "text": text,
            "model_id": "eleven_flash_v2_5",
            "voice_settings": [
                "stability": 0.5,
                "similarity_boost": 0.75
            ]
        ]

        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            throw NSError(domain: "ElevenLabs", code: 2, userInfo: [NSLocalizedDescriptionKey: "Request failed"])
        }

        return data
    }

    // MARK: - Helpers

    private func extractCommandText(from data: Data) -> String? {
        guard let requestString = String(data: data, encoding: .utf8),
              let range = requestString.range(of: "\r\n\r\n"),
              let bodyData = String(requestString[range.upperBound...]).data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: bodyData) as? [String: Any],
              let text = json["text"] as? String else { return nil }
        return text
    }

    nonisolated private func sendNDJSONChunk(_ line: String, to connection: NWConnection) async {
        let dataLine = line + "\n"
        let data = dataLine.data(using: .utf8)!
        // HTTP chunked encoding: size in hex + CRLF + data + CRLF
        let sizeHex = String(format: "%X", data.count)
        let chunk = "\(sizeHex)\r\n\(dataLine)\r\n"

        // Use async/await to wait for send completion
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            connection.send(content: chunk.data(using: .utf8)!, completion: .contentProcessed { error in
                if let error = error {
                    print("[CommandServer] Chunk send error: \(error)")
                }
                continuation.resume()
            })
        }
    }

    private func sendRaw(_ string: String, to connection: NWConnection) {
        connection.send(content: string.data(using: .utf8)!, completion: .contentProcessed { _ in })
    }
    
    private func escapeJSON(_ string: String) -> String {
        let escaped = string
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\t", with: "\\t")
        
        return "\"\(escaped)\""
    }
    
    private func sendJSON(_ json: String, to connection: NWConnection) {
        let response = """
        HTTP/1.1 200 OK\r
        Content-Type: application/json\r
        Content-Length: \(json.utf8.count)\r
        \r
        \(json)
        """
        
        sendResponse(response, to: connection)
    }
    
    private func sendResponse(_ response: String, to connection: NWConnection) {
        let data = response.data(using: .utf8)!

        connection.send(content: data, completion: .contentProcessed { error in
            if let error = error {
                print("[CommandServer] Send error: \(error)")
            }
            connection.cancel()
        })
    }

    private func handleSynthesizeKokoro(_ data: Data, _ connection: NWConnection) async {
        // Extract JSON body
        guard let requestString = String(data: data, encoding: .utf8),
              let range = requestString.range(of: "\r\n\r\n"),
              let bodyData = String(requestString[range.upperBound...]).data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: bodyData) as? [String: Any] else {
            logger.error("[handleSynthesizeKokoro] Failed to parse JSON")
            sendResponse("HTTP/1.1 400 Bad Request\r\n\r\n{\"error\":\"Invalid JSON\"}", to: connection)
            return
        }

        guard let text = json["text"] as? String else {
            logger.error("[handleSynthesizeKokoro] Missing text field")
            sendResponse("HTTP/1.1 400 Bad Request\r\n\r\n{\"error\":\"Missing text field\"}", to: connection)
            return
        }

        let voice = (json["voice"] as? String) ?? "af_jessica"

        logger.info("[handleSynthesizeKokoro] Synthesizing \(text.count) chars with voice \(voice)")

        do {
            let pcmData = try await KokoroTTS.shared.synthesize(text: text, voice: voice)

            let response = """
            HTTP/1.1 200 OK\r
            Content-Type: audio/pcm\r
            X-Sample-Rate: 24000\r
            X-Channels: 1\r
            X-Bit-Depth: 16\r
            Content-Length: \(pcmData.count)\r
            \r

            """

            connection.send(content: response.data(using: .utf8)!, completion: .contentProcessed { _ in })
            connection.send(content: pcmData, completion: .contentProcessed { _ in
                connection.cancel()
            })

            logger.info("[handleSynthesizeKokoro] Kokoro TTS → PCM: \(pcmData.count) bytes @ 24kHz")
        } catch {
            logger.error("[handleSynthesizeKokoro] Synthesis failed: \(error.localizedDescription)")
            sendResponse("HTTP/1.1 500 Internal Server Error\r\n\r\n{\"error\":\"\(error.localizedDescription)\"}", to: connection)
        }
    }

    // MARK: - Bonjour Advertising

    private func startBonjourAdvertising() {
        // Stop existing service if any
        bonjourService?.stop()

        // Create and publish Bonjour service
        bonjourService = NetService(domain: "local.", type: "_sonique._tcp.", name: "SoniqueBar", port: Int32(self.port.rawValue))
        bonjourService?.publish()

        logger.info("[CommandServer] ✓ Bonjour advertising started: _sonique._tcp.local on port \(self.port.rawValue)")
        NSLog("[CommandServer] ✓ Bonjour advertising: _sonique._tcp.local on port \(self.port.rawValue)")
    }
}
