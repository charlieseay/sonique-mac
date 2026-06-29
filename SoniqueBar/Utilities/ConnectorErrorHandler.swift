import Foundation
import os.log

/// Centralized error handling for SoniqueBar connectors.
struct ConnectorErrorHandler {
    private static let logger = Logger(subsystem: "com.seaynic.SoniqueBar", category: "ConnectorError")

    /// Handles an error from a connector, logs it, and returns a user-friendly failure result.
    /// - Parameters:
    ///   - error: The error that was thrown.
    ///   - connectorName: The name of the connector where the error occurred.
    /// - Returns: A `ConnectorResult` representing the failure.
    static func handle(error: Error, connectorName: String) -> ConnectorResult {
        // Log the detailed technical error for debugging.
        logger.error("[\(connectorName)] \(String(describing: error))")

        let userMessage: String

        // Generate a user-friendly message based on the error type.
        if let connectorError = error as? ConnectorError {
            userMessage = mapConnectorError(connectorError, connectorName: connectorName)
        } else if let urlError = error as? URLError {
            userMessage = mapURLError(urlError, connectorName: connectorName)
        } else {
            userMessage = "An unexpected error occurred with the \(connectorName) connector."
        }

        return .failure(error: userMessage)
    }

    /// Maps a `ConnectorError` to a user-friendly string.
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
            // Avoid showing technical details to the user, but log them.
            logger.warning("[\(connectorName)] Invalid response detail: \(message)")
            return "Received an unexpected response from the \(connectorName) service."
        }
    }

    /// Maps a `URLError` to a user-friendly string.
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
