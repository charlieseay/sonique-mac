import Foundation

/// AI-powered diagnostic engine that analyzes errors and suggests fixes
struct DiagnosticAgent {

    /// Diagnostic snapshot from client (iOS or internal)
    struct Snapshot: Codable {
        let timestamp: Date
        let errorType: String
        let errorCode: Int?
        let errorDescription: String
        let networkType: String?  // "cellular", "wifi", "offline", "unknown"
        let tailscaleActive: Bool?
        let lastSuccessfulConnection: Date?
        let endpointsTried: [String]
        let deviceInfo: [String: String]?  // iOS version, device model, etc.
        let systemState: [String: String]?  // SoniqueBar state, Ollama status, etc.
    }

    /// Diagnostic result with confidence and remediation steps
    struct Diagnosis: Codable {
        let diagnosis: String
        let confidence: Double  // 0.0-1.0
        let evidence: [String]
        let rootCause: String
        let remediation: Remediation
        let technicalDetails: String?
    }

    struct Remediation: Codable {
        let autoFixable: Bool
        let requires: String?  // What's needed to fix (e.g., "iOS app rebuild")
        let userAction: String?  // What user should do
        let workaround: String?  // Temporary workaround
        let autoFixSteps: [String]?  // Steps the system can take automatically
    }

    /// Known issue patterns with solutions
    private static let knownIssues: [KnownIssue] = [
        KnownIssue(
            pattern: { snapshot in
                snapshot.errorCode == -1001 &&
                snapshot.networkType == "cellular" &&
                snapshot.endpointsTried.contains { $0.hasPrefix("http://100.") }
            },
            diagnosis: "iOS App Transport Security blocking HTTP over cellular",
            confidence: 0.95,
            evidence: [
                "URLError -1001 (timeout) on cellular network",
                "Attempting HTTP connection to Tailscale IP (100.x.x.x)",
                "iOS blocks insecure HTTP by default on cellular (iOS 14+)"
            ],
            rootCause: "Info.plist missing NSAppTransportSecurity exceptions for Tailscale IP",
            remediation: Remediation(
                autoFixable: false,
                requires: "iOS app rebuild with Info.plist update",
                userAction: "Install latest build from TestFlight with ATS exceptions, or switch to WiFi",
                workaround: "Connect to WiFi network or use VPN with HTTPS proxy",
                autoFixSteps: nil
            )
        ),

        KnownIssue(
            pattern: { snapshot in
                snapshot.errorCode == -1004 &&
                snapshot.endpointsTried.contains { $0.contains(":8890") }
            },
            diagnosis: "SoniqueBar service not reachable",
            confidence: 0.90,
            evidence: [
                "URLError -1004 (connection refused)",
                "Attempting connection to port 8890",
                "Service may be stopped or not listening on expected port"
            ],
            rootCause: "SoniqueBar not running or firewall blocking port 8890",
            remediation: Remediation(
                autoFixable: false,
                requires: "Service restart or firewall configuration",
                userAction: "Check if SoniqueBar is running in menu bar, restart if needed",
                workaround: nil,
                autoFixSteps: ["Check if process 'SoniqueBar' is running", "Verify port 8890 listener"]
            )
        ),

        KnownIssue(
            pattern: { snapshot in
                snapshot.errorDescription.contains("Ollama") ||
                snapshot.systemState?["ollama_status"] == "unreachable"
            },
            diagnosis: "Ollama LLM service unavailable",
            confidence: 0.85,
            evidence: [
                "Ollama service not responding on localhost:11434",
                "LLM queries timing out or failing"
            ],
            rootCause: "Ollama process crashed or not started",
            remediation: Remediation(
                autoFixable: true,
                requires: nil,
                userAction: nil,
                workaround: "System will fall back to pattern matching for simple queries",
                autoFixSteps: [
                    "Check Ollama process status",
                    "Attempt restart via launchctl",
                    "Verify localhost:11434 health endpoint"
                ]
            )
        ),

        KnownIssue(
            pattern: { snapshot in
                snapshot.errorCode == 401 &&
                snapshot.errorDescription.contains("ElevenLabs")
            },
            diagnosis: "ElevenLabs API authentication failed",
            confidence: 0.95,
            evidence: [
                "HTTP 401 Unauthorized from ElevenLabs API",
                "API key expired or invalid"
            ],
            rootCause: "Invalid or expired ElevenLabs API key",
            remediation: Remediation(
                autoFixable: false,
                requires: "Valid ElevenLabs API key",
                userAction: "Update API key in Settings → Voice",
                workaround: "Voice responses temporarily unavailable",
                autoFixSteps: nil
            )
        ),

        KnownIssue(
            pattern: { snapshot in
                snapshot.networkType == "offline" ||
                (snapshot.errorCode == -1009 && snapshot.networkType != nil)
            },
            diagnosis: "No network connectivity",
            confidence: 0.98,
            evidence: [
                "URLError -1009 (network offline)",
                "No active network connection detected"
            ],
            rootCause: "Device not connected to WiFi or cellular network",
            remediation: Remediation(
                autoFixable: false,
                requires: "Active network connection",
                userAction: "Connect to WiFi or enable cellular data",
                workaround: "On-device native intents (time, date, battery) still work offline",
                autoFixSteps: nil
            )
        ),

        KnownIssue(
            pattern: { snapshot in
                snapshot.tailscaleActive == false &&
                snapshot.endpointsTried.contains { $0.hasPrefix("http://100.") }
            },
            diagnosis: "Tailscale VPN inactive",
            confidence: 0.92,
            evidence: [
                "Attempting connection to Tailscale IP (100.x.x.x)",
                "Tailscale reported as inactive on device"
            ],
            rootCause: "Tailscale VPN not connected",
            remediation: Remediation(
                autoFixable: false,
                requires: "Tailscale connection",
                userAction: "Enable Tailscale VPN on your device",
                workaround: "Connect to same WiFi network as SoniqueBar (LAN access)",
                autoFixSteps: nil
            )
        )
    ]

