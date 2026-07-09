import Foundation

/// Tool for system information (hostname, uptime, disk, memory)
enum SystemInfoTool {
    static let toolName = "system_info"

    static func execute(input: [String: Any]) async -> String {
        let infoType = input["type"] as? String ?? "hostname"

        let process = Process()
        process.launchPath = "/bin/sh"

        let command: String
        switch infoType {
        case "hostname":
            command = "hostname"

        case "uptime":
            command = "uptime"

        case "disk":
            command = "df -h /"

        case "memory":
            command = "vm_stat | head -10"

        case "cpu":
            command = "sysctl -n machdep.cpu.brand_string"

        case "os":
            command = "sw_vers"

        default:
            return "ERROR: Unknown info type '\(infoType)'. Use: hostname, uptime, disk, memory, cpu, os"
        }

        process.arguments = ["-c", command]

        let pipe = Pipe()
        process.standardOutput = pipe

        do {
            try process.run()
            process.waitUntilExit()

            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            if let output = String(data: data, encoding: .utf8) {
                return output.trimmingCharacters(in: .whitespacesAndNewlines)
            } else {
                return "ERROR: No output"
            }
        } catch {
            return "ERROR: \(error.localizedDescription)"
        }
    }
}
