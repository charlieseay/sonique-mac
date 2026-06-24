import Foundation
import AppKit
import Vision

/// Screen capture and analysis using Claude Vision API
@MainActor
class ScreenAnalyzer: ObservableObject {
    static let shared = ScreenAnalyzer()

    @Published private(set) var lastScreenshot: URL?
    @Published private(set) var lastAnalysis: String?

    private let screenshotsDir: URL

    private init() {
        // Store screenshots in temp directory
        let tempDir = FileManager.default.temporaryDirectory
        screenshotsDir = tempDir.appendingPathComponent("quinn-screenshots", isDirectory: true)

        try? FileManager.default.createDirectory(at: screenshotsDir, withIntermediateDirectories: true)
    }

    // MARK: - Screen Capture

    /// Capture current screen
    func captureScreen() async throws -> URL {
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let filename = "screenshot-\(timestamp).png"
        let filepath = screenshotsDir.appendingPathComponent(filename)

        // Use screencapture command (faster and more reliable than CGImage)
        let result = await InfrastructureExecutor.shell(
            "screencapture -x -t png '\(filepath.path)'"
        )

        guard result.exitCode == 0, FileManager.default.fileExists(atPath: filepath.path) else {
            throw ScreenAnalyzerError.captureFailed
        }

        lastScreenshot = filepath
        return filepath
    }

    // MARK: - Vision Analysis

    /// Analyze screenshot using Claude Vision API
    func analyzeScreen(query: String? = nil) async throws -> String {
        // Capture screenshot
        let screenshot = try await captureScreen()

        // Convert to base64
        guard let imageData = try? Data(contentsOf: screenshot) else {
            throw ScreenAnalyzerError.imageReadFailed
        }

        let base64Image = imageData.base64EncodedString()

        // Call Claude Vision API
        let analysis = try await callClaudeVision(base64Image: base64Image, query: query)

        lastAnalysis = analysis
        return analysis
    }

    private func callClaudeVision(base64Image: String, query: String?) async throws -> String {
        // Use ask_claude with vision model
        let prompt = query ?? "What do you see on this screen? Describe the main elements and any notable issues or errors."

        // Create multimodal prompt
        let visionPrompt = """
        Analyze this screenshot and answer the following question:

        \(prompt)

        Provide a concise answer (1-2 sentences for simple queries, 3-4 for complex analysis).
        Focus on what's actionable or relevant to the user.
        """

        // Call ask_claude via shell (supports vision in newer versions)
        // For now, use ask_llm with vision-capable model
        let result = await InfrastructureExecutor.shell("""
            echo '\(visionPrompt)' | ask_claude --model sonnet --image '\(screenshotsDir.path)/\(lastScreenshot!.lastPathComponent)' 2>&1
            """)

        if result.exitCode == 0 && !result.stdout.isEmpty {
            return result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        // Fallback: Use Claude API directly via HTTP
        return try await callClaudeVisionAPI(base64Image: base64Image, prompt: visionPrompt)
    }

    private func callClaudeVisionAPI(base64Image: String, prompt: String) async throws -> String {
        // Get API key from ask_claude config
        let apiKey = try await getClaudeAPIKey()

        guard let url = URL(string: "https://api.anthropic.com/v1/messages") else {
            throw ScreenAnalyzerError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")

        let payload: [String: Any] = [
            "model": "claude-3-5-sonnet-20241022",
            "max_tokens": 1024,
            "messages": [
                [
                    "role": "user",
                    "content": [
                        [
                            "type": "image",
                            "source": [
                                "type": "base64",
                                "media_type": "image/png",
                                "data": base64Image
                            ]
                        ],
                        [
                            "type": "text",
                            "text": prompt
                        ]
                    ]
                ]
            ]
        ]

        request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        request.timeoutInterval = 30

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            throw ScreenAnalyzerError.apiError
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let content = json["content"] as? [[String: Any]],
              let firstContent = content.first,
              let text = firstContent["text"] as? String else {
            throw ScreenAnalyzerError.invalidResponse
        }

        return text
    }

    private func getClaudeAPIKey() async throws -> String {
        // Try to get from ask_claude config
        let result = await InfrastructureExecutor.shell(
            "grep ANTHROPIC_API_KEY ~/.config/ask_claude/config 2>/dev/null | cut -d= -f2"
        )

        if result.exitCode == 0 && !result.stdout.isEmpty {
            return result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        // Try environment variable
        if let envKey = ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"] {
            return envKey
        }

        throw ScreenAnalyzerError.noAPIKey
    }

    // MARK: - OCR (Text Extraction)

    /// Extract text from screenshot using Vision framework
    func extractText() async throws -> String {
        guard let screenshot = lastScreenshot else {
            throw ScreenAnalyzerError.noScreenshot
        }

        guard let image = NSImage(contentsOf: screenshot),
              let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            throw ScreenAnalyzerError.imageReadFailed
        }

        return try await withCheckedThrowingContinuation { continuation in
            let request = VNRecognizeTextRequest { request, error in
                if let error = error {
                    continuation.resume(throwing: error)
                    return
                }

                guard let observations = request.results as? [VNRecognizedTextObservation] else {
                    continuation.resume(returning: "")
                    return
                }

                let recognizedText = observations
                    .compactMap { $0.topCandidates(1).first?.string }
                    .joined(separator: "\n")

                continuation.resume(returning: recognizedText)
            }

            request.recognitionLevel = .accurate

            let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
            do {
                try handler.perform([request])
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }

    // MARK: - Cleanup

    /// Delete old screenshots (keep last 10)
    func cleanupOldScreenshots() {
        do {
            let files = try FileManager.default.contentsOfDirectory(
                at: screenshotsDir,
                includingPropertiesForKeys: [.creationDateKey],
                options: [.skipsHiddenFiles]
            )

            let sorted = try files.sorted { url1, url2 in
                let date1 = try url1.resourceValues(forKeys: [.creationDateKey]).creationDate ?? Date.distantPast
                let date2 = try url2.resourceValues(forKeys: [.creationDateKey]).creationDate ?? Date.distantPast
                return date1 > date2
            }

            // Keep newest 10, delete the rest
            for file in sorted.dropFirst(10) {
                try? FileManager.default.removeItem(at: file)
            }
        } catch {
            NSLog("[ScreenAnalyzer] Cleanup failed: \(error)")
        }
    }
}

enum ScreenAnalyzerError: Error {
    case captureFailed
    case imageReadFailed
    case invalidURL
    case noAPIKey
    case apiError
    case invalidResponse
    case noScreenshot
}
