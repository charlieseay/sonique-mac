import Foundation

class MacSettings: ObservableObject {
    @Published var apiKey: String {
        didSet { UserDefaults.standard.set(apiKey, forKey: "apiKey") }
    }
    @Published var externalURL: String {
        didSet { UserDefaults.standard.set(externalURL, forKey: "externalURL") }
    }
    @Published var caelDirectory: String {
        didSet { UserDefaults.standard.set(caelDirectory, forKey: "caelDirectory") }
    }

    init() {
        self.apiKey        = UserDefaults.standard.string(forKey: "apiKey")        ?? ""
        self.externalURL   = UserDefaults.standard.string(forKey: "externalURL")   ?? ""
        self.caelDirectory = UserDefaults.standard.string(forKey: "caelDirectory") ?? "~/Projects/cael"
    }

    // Always manages local CAAL — configured as soon as the directory is set
    var isConfigured: Bool {
        !caelDirectory.trimmingCharacters(in: .whitespaces).isEmpty
    }

    // Always localhost:3100 — CAAL frontend port (3000 avoided to not conflict with other local services)
    var effectiveURL: String { "http://localhost:3100" }

    var normalizedExternalURL: String {
        externalURL.hasSuffix("/") ? String(externalURL.dropLast()) : externalURL
    }
}
