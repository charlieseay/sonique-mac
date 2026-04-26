import Foundation
import AppKit

/// Polls the CAAL backend for pending Mac actions queued by the voice/chat agent
/// and executes them locally via NSWorkspace and NSAppleScript.
///
/// All execution is strictly local — actions are dispatched by Cael through the
/// CAAL webhook server (port 8889) and never exposed to the network.
@MainActor
class SystemControlManager: ObservableObject {
    @Published var isExecuting = false
    @Published var lastActionDescription: String = ""

    private var pollTask: Task<Void, Never>?
    private var backendURL: String = "http://localhost:8889"
    private var apiKey: String = ""

    func start(backendURL: String, apiKey: String) {
        self.backendURL = backendURL
        self.apiKey = apiKey
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.poll()
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    func stop() {
        pollTask?.cancel()
        pollTask = nil
    }

    // MARK: - Polling

    private func poll() async {
        guard let url = URL(string: "\(backendURL)/api/mac-actions/pending") else { return }
        var req = URLRequest(url: url, timeoutInterval: 4)
        if !apiKey.isEmpty { req.setValue(apiKey, forHTTPHeaderField: "x-api-key") }
        guard let (data, _) = try? await URLSession.shared.data(for: req),
              let actions = try? JSONDecoder().decode([MacAction].self, from: data),
              !actions.isEmpty
        else { return }

        for action in actions {
            await execute(action)
        }
    }

    // MARK: - Execution

    private func execute(_ action: MacAction) async {
        isExecuting = true
        lastActionDescription = action.displayDescription
        defer { isExecuting = false }

        var result: String?
        var error: String?

        switch action.actionType {
        case "open_url":
            if let rawURL = action.params["url"]?.value as? String,
               let url = URL(string: rawURL) {
                NSWorkspace.shared.open(url)
                result = "Opened \(rawURL)"
            } else {
                error = "Missing or invalid url param"
            }

        case "open_app":
            if let appName = action.params["app"]?.value as? String {
                let opened = NSWorkspace.shared.launchApplication(appName)
                result = opened ? "Launched \(appName)" : nil
                if !opened { error = "Could not launch \(appName)" }
            } else {
                error = "Missing app param"
            }

        case "run_applescript":
            if let script = action.params["script"]?.value as? String {
                (result, error) = runAppleScript(script)
            } else {
                error = "Missing script param"
            }

        case "shell_command":
            if let command = action.params["command"]?.value as? String {
                let escaped = command.replacingOccurrences(of: "\\", with: "\\\\")
                                     .replacingOccurrences(of: "\"", with: "\\\"")
                let script = "do shell script \"\(escaped)\""
                (result, error) = runAppleScript(script)
            } else {
                error = "Missing command param"
            }

        case "key_press":
            if let keys = action.params["keys"]?.value as? String {
                let script = buildKeystrokeScript(keys)
                (result, error) = runAppleScript(script)
            } else {
                error = "Missing keys param"
            }

        default:
            error = "Unknown action type: \(action.actionType)"
        }

        await postCompletion(actionId: action.id, result: result, error: error)
    }

    // MARK: - AppleScript

    private func runAppleScript(_ source: String) -> (String?, String?) {
        var errorDict: NSDictionary?
        let script = NSAppleScript(source: source)
        let output = script?.executeAndReturnError(&errorDict)
        if let errDict = errorDict,
           let message = errDict[NSAppleScript.errorMessage] as? String {
            return (nil, message)
        }
        return (output?.stringValue ?? "ok", nil)
    }

    private func buildKeystrokeScript(_ keys: String) -> String {
        // Parse "cmd+shift+n" → keystroke "n" using {command down, shift down}
        let parts = keys.lowercased().split(separator: "+").map(String.init)
        guard let key = parts.last else { return "" }
        let modifiers = parts.dropLast()
        var using: [String] = []
        if modifiers.contains("cmd") || modifiers.contains("command") { using.append("command down") }
        if modifiers.contains("shift") { using.append("shift down") }
        if modifiers.contains("option") || modifiers.contains("opt") { using.append("option down") }
        if modifiers.contains("ctrl") || modifiers.contains("control") { using.append("control down") }
        let usingClause = using.isEmpty ? "" : " using {\(using.joined(separator: ", "))}"
        return "tell application \"System Events\" to keystroke \"\(key)\"\(usingClause)"
    }

    // MARK: - Completion

    private func postCompletion(actionId: String, result: String?, error: String?) async {
        guard let url = URL(string: "\(backendURL)/api/mac-actions/\(actionId)/complete") else { return }
        var body: [String: String] = [:]
        if let r = result { body["result"] = r }
        if let e = error  { body["error"]  = e }
        guard let bodyData = try? JSONSerialization.data(withJSONObject: body) else { return }
        var req = URLRequest(url: url, timeoutInterval: 5)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !apiKey.isEmpty { req.setValue(apiKey, forHTTPHeaderField: "x-api-key") }
        req.httpBody = bodyData
        _ = try? await URLSession.shared.data(for: req)
    }
}

// MARK: - Model

private struct MacAction: Decodable {
    let id: String
    let actionType: String
    let params: [String: AnyCodable]
    let source: String
    let status: String
    let queuedAt: Double

    enum CodingKeys: String, CodingKey {
        case id, params, source, status
        case actionType = "action_type"
        case queuedAt = "queued_at"
    }

    var displayDescription: String {
        switch actionType {
        case "open_url":        return "Opening \(params["url"]?.stringValue ?? "URL")..."
        case "open_app":        return "Launching \(params["app"]?.stringValue ?? "app")..."
        case "shell_command":   return "Running command..."
        case "run_applescript": return "Running AppleScript..."
        case "key_press":       return "Sending \(params["keys"]?.stringValue ?? "keys")..."
        default:                return "Executing \(actionType)..."
        }
    }
}

// Minimal type-erased Codable wrapper for heterogeneous JSON param values.
private struct AnyCodable: Decodable {
    let value: Any

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let s = try? container.decode(String.self)  { value = s; return }
        if let i = try? container.decode(Int.self)     { value = i; return }
        if let d = try? container.decode(Double.self)  { value = d; return }
        if let b = try? container.decode(Bool.self)    { value = b; return }
        value = ""
    }

    var stringValue: String { value as? String ?? "\(value)" }
}
