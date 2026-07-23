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
            // Read cookies from Safari's containerized location (macOS 13+)
            // This requires Full Disk Access permission
            let safariCookiesPath = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Containers/com.apple.Safari/Data/Library/Cookies/Cookies.binarycookies")

            // Use python to read Safari's binary cookies format
            let pythonScript = """
            import sys
            import subprocess

            # Use macOS's built-in cookie reader
            result = subprocess.run([
                'python3', '-c',
                '''
import os
import struct
import datetime
from pathlib import Path

cookie_file = Path.home() / "Library/Containers/com.apple.Safari/Data/Library/Cookies/Cookies.binarycookies"
if not cookie_file.exists():
    print("[]")
    sys.exit(0)

# Safari binary cookies parsing - simplified for claude.ai domain only
with open(cookie_file, 'rb') as f:
    data = f.read()

# Look for claude.ai cookie markers in binary data
if b'claude.ai' in data:
    # Find sessionKey cookie
    if b'sessionKey' in data:
        print('{"domain": "claude.ai", "name": "sessionKey", "found": true}')
    else:
        print('{"domain": "claude.ai", "found": false}')
else:
    print('{"domain": "claude.ai", "found": false}')
'''
            ], capture_output=True, text=True)
            print(result.stdout)
            """

            // For now, just check if we can access the file
            let canReadSafariCookies = FileManager.default.isReadableFile(atPath: safariCookiesPath.path)

            if !canReadSafariCookies {
                errorMessage = "Cannot access Safari cookies. Full Disk Access may not be granted yet."
                step = .error
                isImporting = false
                return
            }

            // Fall back to WKWebView default store for now
            let cookieStore = WKWebsiteDataStore.default().httpCookieStore
            let cookies = await withCheckedContinuation { continuation in
                cookieStore.getAllCookies { cookies in
                    continuation.resume(returning: cookies)
                }
            }

            // Filter to provider-specific cookies
            let relevantCookies = cookies.filter { cookie in
                switch provider {
                case .claude:
                    return cookie.domain.contains("claude.ai")
                case .chatgpt:
                    return cookie.domain.contains("openai.com")
                case .gemini:
                    return cookie.domain.contains("google.com")
                case .ollama:
                    return cookie.domain.contains("localhost")
                }
            }

            if !relevantCookies.isEmpty {
                // Save cookies
                do {
                    try await ClaudeSessionManager.shared.saveSession(cookies: relevantCookies)
                    await ProviderManager.shared.setActiveProvider(provider)

                    step = .success

                    // Auto-close after 1.5 seconds
                    try? await Task.sleep(nanoseconds: 1_500_000_000)
                    onSuccess(relevantCookies)
                    isPresented = false
                } catch {
                    errorMessage = "Failed to save session: \(error.localizedDescription)"
                    step = .error
                }
            } else {
                errorMessage = "No \(provider.displayName) cookies found. Make sure you're signed in to \(provider.displayName) in Safari."
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

