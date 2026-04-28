import Foundation
import Combine

/// Spawns and supervises the bundled sidecar processes that back SoniqueBar:
/// Ollama + caal-stt + caal-tts + caal-agent. All four bind to 127.0.0.1 so
/// nothing leaves the machine.
///
/// Lifecycle:
///   1. `start()` — unpacks `python-runtime.tar.gz` from the app bundle to
///      Application Support on first run (subsequent launches are cached by
///      tarball sha256); spawns the four child processes via `launcher.sh`.
///   2. Health polling runs every 2 s. A failing service is restarted with
///      exponential backoff (1 s, 2 s, 4 s), max 3 attempts, before the
///      state flips to `.failed`.
///   3. `stop()` — SIGTERM every child; after 5 s, SIGKILL any stragglers.
///      Called automatically on `applicationWillTerminate`.
///
/// Coexistence: `ContainerManager` still drives the networked CAAL mode.
/// `MacSettings.deploymentMode` selects which supervisor SoniqueBar uses.
@MainActor
final class SidecarManager: ObservableObject {

    // MARK: - Public types

    enum State: Equatable {
        case stopped
        case unpacking
        case starting
        case running
        case degraded(String)       // healthy processes up, one or more unhealthy
        case failed(String)
    }

    enum DeploymentMode: String, CaseIterable, Identifiable {
        case networked  // legacy ContainerManager flow
        case embedded   // this class

        var id: String { rawValue }
        var label: String {
            switch self {
            case .networked: return "Networked (Docker + cael repo)"
            case .embedded:  return "Embedded (bundled sidecar)"
            }
        }
    }

    struct ServiceEndpoint {
        let name: String
        let port: Int?
        let healthURL: URL?
    }

    // MARK: - Published state

    @Published private(set) var state: State = .stopped
    @Published private(set) var serviceHealth: [String: Bool] = [:]
    /// True when a user-installed Ollama is reachable at 127.0.0.1:11434.
    /// Ollama is not bundled — this is informational only; it does not gate
    /// sidecar state. The UI surfaces it as a separate "Local LLM" indicator.
    @Published private(set) var ollamaAvailable: Bool = false

    // MARK: - Config

    // Sidecar-owned processes: STT, TTS, and the CAAL agent.
    // Ollama is the user's responsibility and is NOT spawned here.
    private static let services: [ServiceEndpoint] = [
        ServiceEndpoint(name: "stt",   port: 8081, healthURL: URL(string: "http://127.0.0.1:8081/health")),
        ServiceEndpoint(name: "tts",   port: 8082, healthURL: URL(string: "http://127.0.0.1:8082/health")),
        ServiceEndpoint(name: "agent", port: nil,  healthURL: nil),  // no HTTP health endpoint; checked by process liveness
    ]

    private static let ollamaHealthURL = URL(string: "http://127.0.0.1:11434/api/tags")!

    private static let healthInterval: TimeInterval = 2.0
    private static let maxRestartAttempts = 3
    nonisolated private static let gracefulShutdownSeconds: Double = 5.0

    // MARK: - Runtime

    private var sidecarRoot: URL?
    private var processes: [String: Process] = [:]
    private var restartAttempts: [String: Int] = [:]
    private var healthTimer: Timer?

    // MARK: - Lifecycle

    func start() async {
        let dbgURL = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("sidecar-debug.log")
        func dbg(_ msg: String) {
            let line = "\(Date()): \(msg)\n"
            if let data = line.data(using: .utf8) {
                if let fh = try? FileHandle(forUpdating: dbgURL) {
                    fh.seekToEndOfFile(); fh.write(data); try? fh.close()
                } else { try? data.write(to: dbgURL) }
            }
        }
        dbg("start() called, state=\(state)")
        NSLog("[Sidecar] start() called, current state: \(state)")
        guard state == .stopped || isFailedState(state) else {
            NSLog("[Sidecar] start() no-op — state is \(state)")
            dbg("start() no-op, state=\(state)")
            return
        }

        do {
            state = .unpacking
            dbg("resolving sidecar root…")
            NSLog("[Sidecar] resolving sidecar root…")
            let root = try await resolveSidecarRoot()
            sidecarRoot = root
            dbg("resolveSidecarRoot returned: \(root.path)")
            NSLog("[Sidecar] resolveSidecarRoot returned: \(root.path)")

            state = .starting
            dbg("calling spawnAll…")
            NSLog("[Sidecar] calling spawnAll…")
            try await spawnAll(root: root)
            dbg("spawnAll complete")
            NSLog("[Sidecar] spawnAll complete")

            // Fast-fail when every spawned process exits immediately (common when
            // sandbox blocks exec). This avoids waiting the full readiness budget.
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            let anyRunning = processes.values.contains { $0.isRunning }
            if !anyRunning {
                throw SidecarError.spawnedProcessesExitedImmediately
            }

            // 120s budget: STT loads the faster-whisper model on cold start (~60-90s)
            let ready = await waitForReady(timeout: 120.0)
            if ready {
                NSLog("[Sidecar] all services healthy — running")
                state = .running
                startHealthTimer()
            } else {
                NSLog("[Sidecar] timed out waiting for services to become healthy")
                state = .failed("sidecar did not become healthy within 120 s")
                stopSync()
            }
        } catch {
            dbg("start() CAUGHT ERROR: \(error)")
            state = .failed("start failed: \(error.localizedDescription)")
            stopSync()
        }
    }

