import SwiftUI
import AppKit

/// Setup assistant window for first-launch configuration
class SetupAssistantController: NSWindowController {

    convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 500),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.center()
        window.title = "Quinn Setup"
        window.isReleasedWhenClosed = false

        self.init(window: window)

        window.contentView = NSHostingView(rootView: SetupAssistantView(
            onComplete: { [weak self] in
                self?.close()
            }
        ))
    }

    func show() {
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

struct SetupAssistantView: View {
    let onComplete: () -> Void

    @StateObject private var providerManager = ProviderManager.shared
    @State private var selectedProvider: LLMProvider?
    @State private var showingAuth = false
    @State private var setupComplete = false
    @State private var errorMessage: String?
    @State private var testResponse: String?
    @State private var isTesting = false

    var body: some View {
        VStack(spacing: 0) {
            if !setupComplete {
                // Step 1: Provider Selection
                VStack(spacing: 30) {
                    Spacer()

                    Image(systemName: "waveform.circle.fill")
                        .font(.system(size: 80))
                        .foregroundColor(.blue)

                    Text("Welcome to Quinn")
                        .font(.largeTitle)
                        .bold()

                    Text("Connect your AI service to get started")
                        .foregroundColor(.secondary)

                    VStack(spacing: 12) {
                        ForEach([LLMProvider.claude, .chatgpt, .gemini, .ollama], id: \.self) { provider in
                            ProviderRow(
                                provider: provider,
                                isSelected: selectedProvider == provider,
                                isAuthenticating: false,
                                action: {
                                    selectedProvider = provider
                                    showingAuth = true
                                }
                            )
                        }
                    }
                    .padding()

                    if let error = errorMessage {
                        Text(error)
                            .foregroundColor(.red)
                            .font(.caption)
                            .padding()
                    }

                    Spacer()
                }
                .padding()
            } else {
                // Step 2: Success + Test
                VStack(spacing: 30) {
                    Spacer()

                    ZStack {
                        Circle()
                            .fill(Color.green.opacity(0.1))
                            .frame(width: 100, height: 100)

                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 60))
                            .foregroundColor(.green)
                    }

                    Text("All Set!")
                        .font(.title)
                        .bold()

                    Text("Quinn is ready to help")
                        .foregroundColor(.secondary)

                    // Test section
                    if isTesting {
                        ProgressView()
                            .padding()
                    } else if let response = testResponse {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Image(systemName: "waveform")
                                    .foregroundColor(.blue)
                                Text("Quinn says:")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }

                            Text(response)
                                .padding()
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(Color(.controlBackgroundColor))
                                .cornerRadius(8)
                        }
                        .padding()
                    } else {
                        Button("Test Quinn") {
                            runTest()
                        }
                        .buttonStyle(.borderedProminent)
                    }

                    Spacer()

                    Button(testResponse != nil ? "Done" : "Skip Test") {
                        onComplete()
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .padding(.bottom, 30)
                }
                .padding()
            }
        }
        .frame(width: 600, height: 500)
        .sheet(isPresented: $showingAuth) {
            if let provider = selectedProvider {
                BrowserAuthFlow(
                    provider: provider,
                    isPresented: $showingAuth,
                    onSuccess: { _ in
                        setupComplete = true
                    }
                )
            }
        }
    }

    private func runTest() {
        isTesting = true

        Task {
            do {
                let response = try await ProviderManager.shared.query("Tell me a fun fact in one sentence")

                await MainActor.run {
                    testResponse = response
                    isTesting = false
                }
            } catch {
                await MainActor.run {
                    testResponse = "Test failed: \(error.localizedDescription)"
                    isTesting = false
                }
            }
        }
    }
}

struct ProviderRow: View {
    let provider: LLMProvider
    let isSelected: Bool
    let isAuthenticating: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack {
                Image(systemName: iconName)
                    .font(.title2)
                    .foregroundColor(.blue)
                    .frame(width: 30)

                VStack(alignment: .leading, spacing: 4) {
                    Text(provider.displayName)
                        .font(.headline)

                    Text(description)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Spacer()

                if isAuthenticating {
                    ProgressView()
                        .scaleEffect(0.7)
                } else {
                    Image(systemName: "chevron.right")
                        .foregroundColor(.secondary)
                }
            }
            .padding()
            .background(isSelected ? Color.accentColor.opacity(0.1) : Color(.controlBackgroundColor))
            .cornerRadius(8)
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(isSelected ? Color.accentColor : Color.clear, lineWidth: 2)
            )
        }
        .buttonStyle(.plain)
    }

    var iconName: String {
        switch provider {
        case .claude: return "brain"
        case .chatgpt: return "bubble.left.and.bubble.right"
        case .gemini: return "sparkles"
        case .ollama: return "server.rack"
        }
    }

    var description: String {
        switch provider {
        case .claude: return "Best for reasoning and coding"
        case .chatgpt: return "Fast and conversational"
        case .gemini: return "Google's AI assistant"
        case .ollama: return "Run AI models locally"
        }
    }
}
