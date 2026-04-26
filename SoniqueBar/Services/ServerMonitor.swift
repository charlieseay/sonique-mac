import Foundation
import AppKit

@MainActor
class ServerMonitor: ObservableObject {
    @Published var isOnline = false
    @Published var profile: AssistantProfile?
    @Published var avatarImage: NSImage?
    @Published var hasActiveVoiceSession = false

    let settings = MacSettings()
    let containerManager = ContainerManager()
    let sidecarManager = SidecarManager()
    let premium = PremiumManager()
    let systemControl = SystemControlManager()
    let chatManager = ChatManager()

    private var pollTask: Task<Void, Never>?

    init() {
        Task { [weak self] in
            guard let self else { return }
            switch settings.deploymentMode {
            case .networked:
                await containerManager.setup(caelDirectory: settings.caelDirectory)
            case .embedded:
                await sidecarManager.start()
            }
            startPolling()
        }
    }

    /// Apply a deployment-mode change at runtime: tear down the supervisor
    /// that's currently driving CAAL and bring up the other. Called from the
    /// Settings UI when the user flips the toggle.
    func applyDeploymentMode(_ mode: SidecarManager.DeploymentMode) async {
        settings.deploymentMode = mode
        switch mode {
        case .networked:
            sidecarManager.stop()
            await containerManager.setup(caelDirectory: settings.caelDirectory)
        case .embedded:
            // Leave networked stack running — user may have other tools
            // pointed at it. Just bring up the sidecar instead.
            await sidecarManager.start()
        }
    }

    func startPolling() {
        pollTask?.cancel()
        chatManager.configure(backendURL: settings.backendURL, apiKey: settings.apiKey)
        systemControl.start(backendURL: settings.backendURL, apiKey: settings.apiKey)
        pollTask = Task {
            while !Task.isCancelled {
                await refresh()
                try? await Task.sleep(for: .seconds(30))
            }
        }
    }

    func refresh() async {
        guard settings.isConfigured else { return }
        await checkHealth()
        await fetchProfile()
    }

    private var timezoneSynced = false

    private func checkHealth() async {
        guard let url = URL(string: "\(settings.effectiveURL)/api/settings") else {
            isOnline = false; return
        }
        var req = URLRequest(url: url, timeoutInterval: 5)
        if !settings.apiKey.isEmpty { req.setValue(settings.apiKey, forHTTPHeaderField: "x-api-key") }
        do {
            let (_, response) = try await URLSession.shared.data(for: req)
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            let wasOffline = !isOnline
            isOnline = code == 200 || code == 401
            if isOnline && (wasOffline || !timezoneSynced) {
                await syncTimezone()
            }
        } catch { isOnline = false }

        await checkActiveSession()
    }

    private func checkActiveSession() async {
        guard isOnline,
              let url = URL(string: "\(settings.backendURL)/api/chat/sessions")
        else { hasActiveVoiceSession = false; return }
        var req = URLRequest(url: url, timeoutInterval: 3)
        if !settings.apiKey.isEmpty { req.setValue(settings.apiKey, forHTTPHeaderField: "x-api-key") }
        guard let (data, _) = try? await URLSession.shared.data(for: req),
              let payload = try? JSONDecoder().decode(SessionsPayload.self, from: data)
        else { hasActiveVoiceSession = false; return }
        hasActiveVoiceSession = !payload.sessions.isEmpty
    }

    /// Detect the local Tailscale IP (if Tailscale is installed and connected).
    func detectTailscaleIP() async -> String? {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        task.arguments = ["tailscale", "ip", "-4"]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = Pipe()
        try? task.run()
        task.waitUntilExit()
        let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard task.terminationStatus == 0, !output.isEmpty else { return nil }
        return output
    }

    private struct SessionsPayload: Decodable {
        let sessions: [SessionInfo]
        struct SessionInfo: Decodable {
            let sessionId: String
            enum CodingKeys: String, CodingKey { case sessionId = "session_id" }
        }
    }

    /// Posts the macOS system timezone to CAAL so the agent uses the correct local time.
    private func syncTimezone() async {
        guard let url = URL(string: "\(settings.effectiveURL)/api/settings") else { return }
        let (tzId, tzDisplay) = ContainerManager.systemTimezone()
        guard let body = try? JSONSerialization.data(withJSONObject: [
            "settings": ["timezone_id": tzId, "timezone_display": tzDisplay]
        ]) else { return }
        var req = URLRequest(url: url, timeoutInterval: 5)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !settings.apiKey.isEmpty { req.setValue(settings.apiKey, forHTTPHeaderField: "x-api-key") }
        req.httpBody = body
        _ = try? await URLSession.shared.data(for: req)
        timezoneSynced = true
    }

    private func fetchProfile() async {
        guard let url = URL(string: "\(settings.effectiveURL)/api/assistant/profile") else { return }
        var req = URLRequest(url: url, timeoutInterval: 5)
        if !settings.apiKey.isEmpty { req.setValue(settings.apiKey, forHTTPHeaderField: "x-api-key") }
        do {
            let (data, _) = try await URLSession.shared.data(for: req)
            let p = try JSONDecoder().decode(AssistantProfile.self, from: data)
            if p != profile { profile = p }
            if let avatarPath = p.avatarUrl,
               let avatarURL = URL(string: "\(settings.effectiveURL)\(avatarPath)") {
                await fetchAvatar(from: avatarURL)
            }
        } catch {}
    }

    private func fetchAvatar(from url: URL) async {
        var req = URLRequest(url: url, timeoutInterval: 5)
        if !settings.apiKey.isEmpty { req.setValue(settings.apiKey, forHTTPHeaderField: "x-api-key") }
        do {
            let (data, _) = try await URLSession.shared.data(for: req)
            if let img = NSImage(data: data) { avatarImage = img }
        } catch {}
    }
}
