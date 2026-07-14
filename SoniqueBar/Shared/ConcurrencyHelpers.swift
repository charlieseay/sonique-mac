import Foundation

public enum TimeoutError: Error, LocalizedError {
    case timedOut(label: String)

    public var errorDescription: String? {
        switch self {
        case .timedOut(let label):
            // A more user-friendly mapping from function names to descriptions
            let friendlyLabel: String
            switch label {
            case "handle(_:deviceBattery:)": friendlyLabel = "a native command"
            case "currentTime()": friendlyLabel = "getting the current time"
            case "currentDate()": friendlyLabel = "getting the current date"
            case "dayOfWeek()": friendlyLabel = "getting the day of the week"
            case "macBattery()": friendlyLabel = "getting Mac battery status"
            case "openTarget(_:)": friendlyLabel = "opening the target"
            case "setVolume(delta:)": friendlyLabel = "setting the volume"
            case "setMute(enabled:)": friendlyLabel = "changing mute status"
            case "todaysCalendar()", "todaysCalendar.predicate", "todaysCalendar.fetch", "todaysCalendar.format": friendlyLabel = "fetching calendar events"
            case "showReminders(forToday:)", "showReminders.fetch", "showReminders.format": friendlyLabel = "fetching reminders"
            case "getWeather()", "getWeather.network", "getWeather.stringConversion": friendlyLabel = "getting the weather"
            case "controlMusic(command:)": friendlyLabel = "controlling music"
            case "takeScreenshot()": friendlyLabel = "taking a screenshot"
            case "extractHomeKitDevice": friendlyLabel = "identifying the device"
            case "extractMinutes": friendlyLabel = "parsing the timer duration"
            case "controlHomeKitDevice(name:action:)": friendlyLabel = "home control"
            case "controlHomeKitDevice.urlSession": friendlyLabel = "communicating with home devices"
            case "getCurrentSong()": friendlyLabel = "getting the current song"
            case "setTimer(minutes:)": friendlyLabel = "setting the timer"
            case "cancelTimer()": friendlyLabel = "cancelling the timer"
            case "setFocusMode(enabled:)": friendlyLabel = "changing focus mode"
            case "setDoNotDisturb(enabled:)": friendlyLabel = "changing Do Not Disturb"
            case "adjustBrightness(direction:)": friendlyLabel = "adjusting brightness"
            case "setDarkMode(enabled:)": friendlyLabel = "changing appearance"
            case "lockScreen()": friendlyLabel = "locking the screen"
            case "sleepMac()": friendlyLabel = "putting the Mac to sleep"
            case "setWiFi(enabled:)": friendlyLabel = "changing Wi-Fi status"
            case "setBluetooth(enabled:)": friendlyLabel = "changing Bluetooth status"
            case "getDiskSpace()": friendlyLabel = "getting disk space"
            case "getSystemStats()": friendlyLabel = "getting system stats"
            case "shell.terminationHandler": friendlyLabel = "finishing a shell command"
            case "readFileWithTimeout(url:timeout:)": friendlyLabel = "reading a file"
            case "readFileWithTimeout.urlSession": friendlyLabel = "downloading from a URL"
            case "readLastNote()", "readLastNote.vaultPath": friendlyLabel = "reading notes"
            case "readTodaysNotes()", "readTodaysNotes.vaultPath": friendlyLabel = "reading today's notes"
            case "calculateMath(from:)": friendlyLabel = "the calculation"

            default: friendlyLabel = "an operation"
            }
            let capitalizedLabel = friendlyLabel.prefix(1).capitalized + friendlyLabel.dropFirst()
            return "\(capitalizedLabel) took too long and was cancelled."
        }
    }
}

/// Runs an async operation with a specified timeout.
/// - Throws: `TimeoutError` if the operation does not complete in time.
public func withTimeout<T: Sendable>(
    seconds: TimeInterval,
    label: String = #function,
    operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    return try await withThrowingTaskGroup(of: T.self) { group in
        // Task for the actual operation
        group.addTask {
            try await operation()
        }

        // Task that acts as the timeout
        group.addTask {
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            throw TimeoutError.timedOut(label: label)
        }

        // Await the first task to complete
        guard let result = try await group.next() else {
            throw CancellationError()
        }

        // Cancel the other task and return the result
        group.cancelAll()
        return result
    }
}