    /// Known issue pattern matcher
    private struct KnownIssue {
        let pattern: (Snapshot) -> Bool
        let diagnosis: String
        let confidence: Double
        let evidence: [String]
        let rootCause: String
        let remediation: Remediation
    }

    /// Analyze error snapshot and return diagnosis
    static func diagnose(_ snapshot: Snapshot) async -> Diagnosis {
        // First, check known issue patterns
        for issue in knownIssues {
            if issue.pattern(snapshot) {
                NSLog("[diagnostic] Matched known issue: \(issue.diagnosis)")
                return Diagnosis(
                    diagnosis: issue.diagnosis,
                    confidence: issue.confidence,
                    evidence: issue.evidence,
                    rootCause: issue.rootCause,
                    remediation: issue.remediation,
                    technicalDetails: formatTechnicalDetails(snapshot)
                )
            }
        }

        // No known pattern matched - return generic diagnostic
        NSLog("[diagnostic] No known pattern matched, returning generic diagnosis")
        return Diagnosis(
            diagnosis: "Unknown error",
            confidence: 0.5,
            evidence: [
                "Error type: \(snapshot.errorType)",
                "Error code: \(snapshot.errorCode?.description ?? "unknown")",
                snapshot.errorDescription
            ],
            rootCause: "Could not determine root cause - error pattern not recognized",
            remediation: Remediation(
                autoFixable: false,
                requires: "Manual investigation",
                userAction: "Try restarting the app or check system status",
                workaround: nil,
                autoFixSteps: nil
            ),
            technicalDetails: formatTechnicalDetails(snapshot)
        )
    }

    private static func formatTechnicalDetails(_ snapshot: Snapshot) -> String {
        var details = """
        Timestamp: \(snapshot.timestamp)
        Error: \(snapshot.errorType)
        """

        if let code = snapshot.errorCode {
            details += "\nCode: \(code)"
        }

        if let network = snapshot.networkType {
            details += "\nNetwork: \(network)"
        }

        if let tailscale = snapshot.tailscaleActive {
            details += "\nTailscale: \(tailscale ? "active" : "inactive")"
        }

        if !snapshot.endpointsTried.isEmpty {
            details += "\nEndpoints tried: \(snapshot.endpointsTried.joined(separator: ", "))"
        }

        if let deviceInfo = snapshot.deviceInfo {
            details += "\nDevice: \(deviceInfo.map { "\($0.key)=\($0.value)" }.joined(separator: ", "))"
        }

        return details
    }
}
