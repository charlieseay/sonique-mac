import Foundation

class MacSettings: ObservableObject {
    @Published var serverURL: String {
        didSet { UserDefaults.standard.set(serverURL, forKey: "serverURL") }
    }
    @Published var apiKey: String {
        didSet { UserDefaults.standard.set(apiKey, forKey: "apiKey") }
    }
    @Published var externalURL: String {
        didSet { UserDefaults.standard.set(externalURL, forKey: "externalURL") }
    }

    init() {
        self.serverURL = UserDefaults.standard.string(forKey: "serverURL") ?? ""
        self.apiKey = UserDefaults.standard.string(forKey: "apiKey") ?? ""
        self.externalURL = UserDefaults.standard.string(forKey: "externalURL") ?? ""
    }

    var isConfigured: Bool { !serverURL.trimmingCharacters(in: .whitespaces).isEmpty }

    var normalizedURL: String {
        serverURL.hasSuffix("/") ? String(serverURL.dropLast()) : serverURL
    }

    var normalizedExternalURL: String {
        externalURL.hasSuffix("/") ? String(externalURL.dropLast()) : externalURL
    }
}
