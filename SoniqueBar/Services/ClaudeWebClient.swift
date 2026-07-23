import Foundation
import WebKit
import os.log

/// Headless browser client for querying Claude.ai
@MainActor
class ClaudeWebClient: NSObject {
    static let shared = ClaudeWebClient()

    private let logger = Logger(subsystem: "com.seayniclabs.soniquebar", category: "ClaudeWebClient")

    private var webView: WKWebView?
    private var currentCompletion: ((Result<String, Error>) -> Void)?
    private var queryTimeout: Timer?

    private override init() {
        super.init()
    }

    /// Query Claude.ai with saved session cookies
    func query(_ prompt: String, cookies: [HTTPCookie], timeout: TimeInterval = 30) async throws -> String {
        return try await withCheckedThrowingContinuation { continuation in
            performQuery(prompt, cookies: cookies, timeout: timeout) { result in
                continuation.resume(with: result)
            }
        }
    }

    private func performQuery(_ prompt: String, cookies: [HTTPCookie], timeout: TimeInterval, completion: @escaping (Result<String, Error>) -> Void) {
        logger.info("[ClaudeWebClient] Starting query with \(cookies.count) cookies")

        // Store completion handler
        currentCompletion = completion

        // Set timeout
        queryTimeout?.invalidate()
        queryTimeout = Timer.scheduledTimer(withTimeInterval: timeout, repeats: false) { [weak self] _ in
            self?.logger.error("[ClaudeWebClient] Query timeout")
            self?.cleanup()
            completion(.failure(WebClientError.timeout))
        }

        // Create headless WKWebView
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent() // Fresh data store

        webView = WKWebView(frame: .zero, configuration: config)
        webView?.navigationDelegate = self

        // Add cookies to data store
        let cookieStore = config.websiteDataStore.httpCookieStore
        let group = DispatchGroup()

        for cookie in cookies {
            group.enter()
            cookieStore.setCookie(cookie) {
                group.leave()
            }
        }

        // After cookies loaded, navigate to Claude.ai
        group.notify(queue: .main) { [weak self] in
            guard let self = self else { return }

            self.logger.info("[ClaudeWebClient] Cookies loaded, navigating to claude.ai")

            let request = URLRequest(url: URL(string: "https://claude.ai/new")!)
            self.webView?.load(request)
        }
    }

    private func cleanup() {
        queryTimeout?.invalidate()
        queryTimeout = nil
        webView?.navigationDelegate = nil
        webView = nil
        currentCompletion = nil
    }
}

// MARK: - WKNavigationDelegate

extension ClaudeWebClient: WKNavigationDelegate {
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        logger.info("[ClaudeWebClient] Page loaded")

        // Check if we're on the right page
        guard let url = webView.url?.absoluteString,
              (url.contains("claude.ai/new") || url.contains("claude.ai/chat")) else {
            logger.error("[ClaudeWebClient] Not on Claude.ai chat page: \(webView.url?.absoluteString ?? "nil")")
            cleanup()
            currentCompletion?(.failure(WebClientError.authenticationFailed))
            return
        }

        // Wait a moment for page to fully initialize
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            self?.injectPromptAndWaitForResponse()
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        logger.error("[ClaudeWebClient] Navigation failed: \(error.localizedDescription)")
        cleanup()
        currentCompletion?(.failure(WebClientError.navigationFailed(error)))
    }

    private func injectPromptAndWaitForResponse() {
        guard let webView = webView else { return }

        // JavaScript to inject prompt and extract response
        let js = """
        (async function() {
            // Find input field (multiple possible selectors)
            const input = document.querySelector('div[contenteditable="true"]') ||
                         document.querySelector('textarea[placeholder*="Talk"]') ||
                         document.querySelector('[data-testid="chat-input"]');

            if (!input) {
                return { error: "Input field not found" };
            }

            // Set prompt text
            if (input.tagName === 'TEXTAREA') {
                input.value = `\(escapeJavaScript(prompt))`;
            } else {
                input.textContent = `\(escapeJavaScript(prompt))`;

                // Trigger input event
                const event = new Event('input', { bubbles: true });
                input.dispatchEvent(event);
            }

            // Find and click send button
            const sendBtn = document.querySelector('button[aria-label*="Send"]') ||
                           document.querySelector('[data-testid="send-button"]') ||
                           Array.from(document.querySelectorAll('button')).find(btn =>
                               btn.textContent.includes('Send') || btn.getAttribute('aria-label')?.includes('Send')
                           );

            if (!sendBtn) {
                return { error: "Send button not found" };
            }

            sendBtn.click();

            // Wait for response (poll up to 30 seconds)
            let attempts = 0;
            const maxAttempts = 60; // 30 seconds at 500ms intervals

            while (attempts < maxAttempts) {
                await new Promise(resolve => setTimeout(resolve, 500));

                // Look for response container (multiple possible selectors)
                const responses = document.querySelectorAll('.response-content, [data-test-render-count], .markdown-content, [data-testid="response"]');

                if (responses.length > 0) {
                    // Get last response
                    const lastResponse = responses[responses.length - 1];
                    const text = lastResponse.innerText || lastResponse.textContent;

                    // Make sure it's not empty and not our prompt
                    if (text && text.trim().length > 0 && text !== `\(escapeJavaScript(prompt))`) {
                        return { response: text.trim() };
                    }
                }

                attempts++;
            }

            return { error: "Response timeout" };
        })();
        """

        webView.evaluateJavaScript(js) { [weak self] result, error in
            guard let self = self else { return }

            if let error = error {
                self.logger.error("[ClaudeWebClient] JavaScript error: \(error.localizedDescription)")
                self.cleanup()
                self.currentCompletion?(.failure(WebClientError.javascriptError(error)))
                return
            }

            guard let resultDict = result as? [String: String] else {
                self.logger.error("[ClaudeWebClient] Invalid result format")
                self.cleanup()
                self.currentCompletion?(.failure(WebClientError.invalidResponse))
                return
            }

            if let errorMsg = resultDict["error"] {
                self.logger.error("[ClaudeWebClient] JS returned error: \(errorMsg)")
                self.cleanup()
                self.currentCompletion?(.failure(WebClientError.javascriptError(NSError(domain: "ClaudeWebClient", code: -1, userInfo: [NSLocalizedDescriptionKey: errorMsg]))))
                return
            }

            if let response = resultDict["response"] {
                self.logger.info("[ClaudeWebClient] Got response: \(response.prefix(100))...")
                self.cleanup()
                self.currentCompletion?(.success(response))
                return
            }

            self.logger.error("[ClaudeWebClient] No response or error in result")
            self.cleanup()
            self.currentCompletion?(.failure(WebClientError.invalidResponse))
        }
    }

    private func escapeJavaScript(_ string: String) -> String {
        return string
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "'", with: "\\'")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
    }
}

enum WebClientError: LocalizedError {
    case timeout
    case authenticationFailed
    case navigationFailed(Error)
    case javascriptError(Error)
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .timeout:
            return "Query timeout - Claude took too long to respond"
        case .authenticationFailed:
            return "Authentication failed - please sign in again"
        case .navigationFailed(let error):
            return "Navigation failed: \(error.localizedDescription)"
        case .javascriptError(let error):
            return "JavaScript error: \(error.localizedDescription)"
        case .invalidResponse:
            return "Invalid response from Claude"
        }
    }
}
