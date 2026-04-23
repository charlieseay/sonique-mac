import Foundation
import AppKit

@MainActor
class ServerMonitor: ObservableObject {
    @Published var isOnline = false
    @Published var profile: AssistantProfile?
    @Published var avatarImage: NSImage?

    let settings = MacSettings()
    let containerManager = ContainerManager()
    let premium = PremiumManager()

    private var pollTask: Task<Void, Never>?

    init() {
        Task { [weak self] in
            guard let self else { return }
            await containerManager.setup(caelDirectory: settings.caelDirectory)
            startPolling()
        }
    }

    func startPolling() {
        pollTask?.cancel()
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
            // Sync timezone once per session when CAAL first comes online
            if isOnline && (wasOffline || !timezoneSynced) {
                await syncTimezone()
            }
        } catch { isOnline = false }
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
