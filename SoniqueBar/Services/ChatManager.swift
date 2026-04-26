import Foundation

/// Manages the text chat connection to the CAAL backend.
///
/// Uses the streaming SSE endpoint (POST /api/chat/stream) for real-time
/// token delivery and loads conversation history from /api/chat/history.
///
/// Session ID is always PERSISTENT_SESSION_ID ("sonique-main") — one
/// continuous conversation that persists across restarts on both sides.
@MainActor
class ChatManager: ObservableObject {
    @Published var messages: [ChatMessage] = []
    @Published var isStreaming = false
    @Published var streamingContent = ""
    @Published var error: String?

    private let sessionId = "sonique-main"
    private var backendURL: String = "http://localhost:8889"
    private var apiKey: String = ""
    private var streamTask: Task<Void, Never>?

    func configure(backendURL: String, apiKey: String) {
        self.backendURL = backendURL
        self.apiKey = apiKey
    }

    // MARK: - History

    func loadHistory() async {
        guard let url = URL(string: "\(backendURL)/api/chat/history?session_id=\(sessionId)") else { return }
        var req = URLRequest(url: url, timeoutInterval: 8)
        if !apiKey.isEmpty { req.setValue(apiKey, forHTTPHeaderField: "x-api-key") }
        guard let (data, _) = try? await URLSession.shared.data(for: req),
              let payload = try? JSONDecoder().decode(HistoryPayload.self, from: data)
        else { return }

        let loaded = payload.messages.compactMap { raw -> ChatMessage? in
            guard let roleStr = raw["role"], let content = raw["content"],
                  let role = ChatRole(rawValue: roleStr), role != .system
            else { return nil }
            return ChatMessage(role: role, content: content)
        }
        if !loaded.isEmpty {
            messages = loaded
        }
    }

    // MARK: - Send

    func send(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isStreaming else { return }

        messages.append(ChatMessage(role: .user, content: trimmed))
        streamingContent = ""
        isStreaming = true
        error = nil

        streamTask = Task { [weak self] in
            await self?.stream(text: trimmed)
        }
    }

    func cancelStream() {
        streamTask?.cancel()
        streamTask = nil
        if !streamingContent.isEmpty {
            messages.append(ChatMessage(role: .assistant, content: streamingContent))
        }
        streamingContent = ""
        isStreaming = false
    }

    // MARK: - SSE Stream

    private func stream(text: String) async {
        defer {
            if !streamingContent.isEmpty {
                messages.append(ChatMessage(role: .assistant, content: streamingContent))
                streamingContent = ""
            }
            isStreaming = false
        }

        guard let url = URL(string: "\(backendURL)/api/chat/stream") else { return }
        let body = try? JSONSerialization.data(withJSONObject: [
            "text": text,
            "session_id": sessionId,
        ])
        var req = URLRequest(url: url, timeoutInterval: 120)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        if !apiKey.isEmpty { req.setValue(apiKey, forHTTPHeaderField: "x-api-key") }
        req.httpBody = body

        do {
            let (bytes, _) = try await URLSession.shared.bytes(for: req)
            for try await line in bytes.lines {
                if Task.isCancelled { break }
                guard line.hasPrefix("data: ") else { continue }
                let payload = String(line.dropFirst(6))
                if payload == "[DONE]" { break }
                if let data = payload.data(using: .utf8),
                   let event = try? JSONDecoder().decode(SSEChunk.self, from: data) {
                    if let chunk = event.text {
                        streamingContent += chunk
                    }
                }
            }
        } catch {
            if !Task.isCancelled {
                self.error = error.localizedDescription
            }
        }
    }

    // MARK: - Models

    private struct HistoryPayload: Decodable {
        let sessionId: String
        let messages: [[String: String]]
        enum CodingKeys: String, CodingKey {
            case sessionId = "session_id"
            case messages
        }
    }

    private struct SSEChunk: Decodable {
        let text: String?
        let error: String?
    }
}
