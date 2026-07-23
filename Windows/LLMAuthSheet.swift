import SwiftUI
import WebKit
import AppKit

/// macOS sheet for LLM provider authentication via WKWebView
struct LLMAuthSheet: View {
    let provider: LLMProvider
    @Binding var isPresented: Bool
    let onSuccess: ([HTTPCookie]) -> Void

    @State private var isLoading = true
    @State private var errorMessage: String?
    @State private var loadingTimeout: Timer?

    var body: some View {
        VStack(spacing: 0) {
            if isLoading {
                VStack(spacing: 16) {
                    ProgressView()
                    Text("Loading \(provider.displayName)...")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let error = errorMessage {
                VStack(spacing: 20) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 60))
                        .foregroundColor(.orange)

                    Text("Authentication Failed")
                        .font(.headline)

                    Text(error)
                        .font(.body)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)

                    Button("Try Again") {
                        errorMessage = nil
                        isLoading = true
                    }
                    .buttonStyle(.borderedProminent)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                WebAuthViewMac(
                    provider: provider,
                    onLoadingStateChange: { loading in
                        isLoading = loading
                        if loading {
                            // Start 15 second timeout
                            loadingTimeout?.invalidate()
                            loadingTimeout = Timer.scheduledTimer(withTimeInterval: 15.0, repeats: false) { _ in
                                if isLoading {
                                    errorMessage = "Connection timeout. Please check your internet and try again."
                                    isLoading = false
                                }
                            }
                        } else {
                            loadingTimeout?.invalidate()
                        }
                    },
                    onSuccess: { cookies in
                        loadingTimeout?.invalidate()
                        handleAuthSuccess(cookies: cookies)
                    },
                    onError: { error in
                        loadingTimeout?.invalidate()
                        errorMessage = error
                        isLoading = false
                    }
                )
            }
        }
        .frame(width: 800, height: 600)
        .onDisappear {
            loadingTimeout?.invalidate()
        }
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") {
                    isPresented = false
                }
            }
        }
    }

    private func handleAuthSuccess(cookies: [HTTPCookie]) {
        Task { @MainActor in
            do {
                try await ClaudeSessionManager.shared.saveSession(cookies: cookies)
                await ProviderManager.shared.setActiveProvider(provider)
                isPresented = false
                onSuccess(cookies)
            } catch {
                errorMessage = "Failed to save session: \(error.localizedDescription)"
                isLoading = false
            }
        }
    }
}

/// NSViewRepresentable wrapper for WKWebView on macOS
struct WebAuthViewMac: NSViewRepresentable {
    let provider: LLMProvider
    let onLoadingStateChange: (Bool) -> Void
    let onSuccess: ([HTTPCookie]) -> Void
    let onError: (String) -> Void

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()

        // Enable JavaScript
        let preferences = WKWebpagePreferences()
        preferences.allowsContentJavaScript = true
        config.defaultWebpagePreferences = preferences

        // Use default website data store (shares cookies with Safari)
        config.websiteDataStore = .default()

        // Set process pool to allow cookies
        config.processPool = WKProcessPool()

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator

        // Set proper user agent to avoid bot detection
        webView.customUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15"

        var request = URLRequest(url: provider.authURL)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        webView.load(request)

        return webView
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    class Coordinator: NSObject, WKNavigationDelegate {
        let parent: WebAuthViewMac
        private var hasCheckedAuth = false

        init(_ parent: WebAuthViewMac) {
            self.parent = parent
        }

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            print("[LLMAuthSheet] Started loading: \(webView.url?.absoluteString ?? "unknown")")
            parent.onLoadingStateChange(true)
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            print("[LLMAuthSheet] Finished loading: \(webView.url?.absoluteString ?? "unknown")")
            parent.onLoadingStateChange(false)

            guard let url = webView.url?.absoluteString else { return }

            let isAuthenticated: Bool = {
                switch parent.provider {
                case .claude:
                    return url.contains("/new") || url.contains("/chat")
                case .chatgpt:
                    return url.contains("chat.openai.com") && !url.contains("/auth/")
                case .gemini:
                    return url.contains("/app") || url.contains("/chat")
                case .ollama:
                    return true
                }
            }()

            if isAuthenticated && !hasCheckedAuth {
                hasCheckedAuth = true
                extractCookies(from: webView)
            }
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            print("[LLMAuthSheet] Navigation failed: \(error.localizedDescription)")
            parent.onLoadingStateChange(false)
            parent.onError(error.localizedDescription)
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            print("[LLMAuthSheet] Provisional navigation failed: \(error.localizedDescription)")
            parent.onLoadingStateChange(false)
            parent.onError(error.localizedDescription)
        }

        private func extractCookies(from webView: WKWebView) {
            webView.configuration.websiteDataStore.httpCookieStore.getAllCookies { cookies in
                let relevantCookies = cookies.filter { cookie in
                    switch self.parent.provider {
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
                    self.parent.onSuccess(relevantCookies)
                } else {
                    self.parent.onError("No authentication cookies found")
                }
            }
        }
    }
}
