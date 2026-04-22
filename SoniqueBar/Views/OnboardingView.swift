import SwiftUI

struct OnboardingView: View {
    @EnvironmentObject var monitor: ServerMonitor
    @Environment(\.dismiss) private var dismiss
    @State private var urlDraft = ""
    @State private var keyDraft = ""
    @State private var showScanner = false
    @State private var scanned = false

    var body: some View {
        VStack(spacing: 20) {
            Text(monitor.settings.isConfigured ? "Settings" : "Connect to Base Station")
                .font(.headline)

            if showScanner {
                QRScannerView { value in
                    handleQR(value)
                }
                .frame(width: 220, height: 220)
                .cornerRadius(12)
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.separator, lineWidth: 1))

                Button("Enter manually") { showScanner = false }
                    .foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Server URL")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    TextField("http://192.168.0.x:3000", text: $urlDraft)
                        .textFieldStyle(.roundedBorder)

                    Text("API Key (optional)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.top, 4)
                    SecureField("Leave empty if not set", text: $keyDraft)
                        .textFieldStyle(.roundedBorder)
                }

                Button {
                    showScanner = true
                } label: {
                    Label("Scan iOS QR Code", systemImage: "qrcode.viewfinder")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }

            if !showScanner {
                HStack {
                    if monitor.settings.isConfigured {
                        Button("Cancel") { dismiss() }
                    }
                    Spacer()
                    Button("Connect") { save() }
                        .buttonStyle(.borderedProminent)
                        .disabled(urlDraft.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
        .padding(24)
        .frame(width: 300)
        .onAppear {
            urlDraft = monitor.settings.serverURL
            keyDraft = monitor.settings.apiKey
        }
    }

    private func handleQR(_ value: String) {
        guard let url = URL(string: value),
              url.scheme == "sonique",
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return }
        let params = components.queryItems ?? []
        if let u = params.first(where: { $0.name == "url" })?.value { urlDraft = u }
        if let k = params.first(where: { $0.name == "key" })?.value { keyDraft = k }
        showScanner = false
        save()
    }

    private func save() {
        monitor.settings.serverURL = urlDraft.trimmingCharacters(in: .whitespaces)
        monitor.settings.apiKey = keyDraft.trimmingCharacters(in: .whitespaces)
        monitor.startPolling()
        dismiss()
    }
}