    func stop() {
        stopHealthTimer()
        stopSync()
        state = .stopped
        serviceHealth.removeAll()
    }

    // MARK: - Tarball staging

    /// Returns the on-disk path that holds the unpacked sidecar tree.
    /// Unpacks the bundled tarball on first run; subsequent runs reuse the
    /// cached directory if its marker file matches the bundled tarball's
    /// sha256 (so app updates auto-refresh).
    private func resolveSidecarRoot() async throws -> URL {
        let dbgURL = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("sidecar-debug.log")
        func dbg(_ msg: String) {
            let line = "\(Date()): [resolve] \(msg)\n"
            if let data = line.data(using: .utf8) {
                if let fh = try? FileHandle(forUpdating: dbgURL) {
                    fh.seekToEndOfFile(); fh.write(data); try? fh.close()
                } else { try? data.write(to: dbgURL) }
            }
        }
        dbg("getting AppSupport URL")
        let support = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ).appendingPathComponent("SoniqueBar/sidecar", isDirectory: true)
        dbg("support=\(support.path)")
        NSLog("[Sidecar] resolve support path: \(support.path)")

        // Fast path: once staged, reuse local sidecar immediately. Re-hashing a
        // ~700MB tarball on every launch can stall startup long enough that users
        // see "connected but no voice" while STT/TTS never spawn.
        let shaMarker = support.appendingPathComponent(".tarball.sha256")
        let signMarker = support.appendingPathComponent(".codesign.ok")
        if FileManager.default.fileExists(atPath: support.path),
           FileManager.default.fileExists(atPath: shaMarker.path) {
            dbg("fast path: cached sidecar marker present — skipping tarball sha256")
            NSLog("[Sidecar] fast path: cached sidecar present")
            if !FileManager.default.fileExists(atPath: signMarker.path) {
                dbg("fast path: sign marker missing — re-signing cached binaries")
                NSLog("[Sidecar] re-signing cached sidecar binaries")
                try await signSidecarBinaries(in: support)
                try "ok".write(to: signMarker, atomically: true, encoding: .utf8)
            }
            return support
        }

        guard let bundledTarball = Bundle.main.url(
            forResource: "python-runtime",
            withExtension: "tar.gz"
        ) else {
            dbg("ERROR: tarball not found in bundle")
            throw SidecarError.bundleResourceMissing("python-runtime.tar.gz")
        }
        dbg("tarball=\(bundledTarball.path)")

        dbg("computing sha256 of tarball…")
        NSLog("[Sidecar] computing tarball sha256")
        let bundledSha = try await sha256(of: bundledTarball)
        dbg("bundledSha=\(bundledSha)")
        NSLog("[Sidecar] tarball sha256 computed")

        if FileManager.default.fileExists(atPath: shaMarker.path),
           let existing = try? String(contentsOf: shaMarker, encoding: .utf8),
           existing.trimmingCharacters(in: .whitespacesAndNewlines) == bundledSha {
            dbg("SHA match — using cached sidecar")
            return support  // cached, matches
        }
        dbg("SHA mismatch or no marker — will extract")

