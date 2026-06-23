import Foundation
import SonicBloomCore

private struct Arguments {
    var watch = false
    var interval: TimeInterval = 2
}

private func parseArguments(_ raw: [String]) -> Arguments {
    var arguments = Arguments()
    var index = 1
    while index < raw.count {
        switch raw[index] {
        case "--watch":
            arguments.watch = true
        case "--once":
            arguments.watch = false
        case "--interval" where index + 1 < raw.count:
            arguments.interval = max(Double(raw[index + 1]) ?? arguments.interval, 0.5)
            index += 1
        default:
            break
        }
        index += 1
    }
    return arguments
}

private func sonicBloomIsRunning() -> Bool {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
    process.arguments = ["-x", "SonicBloom"]
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    do {
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus == 0
    } catch {
        return true
    }
}

@discardableResult
private func restoreIfAbandoned() -> Bool {
    do {
        return try CoreAudioRouteManager().restoreAbandonedBridgeSystemOutput(appIsRunning: sonicBloomIsRunning())
    } catch {
        fputs("SonicBloomRecovery: \(error.localizedDescription)\n", stderr)
        return false
    }
}

private let arguments = parseArguments(CommandLine.arguments)
if arguments.watch {
    while true {
        _ = restoreIfAbandoned()
        Thread.sleep(forTimeInterval: arguments.interval)
    }
} else {
    _ = restoreIfAbandoned()
    exit(0)
}
