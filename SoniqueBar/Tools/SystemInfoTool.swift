enum SystemInfoTool { static func execute(input: [String: Any]) async -> String { let sysctlProcess = Process() sysctlProcess.launchPath = "/usr/sbin/sysctl" sysctlProcess.arguments = ["-a"] let dfProcess = Process() dfProcess.launchPath = "/bin/df" let uptimeProcess = Process() uptimeProcess.launchPath = "/usr/bin/uptime" let sysctlOutput = await sysctlProcess.run() let dfOutput = await dfProcess.run() let uptimeOutput = await uptimeProcess.run() return "System: \(sysctlOutput)
Disk: \(dfOutput)
Uptime: \(uptimeOutput)" } }