        // Need to unpack (or refresh after app update)
        if FileManager.default.fileExists(atPath: support.path) {
            try await removeDirectoryOffMainThread(support)
        }
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)

        try await extractTarball(bundledTarball, into: support)
        // Re-sign all native binaries with the app's own team certificate so the
        // sandbox allows exec. The bundled runtime ships with ad-hoc signatures
        // (TeamIdentifier=not set), which macOS blocks when a sandboxed app tries
        // to exec them.
        try await signSidecarBinaries(in: support)
        try "ok".write(to: signMarker, atomically: true, encoding: .utf8)
        try bundledSha.write(to: shaMarker, atomically: true, encoding: .utf8)

        return support
    }

    /// Large `removeItem` trees can block the main actor for tens of seconds.
    private func removeDirectoryOffMainThread(_ url: URL) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    try FileManager.default.removeItem(at: url)
                    cont.resume()
                } catch {
                    cont.resume(throwing: error)
                }
            }
        }
    }

    private func extractTarball(_ tarball: URL, into dir: URL) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            let task = Process()
            task.launchPath = "/usr/bin/tar"
            task.arguments = ["-xzf", tarball.path, "-C", dir.path]
            task.standardOutput = FileHandle.nullDevice
            task.standardError = FileHandle.nullDevice
            task.terminationHandler = { proc in
                if proc.terminationStatus == 0 {
                    cont.resume()
                } else {
                    cont.resume(throwing: SidecarError.tarballExtractFailed(status: proc.terminationStatus))
                }
            }
            do { try task.run() }
            catch { cont.resume(throwing: error) }
        }
    }

    private func sha256(of url: URL) async throws -> String {
        try await withCheckedThrowingContinuation { cont in
            let task = Process()
            task.launchPath = "/usr/bin/shasum"
            task.arguments = ["-a", "256", url.path]
            let pipe = Pipe()
            task.standardOutput = pipe
            task.standardError = FileHandle.nullDevice
            task.terminationHandler = { _ in
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                let line = String(data: data, encoding: .utf8) ?? ""
                cont.resume(returning: String(line.split(separator: " ").first ?? ""))
            }
            do { try task.run() }
            catch { cont.resume(throwing: error) }
        }
    }

    /// Re-signs every executable and shared library in the sidecar tree so the
    /// App Sandbox allows exec. Bundled Python ships with ad-hoc signatures
    /// (TeamIdentifier=not set); macOS blocks exec of those from a sandboxed
    /// parent. We re-sign with whatever Apple Development/Distribution identity
    /// is available in the keychain.
    private func signSidecarBinaries(in root: URL) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            DispatchQueue.global(qos: .userInitiated).async {
                // Discover the first usable code-signing identity SHA1 hash.
                let findTask = Process()
                findTask.launchPath = "/usr/bin/security"
                findTask.arguments = ["find-identity", "-v", "-p", "codesigning"]
                let pipe = Pipe()
                findTask.standardOutput = pipe
                findTask.standardError = FileHandle.nullDevice
                try? findTask.run()
                findTask.waitUntilExit()
                let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""

                // Lines look like:  1) HASH "Apple Development: Name (TEAM)"
                var identity: String? = nil
                for line in output.components(separatedBy: "\n") {
                    if line.contains("Apple Development") || line.contains("Apple Distribution") {
                        let parts = line.trimmingCharacters(in: .whitespaces).components(separatedBy: " ")
                        if parts.count >= 2, parts[1].count == 40 {
                            identity = parts[1]
                            break
                        }
                    }
                }
                guard let identity else { cont.resume(); return }

                let fm = FileManager.default
                guard let enumerator = fm.enumerator(
                    at: root,
                    includingPropertiesForKeys: [.isRegularFileKey, .isExecutableKey],
                    options: [.skipsHiddenFiles]
                ) else { cont.resume(); return }

                for case let url as URL in enumerator {
                    guard let rv = try? url.resourceValues(forKeys: [.isRegularFileKey, .isExecutableKey]),
                          rv.isRegularFile == true else { continue }
                    let ext = url.pathExtension
                    let shouldSign = ext == "so" || ext == "dylib" || ext.isEmpty || rv.isExecutable == true
                    guard shouldSign else { continue }
                    let task = Process()
                    task.launchPath = "/usr/bin/codesign"
                    task.arguments = ["--force", "--sign", identity, "--timestamp=none", url.path]
                    task.standardOutput = FileHandle.nullDevice
                    task.standardError = FileHandle.nullDevice
                    try? task.run()
                    task.waitUntilExit()
                }
                cont.resume()
            }
        }
    }

    // MARK: - Process spawning

    private func spawnAll(root: URL) async throws {
        let dbgURL = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("sidecar-debug.log")
        func dbg(_ msg: String) {
            let line = "\(Date()): [spawnAll] \(msg)\n"
            if let data = line.data(using: .utf8) {
                if let fh = try? FileHandle(forUpdating: dbgURL) {
                    fh.seekToEndOfFile(); fh.write(data); try? fh.close()
                } else { try? data.write(to: dbgURL) }
            }
        }
        dbg("evictStalePortHolders…")
        await evictStalePortHolders()
        dbg("evict done")
        for svc in Self.services {
            dbg("spawn \(svc.name)…")
            try spawn(service: svc, root: root)
            dbg("spawn \(svc.name) returned")
        }
    }

    /// Kill any process already bound to a sidecar service port so a fresh
    /// spawn can bind. Handles the case where a previous SoniqueBar instance
    /// was force-killed before stopSync could SIGTERM its children.
    ///
    /// Runs off the main actor — `lsof` + `waitUntilExit` + `Thread.sleep` must
    /// not block `@MainActor` or the menu bar never appears (App Not Responding).
    private func evictStalePortHolders() async {
        let services = Self.services
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            DispatchQueue.global(qos: .userInitiated).async {
                for svc in services {
                    guard let port = svc.port else { continue }
                    let task = Process()
                    task.launchPath = "/usr/sbin/lsof"
                    task.arguments = ["-nP", "-ti", "TCP:\(port)", "-sTCP:LISTEN"]
                    let pipe = Pipe()
                    task.standardOutput = pipe
                    task.standardError = FileHandle.nullDevice
                    do {
                        try task.run()
                    } catch {
                        continue
                    }
                    // lsof can occasionally hang; never block sidecar startup on eviction.
                    let deadline = Date().addingTimeInterval(1.5)
                    while task.isRunning && Date() < deadline {
                        Thread.sleep(forTimeInterval: 0.05)
                    }
                    if task.isRunning {
                        task.terminate()
                        Thread.sleep(forTimeInterval: 0.1)
                        if task.isRunning {
                            kill(task.processIdentifier, SIGKILL)
                        }
                    }
                    let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                    for pidStr in output.components(separatedBy: .newlines) {
                        guard let pid = Int32(pidStr.trimmingCharacters(in: .whitespaces)), pid > 0 else { continue }
                        kill(pid, SIGTERM)
                    }
                }
                Thread.sleep(forTimeInterval: 0.5)
                cont.resume()
            }
        }
    }

    private func spawn(service: ServiceEndpoint, root: URL) throws {
        let proc = Process()
        proc.launchPath = "/bin/bash"
        proc.arguments = [
            root.appendingPathComponent("launcher.sh").path,
            root.path,
            service.name,
        ]
        let logURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("sonique-sidecar-\(service.name).log")
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        let logHandle = try FileHandle(forWritingTo: logURL)
        proc.standardOutput = logHandle
        proc.standardError = logHandle
        proc.environment = sanitizedEnvironment()

        // On exit, trigger recovery — but only if the manager is in a
        // running/degraded state. If we're tearing down, just let it die.
        proc.terminationHandler = { [weak self] ended in
            Task { @MainActor in
                await self?.handleProcessExit(service.name, process: ended)
            }
        }

        try proc.run()
        processes[service.name] = proc
        serviceHealth[service.name] = false
        restartAttempts[service.name] = 0
    }

    private func sanitizedEnvironment() -> [String: String] {
        // Strip anything that could leak host state into the bundled runtime.
        var env: [String: String] = [:]
        env["HOME"] = ProcessInfo.processInfo.environment["HOME"] ?? NSHomeDirectory()
        env["USER"] = ProcessInfo.processInfo.environment["USER"] ?? NSUserName()
        env["LANG"] = "en_US.UTF-8"
        env["TZ"] = "America/Chicago"
        // Home Assistant REST credentials — only injected when configured
        let defaults = UserDefaults.standard
        if let url = defaults.string(forKey: "haURL"), !url.isEmpty {
            env["HA_URL"] = url
        }
        if let token = defaults.string(forKey: "haToken"), !token.isEmpty {
            env["HA_TOKEN"] = token
        }
        // Task #284: inject NVIDIA / LLM cloud env from `MacSettings` + `LLMRoutingCAALKeys`
        // parity here once `caal-agent` reads them (feature-flagged; never pass API keys from prefs).
        return env
    }

    // MARK: - Readiness

    private func waitForReady(timeout: TimeInterval) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            await runHealthSweep()
            let httpServices = Self.services.filter { $0.healthURL != nil }
            let allHealthy = httpServices.allSatisfy { serviceHealth[$0.name] == true }
            if allHealthy { return true }
            try? await Task.sleep(nanoseconds: 500_000_000)  // 500 ms
        }
        return false
    }

    // MARK: - Health polling

    private func startHealthTimer() {
        stopHealthTimer()
        healthTimer = Timer.scheduledTimer(withTimeInterval: Self.healthInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                await self?.runHealthSweep()
                self?.reconcileStateAfterSweep()
            }
        }
    }

    private func stopHealthTimer() {
        healthTimer?.invalidate()
        healthTimer = nil
    }

    private func runHealthSweep() async {
        await withTaskGroup(of: (String, Bool).self) { group in
            for svc in Self.services {
                group.addTask { [weak self] in
                    let ok = await self?.checkHealth(svc) ?? false
                    return (svc.name, ok)
                }
            }
            for await (name, ok) in group {
                serviceHealth[name] = ok
            }
        }
        // Probe user's Ollama separately — does not affect sidecar state
        ollamaAvailable = await probeURL(Self.ollamaHealthURL)
    }

    private nonisolated func probeURL(_ url: URL) async -> Bool {
        var req = URLRequest(url: url, timeoutInterval: 1.5)
        req.httpMethod = "GET"
        do {
            let (_, response) = try await URLSession.shared.data(for: req)
            return (response as? HTTPURLResponse).map { (200..<300).contains($0.statusCode) } ?? false
        } catch {
            return false
        }
    }

    private nonisolated func checkHealth(_ svc: ServiceEndpoint) async -> Bool {
        // Process liveness for services without an HTTP health endpoint
        guard let url = svc.healthURL else {
            // agent has no HTTP health; treat as healthy if the process is running
            return await MainActor.run { [weak self] in
                self?.processes[svc.name]?.isRunning ?? false
            }
        }
        var req = URLRequest(url: url, timeoutInterval: 1.5)
        req.httpMethod = "GET"
        do {
            let (_, response) = try await URLSession.shared.data(for: req)
            if let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) {
                return true
            }
            return false
        } catch {
            return false
        }
    }

    private func reconcileStateAfterSweep() {
        let unhealthy = Self.services.filter { serviceHealth[$0.name] == false }.map { $0.name }
        switch (unhealthy.isEmpty, state) {
        case (true, .running), (true, .degraded):
            state = .running
        case (false, .running):
            state = .degraded("unhealthy: \(unhealthy.joined(separator: ", "))")
        default:
            break
        }
    }

    // MARK: - Crash recovery

    private func handleProcessExit(_ name: String, process: Process) async {
        // Only recover if we're in an operating state
        guard state == .running || isDegradedState(state) else { return }

        let attempts = (restartAttempts[name] ?? 0) + 1
        restartAttempts[name] = attempts
        processes.removeValue(forKey: name)
        serviceHealth[name] = false

        guard attempts <= Self.maxRestartAttempts,
              let root = sidecarRoot,
              let svc = Self.services.first(where: { $0.name == name }) else {
            state = .failed("\(name) crashed \(attempts) times — giving up")
            return
        }

        // Exponential backoff: 1s, 2s, 4s
        let backoff = pow(2.0, Double(attempts - 1))
        try? await Task.sleep(nanoseconds: UInt64(backoff * 1_000_000_000))

        do {
            try spawn(service: svc, root: root)
            state = .degraded("restarted \(name) (attempt \(attempts))")
        } catch {
            state = .failed("could not restart \(name): \(error.localizedDescription)")
        }
    }

    // MARK: - Teardown

    /// Synchronous stop — used from `applicationWillTerminate` where we
    /// don't have time for an async handler to unwind.
    nonisolated func stopSync() {
        let procsCopy: [String: Process] = MainActor.assumeIsolated {
            let snapshot = self.processes
            self.processes.removeAll()
            return snapshot
        }

        // SIGTERM
        for (_, proc) in procsCopy where proc.isRunning {
            proc.terminate()
        }

        // Wait up to gracefulShutdownSeconds, then SIGKILL any stragglers
        let deadline = Date().addingTimeInterval(Self.gracefulShutdownSeconds)
        while Date() < deadline {
            if procsCopy.values.allSatisfy({ !$0.isRunning }) { break }
            Thread.sleep(forTimeInterval: 0.1)
        }
        for (_, proc) in procsCopy where proc.isRunning {
            kill(proc.processIdentifier, SIGKILL)
        }
    }

    // MARK: - Helpers

    private func isFailedState(_ s: State) -> Bool {
        if case .failed = s { return true }
        return false
    }
    private func isDegradedState(_ s: State) -> Bool {
        if case .degraded = s { return true }
        return false
    }
}

// MARK: - Errors

enum SidecarError: LocalizedError {
    case bundleResourceMissing(String)
    case tarballExtractFailed(status: Int32)
    case spawnedProcessesExitedImmediately

    var errorDescription: String? {
        switch self {
        case .bundleResourceMissing(let path):
            return "bundled resource missing: \(path)"
        case .tarballExtractFailed(let status):
            return "tar extraction failed with status \(status)"
        case .spawnedProcessesExitedImmediately:
            return "sidecar processes exited immediately after spawn"
        }
    }
}
