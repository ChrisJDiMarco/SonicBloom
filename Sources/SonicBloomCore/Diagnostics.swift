import Darwin
import Foundation

public struct TrustSummary: Equatable, Sendable {
    public var headline: String
    public var clipping: String
    public var route: String
    public var cpu: String

    public init(headline: String, clipping: String, route: String, cpu: String) {
        self.headline = headline
        self.clipping = clipping
        self.route = route
        self.cpu = cpu
    }
}

public enum TrustSummaryBuilder {
    public static func build(
        routeState: AudioRouteState,
        meter: DSPMeter,
        cpuUsagePercent: Double,
        lastError: String?
    ) -> TrustSummary {
        let needsAttention = lastError != nil || routeState.installHealth == .degraded || !routeState.isProcessingAvailable
        return TrustSummary(
            headline: needsAttention ? "Needs attention" : "Audio protected",
            clipping: clippingText(meter.limitedSamples),
            route: routeText(routeState),
            cpu: cpuUsagePercent > 15 ? "CPU high" : "CPU normal"
        )
    }

    private static func clippingText(_ limitedSamples: UInt32) -> String {
        limitedSamples == 0 ? "No clipping" : "\(NumberFormatter.localizedString(from: NSNumber(value: limitedSamples), number: .decimal)) peaks protected"
    }

    private static func routeText(_ routeState: AudioRouteState) -> String {
        guard routeState.isProcessingAvailable else { return "Route degraded" }
        guard let output = routeState.selectedPhysicalOutputName, !output.isEmpty else { return "Route needs output" }
        return "Route healthy -> \(output)"
    }
}

public enum SonicBloomDiagnosticsReport {
    public static func build(
        routeState: AudioRouteState,
        meter: DSPMeter,
        cpuUsagePercent: Double,
        selectedPresetName: String,
        syncMode: AudioSyncMode,
        lastError: String?
    ) -> String {
        [
            "SonicBloom Diagnostics",
            "Preset: \(selectedPresetName)",
            "Sync Mode: \(syncMode.rawValue)",
            "Install Health: \(routeState.installHealth.rawValue)",
            "Input: \(routeState.bridgeInputDeviceName ?? "No input")",
            "Output: \(routeState.selectedPhysicalOutputName ?? "No output")",
            "Sample Rate: \(Int(routeState.sampleRate.rounded())) Hz",
            "Channels: \(routeState.channels)",
            "Buffer: \(routeState.bufferSize) frames",
            String(format: "Latency: %.1f ms", routeState.estimatedLatencyMS),
            String(format: "CPU: %.1f%%", cpuUsagePercent),
            String(format: "Input Peak: %.2f", meter.inputPeak),
            String(format: "Output Peak: %.2f", meter.outputPeak),
            String(format: "Gain Reduction: %.1f dB", meter.gainReductionDB),
            "Clips Protected: \(meter.limitedSamples)",
            "Recovery: \(routeState.recoverySummary)",
            "Status: \(routeState.statusMessage)",
            "Last Error: \(lastError ?? "None")"
        ].joined(separator: "\n")
    }
}

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
