import Foundation
import os.log

/// Advertises SoniqueBar backend via Bonjour so iOS clients can auto-discover
/// the server without hardcoded IPs.
///
/// Service type: _sonique._tcp
/// Port: 8890
///
/// iOS clients browse for this service and extract the IP+port dynamically.
class BonjourService: NSObject {
    private let logger = Logger(subsystem: "com.seayniclabs.soniquebar", category: "Bonjour")
    private var service: NetService?

    /// Start advertising the SoniqueBar backend on port 8890
    func start() {
        // Advertise as "_sonique._tcp" on port 8890
        service = NetService(domain: "local.", type: "_sonique._tcp.", name: "SoniqueBar", port: 8890)
        service?.delegate = self
        service?.publish()

        logger.info("[Bonjour] Started advertising _sonique._tcp.local on port 8890")
    }

    /// Stop advertising
    func stop() {
        service?.stop()
        service = nil
        logger.info("[Bonjour] Stopped advertising")
    }
}

// MARK: - NetServiceDelegate
extension BonjourService: NetServiceDelegate {
    func netServiceDidPublish(_ sender: NetService) {
        logger.info("[Bonjour] ✅ Service published successfully: \(sender.name)")
    }

    func netService(_ sender: NetService, didNotPublish errorDict: [String : NSNumber]) {
        logger.error("[Bonjour] ❌ Failed to publish service: \(errorDict)")
    }

    func netServiceDidStop(_ sender: NetService) {
        logger.info("[Bonjour] Service stopped")
    }
}
