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
    private var backendURL: String = "http://localhost:8891"
    private var apiKey: String = ""
    private var streamTask: Task<Void, Never>?
    private let localMemory = LocalMemoryStore.shared

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
            Task {
                await localMemory.bootstrapIfNeeded(from: loaded)
            }
        }
    }

    // MARK: - Send

    func send(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isStreaming else { return }

        messages.append(ChatMessage(role: .user, content: trimmed))
        Task { await localMemory.appendTurn(role: .user, content: trimmed) }
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
            let content = streamingContent
            Task { await localMemory.appendTurn(role: .assistant, content: content) }
        }
        streamingContent = ""
        isStreaming = false
    }

    // MARK: - SSE Stream

    private func stream(text: String) async {
        defer {
            if !streamingContent.isEmpty {
                messages.append(ChatMessage(role: .assistant, content: streamingContent))
                let content = streamingContent
                Task { await localMemory.appendTurn(role: .assistant, content: content) }
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

// MARK: - Local memory + persona state

private struct StoredTurn: Codable {
    let role: String
    let content: String
    let timestamp: Date
}

private struct MemoryEpisode: Codable {
    let id: String
    let summary: String
    let turnCount: Int
    let start: Date
    let end: Date
}

private struct PersonaProfile: Codable {
    var traits: [String: Double]
    var preferences: [String: String]
    var summary: String
    var updatedAt: Date

    static let empty = PersonaProfile(
        traits: [:],
        preferences: [:],
        summary: "No stable persona yet.",
        updatedAt: Date()
    )
}

actor LocalMemoryStore {
    static let shared = LocalMemoryStore()

    private let maxRawTurns = 240
    private let compressChunkSize = 120

    private let dirURL: URL
    private let turnsURL: URL
    private let episodesURL: URL
    private let personaURL: URL
    private let statusURL: URL

    init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        dirURL = appSupport.appendingPathComponent("SoniqueBar/memory", isDirectory: true)
        turnsURL = dirURL.appendingPathComponent("conversation-turns.json")
        episodesURL = dirURL.appendingPathComponent("conversation-episodes.json")
        personaURL = dirURL.appendingPathComponent("persona-profile.json")
        statusURL = dirURL.appendingPathComponent("memory-health.json")
    }

    func bootstrapIfNeeded(from history: [ChatMessage]) async {
        guard !history.isEmpty else { return }
        var turns = loadTurns()
        guard turns.isEmpty else { return }
        turns = history.map { StoredTurn(role: $0.role.rawValue, content: $0.content, timestamp: $0.timestamp) }
        save(turns: turns)
        await recomputePersona(from: turns)
    }

    func appendTurn(role: ChatRole, content: String) async {
        var turns = loadTurns()
        turns.append(StoredTurn(role: role.rawValue, content: content, timestamp: Date()))
        save(turns: turns)
        if role == .user {
            await updatePersona(fromUserText: content)
        }
        await compactIfNeeded()
    }

    func compactIfNeeded() async {
        var turns = loadTurns()
        guard turns.count > maxRawTurns else { return }

        let chunk = Array(turns.prefix(compressChunkSize))
        let remaining = Array(turns.dropFirst(compressChunkSize))
        let episode = MemoryEpisode(
            id: UUID().uuidString,
            summary: summarize(chunk: chunk),
            turnCount: chunk.count,
            start: chunk.first?.timestamp ?? Date(),
            end: chunk.last?.timestamp ?? Date()
        )

        var episodes = loadEpisodes()
        episodes.append(episode)
        if episodes.count > 200 {
            episodes = Array(episodes.suffix(200))
        }

        turns = remaining
        save(turns: turns)
        save(episodes: episodes)
        await recomputePersona(from: turns)
        await markJanitorHeartbeat(mode: "inprocess", compacted: true)
    }

    func markJanitorHeartbeat(mode: String, compacted: Bool = false) async {
        var status = load([String: String].self, from: statusURL, fallback: [:])
        status["mode"] = mode
        status["lastRunAt"] = ISO8601DateFormatter().string(from: Date())
        if compacted {
            status["lastCompactAt"] = status["lastRunAt"]
        }
        save(status, to: statusURL)
    }

    private func summarize(chunk: [StoredTurn]) -> String {
        let userLines = chunk.filter { $0.role == "user" }.map(\.content)
        let assistantLines = chunk.filter { $0.role == "assistant" }.map(\.content)
        let userSnippet = userLines.prefix(3).joined(separator: " | ").prefix(220)
        let assistantSnippet = assistantLines.prefix(2).joined(separator: " | ").prefix(180)
        return "Conversation archive: user discussed \(userLines.count) prompts. Sample user intents: \(userSnippet). Sample assistant responses: \(assistantSnippet)."
    }

    private func updatePersona(fromUserText text: String) async {
        var persona = loadPersona()
        let lowered = text.lowercased()

        if lowered.contains("i prefer") || lowered.contains("prefer ") {
            persona.traits["expresses_preferences", default: 0] += 1
        }
        if lowered.contains("i like") || lowered.contains("i love") {
            persona.traits["positive_affinity", default: 0] += 1
        }
        if lowered.contains("don't") || lowered.contains("do not") {
            persona.traits["explicit_constraints", default: 0] += 1
        }

        if let pref = extractPreference(from: text) {
            persona.preferences["last_stated_preference"] = pref
        }

        persona.summary = summarizePersona(persona)
        persona.updatedAt = Date()
        save(persona: persona)
    }

    private func recomputePersona(from turns: [StoredTurn]) async {
        var persona = loadPersona()
        let userTurns = turns.filter { $0.role == "user" }.suffix(120)
        persona.traits["recent_user_turns"] = Double(userTurns.count)
        persona.summary = summarizePersona(persona)
        persona.updatedAt = Date()
        save(persona: persona)
    }

    private func summarizePersona(_ persona: PersonaProfile) -> String {
        let topTraits = persona.traits
            .sorted { $0.value > $1.value }
            .prefix(3)
            .map { "\($0.key)=\(Int($0.value))" }
            .joined(separator: ", ")
        let pref = persona.preferences["last_stated_preference"] ?? "none captured"
        return "Evolving persona traits: \(topTraits.isEmpty ? "none" : topTraits). Latest preference signal: \(pref)."
    }

    private func extractPreference(from text: String) -> String? {
        let pattern = "(?i)i\\s+(?:prefer|like|love)\\s+([^\\.,;]{2,60})"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, range: range),
              let capture = Range(match.range(at: 1), in: text)
        else { return nil }
        return text[capture].trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func loadTurns() -> [StoredTurn] {
        load([StoredTurn].self, from: turnsURL, fallback: [])
    }

    private func loadEpisodes() -> [MemoryEpisode] {
        load([MemoryEpisode].self, from: episodesURL, fallback: [])
    }

    private func loadPersona() -> PersonaProfile {
        load(PersonaProfile.self, from: personaURL, fallback: .empty)
    }

    private func save(turns: [StoredTurn]) {
        save(turns, to: turnsURL)
    }

    private func save(episodes: [MemoryEpisode]) {
        save(episodes, to: episodesURL)
    }

    private func save(persona: PersonaProfile) {
        save(persona, to: personaURL)
    }

    private func load<T: Decodable>(_ type: T.Type, from url: URL, fallback: T) -> T {
        guard let data = try? Data(contentsOf: url)
        else { return fallback }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let decoded = try? decoder.decode(type, from: data) else { return fallback }
        return decoded
    }

    private func save<T: Encodable>(_ value: T, to url: URL) {
        try? FileManager.default.createDirectory(at: dirURL, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(value) else { return }
        try? data.write(to: url, options: .atomic)
    }
}

final class MemoryJanitorService {
    private var janitorTask: Task<Void, Never>?
    private var janitorProcess: Process?
    private let store = LocalMemoryStore.shared

    func start() {
        guard janitorTask == nil, janitorProcess == nil else { return }
        Task { await store.markJanitorHeartbeat(mode: "starting") }
        if startSubprocessJanitor() {
            return
        }
        // Fallback for environments where python isn't available.
        janitorTask = Task {
            while !Task.isCancelled {
                await store.compactIfNeeded()
                await store.markJanitorHeartbeat(mode: "inprocess")
                try? await Task.sleep(nanoseconds: 300_000_000_000) // 5 minutes
            }
        }
    }

    func stop() {
        janitorTask?.cancel()
        janitorTask = nil
        janitorProcess?.terminate()
        janitorProcess = nil
    }

    private func startSubprocessJanitor() -> Bool {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let memoryDir = appSupport.appendingPathComponent("SoniqueBar/memory", isDirectory: true)
        let scriptURL = memoryDir.appendingPathComponent("memory_janitor.py")
        try? FileManager.default.createDirectory(at: memoryDir, withIntermediateDirectories: true)
        guard writeJanitorScript(to: scriptURL) else { return false }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = [scriptURL.path, memoryDir.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.terminationHandler = { [weak self] _ in
            Task { @MainActor in
                self?.janitorProcess = nil
                if self?.janitorTask == nil {
                    self?.start()
                }
            }
        }
        do {
            try process.run()
            janitorProcess = process
            Task { await store.markJanitorHeartbeat(mode: "subprocess") }
            return true
        } catch {
            return false
        }
    }

    private func writeJanitorScript(to url: URL) -> Bool {
        let script = """
import json
import os
import sys
import time
from datetime import datetime, timezone

memory_dir = sys.argv[1] if len(sys.argv) > 1 else "."
turns_path = os.path.join(memory_dir, "conversation-turns.json")
episodes_path = os.path.join(memory_dir, "conversation-episodes.json")
persona_path = os.path.join(memory_dir, "persona-profile.json")
status_path = os.path.join(memory_dir, "memory-health.json")

MAX_RAW_TURNS = 240
COMPRESS_CHUNK_SIZE = 120
SLEEP_SECONDS = 300

def load_json(path, fallback):
    try:
        with open(path, "r", encoding="utf-8") as f:
            return json.load(f)
    except Exception:
        return fallback

def save_json(path, value):
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(value, f, indent=2, sort_keys=True)
    os.replace(tmp, path)

def mark_status(last_compact=None):
    payload = load_json(status_path, {})
    payload["mode"] = "subprocess"
    payload["lastRunAt"] = datetime.now(timezone.utc).isoformat()
    if last_compact is not None:
        payload["lastCompactAt"] = last_compact
    save_json(status_path, payload)

def compact_once():
    turns = load_json(turns_path, [])
    if not isinstance(turns, list):
        turns = []
    if len(turns) <= MAX_RAW_TURNS:
        mark_status()
        return

    chunk = turns[:COMPRESS_CHUNK_SIZE]
    remaining = turns[COMPRESS_CHUNK_SIZE:]
    user_lines = [t.get("content", "") for t in chunk if t.get("role") == "user"]
    assistant_lines = [t.get("content", "") for t in chunk if t.get("role") == "assistant"]
    user_snippet = " | ".join(user_lines[:3])[:220]
    assistant_snippet = " | ".join(assistant_lines[:2])[:180]
    episode = {
        "id": f"ep-{int(time.time()*1000)}",
        "summary": f"Conversation archive: user discussed {len(user_lines)} prompts. Sample user intents: {user_snippet}. Sample assistant responses: {assistant_snippet}.",
        "turnCount": len(chunk),
        "start": chunk[0].get("timestamp") if chunk else datetime.now(timezone.utc).isoformat(),
        "end": chunk[-1].get("timestamp") if chunk else datetime.now(timezone.utc).isoformat(),
    }
    episodes = load_json(episodes_path, [])
    if not isinstance(episodes, list):
        episodes = []
    episodes.append(episode)
    episodes = episodes[-200:]
    save_json(episodes_path, episodes)
    save_json(turns_path, remaining)

    persona = load_json(persona_path, {
        "traits": {},
        "preferences": {},
        "summary": "No stable persona yet.",
        "updatedAt": datetime.now(timezone.utc).isoformat(),
    })
    traits = persona.get("traits", {}) if isinstance(persona.get("traits"), dict) else {}
    recent_user_turns = sum(1 for t in remaining if t.get("role") == "user")
    traits["recent_user_turns"] = recent_user_turns
    persona["traits"] = traits
    top = sorted(traits.items(), key=lambda kv: kv[1], reverse=True)[:3]
    top_str = ", ".join([f"{k}={int(v)}" for k, v in top]) if top else "none"
    pref = (persona.get("preferences") or {}).get("last_stated_preference", "none captured")
    persona["summary"] = f"Evolving persona traits: {top_str}. Latest preference signal: {pref}."
    persona["updatedAt"] = datetime.now(timezone.utc).isoformat()
    save_json(persona_path, persona)
    mark_status(last_compact=datetime.now(timezone.utc).isoformat())

while True:
    try:
        compact_once()
    except Exception:
        pass
    time.sleep(SLEEP_SECONDS)
"""
        do {
            try script.write(to: url, atomically: true, encoding: .utf8)
            return true
        } catch {
            return false
        }
    }
}
