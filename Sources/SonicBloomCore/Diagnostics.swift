import Darwin
import Foundation

public struct ProcessCPUUsageSampler: Sendable {
    private var previousWallTime: TimeInterval?
    private var previousCPUTime: TimeInterval?

    public init() {}

    public mutating func sample(
        wallTime: TimeInterval = ProcessInfo.processInfo.systemUptime,
        processCPUTime: TimeInterval = Self.currentProcessCPUTime()
    ) -> Double {
        defer {
            previousWallTime = wallTime
            previousCPUTime = processCPUTime
        }
        guard let previousWallTime, let previousCPUTime else { return 0 }
        let wallDelta = wallTime - previousWallTime
        guard wallDelta > 0 else { return 0 }
        return max(0, (processCPUTime - previousCPUTime) / wallDelta * 100)
    }

    public static func currentProcessCPUTime() -> TimeInterval {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        return seconds(usage.ru_utime) + seconds(usage.ru_stime)
    }

    private static func seconds(_ value: timeval) -> TimeInterval {
        TimeInterval(value.tv_sec) + TimeInterval(value.tv_usec) / 1_000_000
    }
}
