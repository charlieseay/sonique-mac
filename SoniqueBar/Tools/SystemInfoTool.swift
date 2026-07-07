import Foundation

/// Wraps `/usr/sbin/sysctl`, `/bin/df`, and `/usr/bin/uptime` for system information.
enum SystemInfoTool {

    static let toolName = "system_info"

    /// Execute the system info tool.
    /// Input key: "query" — one of "disk", "memory", "cpu", "uptime", or "all"
    static func execute(input: [String: Any]) async -> String {
        let query = (input["query"] as? String ?? "all").lowercased()

        switch query {
        case "disk":
            return await diskSpace()
        case "memory", "ram":
            return await memoryInfo()
        case "cpu":
            return await cpuInfo()
        case "uptime":
            return await uptimeInfo()
        default:
            // "all" or unrecognised — return a compact summary
            let disk = await diskSpace()
            let memory = await memoryInfo()
            let uptime = await uptimeInfo()
            return "\(disk)\n\(memory)\n\(uptime)"
        }
    }

    // MARK: - Disk space via /bin/df

    private static func diskSpace() async -> String {
        let result = await run(
            executable: "/bin/df",
            arguments: ["-h", "/"]
        )
        guard result.exitCode == 0 else {
            return "Couldn't read disk space."
        }
        // df -h / produces two lines: header + data.
        // Parse the data line for Used/Available/Capacity.
        let lines = result.stdout.components(separatedBy: "\n").filter { !$0.isEmpty }
        guard lines.count >= 2 else { return result.stdout }
        let fields = lines[1].components(separatedBy: .whitespaces).filter { !$0.isEmpty }
        // Typical columns: Filesystem Size Used Avail Capacity Mounted
        if fields.count >= 4 {
            return "Disk: \(fields[3]) available of \(fields[1]) total (\(fields[4]) used)."
        }
        return lines[1]
    }

    // MARK: - Memory via sysctl

    private static func memoryInfo() async -> String {
        // hw.memsize gives physical RAM in bytes
        let total = await run(executable: "/usr/sbin/sysctl", arguments: ["-n", "hw.memsize"])
        guard total.exitCode == 0,
              let bytes = UInt64(total.stdout.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            return "Couldn't read memory info."
        }
        let gb = Double(bytes) / 1_073_741_824
        let gbStr = String(format: "%.0f", gb)
        return "Memory: \(gbStr) GB physical RAM."
    }

    // MARK: - CPU info via sysctl

    private static func cpuInfo() async -> String {
        async let brandResult = run(executable: "/usr/sbin/sysctl", arguments: ["-n", "machdep.cpu.brand_string"])
        async let coresResult = run(executable: "/usr/sbin/sysctl", arguments: ["-n", "hw.logicalcpu"])

        let brand = await brandResult
        let cores = await coresResult

        let brandStr = brand.exitCode == 0
            ? brand.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            : "Unknown CPU"
        let coresStr = cores.exitCode == 0
            ? cores.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            : "?"

        return "CPU: \(brandStr), \(coresStr) logical cores."
    }

    // MARK: - Uptime via /usr/bin/uptime

    private static func uptimeInfo() async -> String {
        let result = await run(executable: "/usr/bin/uptime", arguments: [])
        guard result.exitCode == 0 else {
            return "Couldn't read uptime."
        }
        return result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Process runner with 10-second timeout

    private static func run(executable: String, arguments: [String]) async -> (stdout: String, exitCode: Int32) {
        await withCheckedContinuation { continuation in
            var resumed = false
            let lock = NSLock()

            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments

            let outPipe = Pipe()
            process.standardOutput = outPipe
            process.standardError = Pipe()

            guard (try? process.run()) != nil else {
                continuation.resume(returning: ("", -1))
                return
            }

            let deadline = DispatchTime.now() + 10.0
            DispatchQueue.global().asyncAfter(deadline: deadline) {
                lock.lock()
                defer { lock.unlock() }
                if !resumed {
                    resumed = true
                    if process.isRunning { process.terminate() }
                    continuation.resume(returning: ("", -2))
                }
            }

            DispatchQueue.global().async {
                process.waitUntilExit()
                let data = outPipe.fileHandleForReading.readDataToEndOfFile()
                let stdout = String(data: data, encoding: .utf8) ?? ""
                lock.lock()
                defer { lock.unlock() }
                if !resumed {
                    resumed = true
                    continuation.resume(returning: (stdout, process.terminationStatus))
                }
            }
        }
    }
}
