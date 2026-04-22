import Foundation

class MacSettings: ObservableObject {
    @Published var serverURL: String {
        didSet { UserDefaults.standard.set(serverURL, forKey: "serverURL") }
    }
    @Published var apiKey: String {
        didSet { UserDefaults.standard.set(apiKey, forKey: "apiKey") }
    }

    init() {
        self.serverURL = UserDefaults.standard.string(forKey: "serverURL") ?? ""
        self.apiKey = UserDefaults.standard.string(forKey: "apiKey") ?? ""
    }

    var isConfigured: Bool { !serverURL.trimmingCharacters(in: .whitespaces).isEmpty }

    var normalizedURL: String {
        serverURL.hasSuffix("/") ? String(serverURL.dropLast()) : serverURL
    }
}
