import SwiftUI
import AppKit
import WebKit

/// Browser-based auth flow: open Safari, then import cookies
struct BrowserAuthFlow: View {
    let provider: LLMProvider
    @Binding var isPresented: Bool
    let onSuccess: ([HTTPCookie]) -> Void

    @State private var step: AuthStep = .instructions
    @State private var isImporting = false
    @State private var errorMessage: String?

    enum AuthStep {
        case instructions
        case importing
        case success
        case error
    }

    var body: some View {
        VStack(spacing: 30) {
            Spacer()

            switch step {
            case .instructions:
                instructionsView
            case .importing:
                importingView
            case .success:
                successView
            case .error:
                errorView
            }

            Spacer()

            bottomButtons
        }
        .frame(width: 600, height: 500)
        .onAppear {
            // Open Safari immediately
            NSWorkspace.shared.open(provider.authURL)
        }
    }

    private var instructionsView: some View {
        VStack(spacing: 16) {
            Image(systemName: "safari")
                .font(.system(size: 50))
                .foregroundColor(.blue)

            Text("Sign In via Browser")
                .font(.title2)
                .bold()

            Text("Safari has opened to \(provider.displayName)")
                .font(.callout)
                .foregroundColor(.secondary)

            VStack(alignment: .leading, spacing: 10) {
                InstructionRow(number: "1", text: "Sign in to your \(provider.displayName) account in Safari")
                InstructionRow(number: "2", text: "Complete any 2FA or verification steps")
                InstructionRow(number: "3", text: "Once you're signed in, click \"I'm Signed In\" below")
            }
            .padding(.horizontal)
        }
        .padding(.vertical)
    }

    private var importingView: some View {
        VStack(spacing: 20) {
            ProgressView()
                .scaleEffect(1.5)

            Text("Importing session...")
                .font(.headline)

            Text("Reading cookies from Safari")
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }

    private var successView: some View {
        VStack(spacing: 20) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 60))
                .foregroundColor(.green)

            Text("Session Imported!")
                .font(.title2)
                .bold()

            Text("Quinn is now connected to \(provider.displayName)")
                .font(.body)
                .foregroundColor(.secondary)
        }
    }

    private var errorView: some View {
        VStack(spacing: 20) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 60))
                .foregroundColor(.orange)

            Text("Import Failed")
                .font(.title2)
                .bold()

            if let error = errorMessage {
                Text(error)
                    .font(.body)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
            }

            Button("Try Again") {
                step = .instructions
                errorMessage = nil
                NSWorkspace.shared.open(provider.authURL)
            }
            .buttonStyle(.borderedProminent)
        }
    }

    private var bottomButtons: some View {
        HStack {
            Button("Cancel") {
                isPresented = false
            }
            .keyboardShortcut(.cancelAction)

            Spacer()

            if step == .instructions {
                Button("I'm Signed In") {
                    importCookiesFromSafari()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            } else if step == .success {
                Button("Continue") {
                    isPresented = false
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding()
    }

    private func importCookiesFromSafari() {
        step = .importing
        isImporting = true

        Task { @MainActor in
            // Use Node.js script with @mherod/get-cookie to read Safari cookies
            let scriptPath = Bundle.main.resourcePath! + "/../../../Scripts/get-safari-cookies.js"
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/local/bin/node")
            process.arguments = [scriptPath, provider.chatURL.host!]

            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe

            do {
                try process.run()
                process.waitUntilExit()

                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                let output = String(data: data, encoding: .utf8) ?? ""

                // Parse JSON output
                guard let jsonData = output.data(using: .utf8),
                      let cookieArray = try? JSONSerialization.jsonObject(with: jsonData) as? [[String: Any]] else {
                    errorMessage = "Failed to parse cookies from Safari"
                    step = .error
                    isImporting = false
                    return
                }

                // Convert to HTTPCookies
                var httpCookies: [HTTPCookie] = []
                for cookieDict in cookieArray {
                    var properties: [HTTPCookiePropertyKey: Any] = [:]
                    properties[.domain] = cookieDict["domain"] as? String ?? ""
                    properties[.name] = cookieDict["name"] as? String ?? ""
                    properties[.value] = cookieDict["value"] as? String ?? ""
                    properties[.path] = cookieDict["path"] as? String ?? "/"

                    if let secure = cookieDict["secure"] as? Bool, secure {
                        properties[.secure] = "TRUE"
                    }

                    if let cookie = HTTPCookie(properties: properties) {
                        httpCookies.append(cookie)
                    }
                }

                if httpCookies.isEmpty {
                    errorMessage = "No valid cookies found"
                    step = .error
                    isImporting = false
                    return
                }

                // Save cookies
                do {
                    try await ClaudeSessionManager.shared.saveSession(cookies: httpCookies)
                    await ProviderManager.shared.setActiveProvider(provider)

                    step = .success
                    try? await Task.sleep(nanoseconds: 1_500_000_000)
                    onSuccess(httpCookies)
                    isPresented = false
                } catch {
                    errorMessage = "Failed to save session: \(error.localizedDescription)"
                    step = .error
                }
            } catch {
                errorMessage = "Failed to run cookie extraction: \(error.localizedDescription)"
                step = .error
            }

            isImporting = false
        }
    }
}

struct InstructionRow: View {
    let number: String
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Text(number)
                .font(.headline)
                .foregroundColor(.white)
                .frame(width: 28, height: 28)
                .background(Circle().fill(Color.blue))

            Text(text)
                .font(.body)

            Spacer()
        }
    }
}

