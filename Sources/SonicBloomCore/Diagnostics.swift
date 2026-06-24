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

public struct AudioConfidenceReport: Equatable, Sendable {
    public var headline: String
    public var route: String
    public var latency: String
    public var clipping: String
    public var cpu: String
    public var recovery: String
    public var isPassing: Bool

    public init(headline: String, route: String, latency: String, clipping: String, cpu: String, recovery: String, isPassing: Bool) {
        self.headline = headline
        self.route = route
        self.latency = latency
        self.clipping = clipping
        self.cpu = cpu
        self.recovery = recovery
        self.isPassing = isPassing
    }
}

public enum AudioConfidenceReportBuilder {
    public static func build(
        routeState: AudioRouteState,
        meter: DSPMeter,
        cpuUsagePercent: Double,
        audioHealth: AudioStreamHealth,
        lastError: String?
    ) -> AudioConfidenceReport {
        let routeOK = routeState.isProcessingAvailable && routeState.selectedPhysicalOutputName != nil
        let latencyOK = routeState.estimatedLatencyMS <= 20
        let cpuOK = cpuUsagePercent <= 20
        let healthOK = !audioHealth.needsRepair && lastError == nil
        let passing = routeOK && latencyOK && cpuOK && healthOK
        return AudioConfidenceReport(
            headline: passing ? "Ready for daily use" : "Needs one fix",
            route: routeOK ? "Route OK -> \(routeState.selectedPhysicalOutputName ?? "Output")" : "Route needs output or driver",
            latency: latencyOK ? String(format: "Latency OK: %.1f ms", routeState.estimatedLatencyMS) : String(format: "Latency high: %.1f ms", routeState.estimatedLatencyMS),
            clipping: meter.limitedSamples == 0 ? "No clipping" : "\(meter.limitedSamples) peaks protected",
            cpu: cpuOK ? String(format: "CPU OK: %.1f%%", cpuUsagePercent) : String(format: "CPU high: %.1f%%", cpuUsagePercent),
            recovery: healthOK ? "Audio path stable" : (lastError ?? audioHealth.summary),
            isPassing: passing
        )
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
        activeSpatialProfileName: String? = nil,
        perAppCaptureSummary: String = "Global route",
        settings: SonicBloomSettings = .default,
        audioHealth: AudioStreamHealth = AudioStreamHealth(),
        lastError: String?
    ) -> String {
        [
            "SonicBloom Diagnostics",
            "Preset: \(selectedPresetName)",
            "Sync Mode: \(syncMode.rawValue)",
            "Spatial Profile: \(activeSpatialProfileName ?? "Synthetic HRTF")",
            "Per-App Capture: \(perAppCaptureSummary)",
            "Smart Matching: \(settings.smartPresetMatching ? "On" : "Off")",
            "App Profiles: \(settings.applyAppProfilesAutomatically ? "Auto" : "Manual")",
            "Reduce Motion: \(settings.reduceMotion ? "On" : "Off")",
            String(format: "Waveform Intensity: %.2f", settings.waveformIntensity),
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
            "Audio Health: \(audioHealth.summary)",
            "Confidence: \(AudioConfidenceReportBuilder.build(routeState: routeState, meter: meter, cpuUsagePercent: cpuUsagePercent, audioHealth: audioHealth, lastError: lastError).headline)",
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
