import Foundation

/// Spawns and supervises the bundled Python sidecar processes that back
/// SoniqueBar: caal-stt, caal-tts, and caal-agent. All three bind to
/// 127.0.0.1 so nothing leaves the machine.
///
/// Stub. Process spawning, health polling, and crash recovery land during
/// Phase 2 of the packaging plan. Until then, SoniqueBar continues to use
/// ContainerManager against the networked CAAL stack.
///
/// See:
///   - Sidecar/README.md
///   - charlieseay/cael → services/
///   - Vault: Projects/Lab/Apps/Sonique/Packaging Plan.md
@MainActor
final class SidecarManager: ObservableObject {
    enum State: Equatable {
        case stopped
        case starting
        case running
        case failed(String)
    }

    struct Endpoints {
        let stt = URL(string: "http://127.0.0.1:8081")!
        let tts = URL(string: "http://127.0.0.1:8082")!
        let agent = URL(string: "http://127.0.0.1:8080")!
    }

    @Published private(set) var state: State = .stopped
    let endpoints = Endpoints()

    func start() async {
        state = .starting
        // TODO(phase-2): resolve bundled Python runtime path in Resources/Sidecar/
        // TODO(phase-2): spawn caal-stt, caal-tts, caal-agent via Process()
        // TODO(phase-2): poll /health on each endpoint until ready (30s timeout)
        // TODO(phase-2): restart on crash, surface failure state to UI
        state = .stopped
    }

    func stop() {
        // TODO(phase-2): terminate child processes cleanly
        state = .stopped
    }
}
