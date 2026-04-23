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
    @Published var managedMode: Bool {
        didSet { UserDefaults.standard.set(managedMode, forKey: "managedMode") }
    }
    @Published var caelDirectory: String {
        didSet { UserDefaults.standard.set(caelDirectory, forKey: "caelDirectory") }
    }

    init() {
        self.serverURL    = UserDefaults.standard.string(forKey: "serverURL")    ?? ""
        self.apiKey       = UserDefaults.standard.string(forKey: "apiKey")       ?? ""
        self.externalURL  = UserDefaults.standard.string(forKey: "externalURL")  ?? ""
        self.managedMode  = UserDefaults.standard.bool(forKey: "managedMode")
        self.caelDirectory = UserDefaults.standard.string(forKey: "caelDirectory") ?? "~/Projects/cael"
    }

    // True when we have enough info to connect — either managed (localhost) or manual URL set
    var isConfigured: Bool {
        managedMode || !serverURL.trimmingCharacters(in: .whitespaces).isEmpty
    }

    // URL to actually use — managed mode always hits localhost:3000
    var effectiveURL: String {
        managedMode ? "http://localhost:3000" : normalizedURL
    }

    var normalizedURL: String {
        serverURL.hasSuffix("/") ? String(serverURL.dropLast()) : serverURL
    }

    var normalizedExternalURL: String {
        externalURL.hasSuffix("/") ? String(externalURL.dropLast()) : externalURL
    }
}
