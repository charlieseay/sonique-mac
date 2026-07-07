import Foundation
import os.log

/// Centralized error handling and retry logic for SoniqueBar connectors.
struct ConnectorErrorHandler {
    private static let logger = Logger(subsystem: "com.seaynic.SoniqueBar", category: "ConnectorError")

    /// Default request timeout for connector HTTP calls.
    static let defaultTimeout: TimeInterval = 15

    /// Handles an error from a connector, logs it, and returns a user-friendly failure result.
    static func handle(error: Error, connectorName: String) -> ConnectorResult {
        logger.error("[\(connectorName)] \(String(describing: error))")

        let userMessage: String

        if let connectorError = error as? ConnectorError {
            userMessage = mapConnectorError(connectorError, connectorName: connectorName)
        } else if let urlError = error as? URLError {
            userMessage = mapURLError(urlError, connectorName: connectorName)
        } else {
            userMessage = "An unexpected error occurred with the \(connectorName) connector."
        }

        return .failure(error: userMessage)
    }

    /// Executes an async throwing operation with automatic retry on transient failures.
    ///
    /// - Parameters:
    ///   - maxAttempts: Maximum number of attempts (default 3).
    ///   - delaySeconds: Base delay between retries in seconds (doubles each attempt).
    ///   - connectorName: Used for logging.
    ///   - operation: The async throwing closure to retry.
    /// - Returns: The result of the first successful attempt.
    static func withRetry<T>(
        maxAttempts: Int = 3,
        delaySeconds: Double = 1.0,
        connectorName: String,
        operation: () async throws -> T
    ) async throws -> T {
        var lastError: Error?

        for attempt in 1...maxAttempts {
            do {
                return try await operation()
            } catch let error as URLError where isTransient(error) {
                lastError = error
                if attempt < maxAttempts {
                    let delay = delaySeconds * pow(2.0, Double(attempt - 1))
                    logger.warning("[\(connectorName)] Attempt \(attempt) failed (\(error.localizedDescription)), retrying in \(String(format: "%.1f", delay))s")
                    try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                }
            } catch let error as ConnectorError where isTransient(error) {
                lastError = error
                if attempt < maxAttempts {
                    let delay = delaySeconds * pow(2.0, Double(attempt - 1))
                    logger.warning("[\(connectorName)] Attempt \(attempt) failed (\(error.localizedDescription)), retrying in \(String(format: "%.1f", delay))s")
                    try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                }
            } catch {
                // Non-transient errors (auth, bad params, etc.) fail immediately.
                throw error
            }
        }

        throw lastError ?? ConnectorError.connectionFailed
    }

    /// Returns a URLRequest with the default connector timeout applied.
    static func request(url: URL, method: String = "GET") -> URLRequest {
        var req = URLRequest(url: url, timeoutInterval: defaultTimeout)
        req.httpMethod = method
        return req
    }

    // MARK: - Private helpers

    private static func isTransient(_ error: URLError) -> Bool {
        switch error.code {
        case .timedOut, .networkConnectionLost, .notConnectedToInternet,
             .cannotConnectToHost, .dnsLookupFailed:
            return true
        default:
            return false
        }
    }

    private static func isTransient(_ error: ConnectorError) -> Bool {
        switch error {
        case .connectionFailed, .serviceUnavailable:
            return true
        default:
            return false
        }
    }

    private static func mapConnectorError(_ error: ConnectorError, connectorName: String) -> String {
        switch error {
        case .unknownCapability(let name):
            return "The \(connectorName) connector does not support the action: \(name)."
        case .missingParameter(let name):
            return "A required parameter is missing: \(name)."
        case .invalidParameter(let name, let expected, _):
            return "The parameter '\(name)' is invalid. Expected: \(expected)."
        case .authenticationFailed:
            return "Authentication failed for \(connectorName). Please check your credentials."
        case .connectionFailed:
            return "Could not connect to the \(connectorName) service."
        case .rateLimitExceeded:
            return "Too many requests to \(connectorName). Please try again later."
        case .serviceUnavailable:
            return "The \(connectorName) service is currently unavailable."
        case .invalidResponse(let message):
            logger.warning("[\(connectorName)] Invalid response detail: \(message)")
            return "Received an unexpected response from the \(connectorName) service."
        }
    }

    private static func mapURLError(_ error: URLError, connectorName: String) -> String {
        switch error.code {
        case .notConnectedToInternet, .networkConnectionLost:
            return "Please check your internet connection."
        case .timedOut:
            return "The request to \(connectorName) timed out."
        case .cannotFindHost, .dnsLookupFailed:
            return "Could not find the \(connectorName) service. Please check the server address."
        default:
            return "A network error occurred while contacting \(connectorName)."
        }
    }
}
