@preconcurrency import AppKit
import AVFoundation
import Foundation
import SonicBloomCore

@MainActor
final class SonicBloomMeterModel: ObservableObject {
    @Published var meter = DSPMeter()
}

struct TrustDiagnostic: Identifiable {
    var title: String
    var value: String
    var tint: TrustTint

    var id: String { title }
}

enum TrustTint {
    case green
    case blue
    case orange
}

enum CalibrationSound {
    case tone
    case noise
}

@MainActor
final class SonicBloomViewModel: ObservableObject {
    let routeManager = CoreAudioRouteManager()
    private let bridge = SonicBloomAudioBridge()
    private let calibrationTonePlayer = CalibrationTonePlayer()
    private let audioControlQueue = DispatchQueue(label: "com.chrisdimarco.sonicbloom.audio-control")
    private let defaults: UserDefaults
    private var cpuSampler = ProcessCPUUsageSampler()
    private var cpuRefreshTask: Task<Void, Never>?
    private var routeRecoveryTask: Task<Void, Never>?
    private var appActivationObserver: NSObjectProtocol?
    private var smartPresetStabilizer = SmartPresetStabilizer()
    private var activeProfileOutputName: String?
    private var isApplyingDevicePreset = false
    private var isApplyingSmartPreset = false
    let meterModel = SonicBloomMeterModel()
    let presets = PresetCatalog.builtIns
    @Published var selectedPreset: DSPPreset = .cleanLoud {
        didSet {
            updateBridgePreset()
            rememberSelectedPresetForCurrentOutput()
        }
    }
    @Published var profile: SonicBloomProfile {
        didSet {
            save(profile, forKey: DefaultsKey.profile)
            refreshAppMixerRules()
            activeAppRule = profile.effectiveAppRule(for: foregroundAppBundleIdentifier)
            if oldValue.effectiveSyncMode(for: foregroundAppBundleIdentifier, default: settings.syncMode, contentProfile: smartContentProfile) != processingSyncMode {
                routeState.bufferSize = Int(processingSyncMode.preferredBufferFrameSize)
                if isBridgeRunning, !isTransitioning {
                    startBridge()
                    return
                }
            }
            updateBridgePreset()
        }
    }
    @Published var settings: SonicBloomSettings {
        didSet {
            save(settings, forKey: DefaultsKey.settings)
            if !settings.smartPresetMatching {
                smartPresetStabilizer.reset()
            }
            if oldValue.syncMode != settings.syncMode {
                routeState.bufferSize = Int(processingSyncMode.preferredBufferFrameSize)
                if isBridgeRunning, !isTransitioning {
                    startBridge()
                    return
                }
            }
            updateBridgePreset()
        }
    }
    @Published var routeState: AudioRouteState
    @Published var isBypassed = false {
        didSet { updateBridgePreset() }
    }
    @Published var isBridgeRunning = false
    @Published var isTransitioning = false
    @Published var lastError: String?
    @Published private(set) var cpuUsagePercent = 0.0
    @Published private(set) var smartContentProfile: SmartContentProfile = .quiet
    @Published private(set) var appMixerRules: [AppAudioRule] = []
    @Published private(set) var foregroundAppBundleIdentifier: String?
    @Published private(set) var activeAppRule: AppAudioRule?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        profile = Self.load(SonicBloomProfile.self, from: defaults, key: DefaultsKey.profile) ?? .default
        settings = Self.load(SonicBloomSettings.self, from: defaults, key: DefaultsKey.settings) ?? .default
        routeState = routeManager.currentState()
        activeProfileOutputName = routeState.selectedPhysicalOutputName
        selectedPreset = presetForOutput(routeState.selectedPhysicalOutputName)
        bridge.meterHandler = { [weak self] meter in
            Task { @MainActor in
                self?.handleMeter(meter)
            }
        }
        refreshAppMixerRules()
        refreshForegroundApplication()
        startAppActivationObserver()
        startCPURefresh()
    }

    deinit {
        cpuRefreshTask?.cancel()
        routeRecoveryTask?.cancel()
        if let appActivationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(appActivationObserver)
        }
    }

    func refreshRoute() {
        let previous = routeState
        var next = routeManager.currentState()
        next.recoveryMessage = previous.recoveryMessage
        next.recoveryAttempts = previous.recoveryAttempts
        if isBridgeRunning {
            next.bufferSize = previous.bufferSize
        }
        let shouldRestartBridge = next.needsBridgeRestart(after: previous, bridgeWasRunning: isBridgeRunning)
        if isBridgeRunning, !next.isProcessingAvailable {
            next = next.recordingDegradedRecovery("Route degraded: SonicBloom Output unavailable.")
        } else if shouldRestartBridge,
                  let oldOutput = previous.selectedPhysicalOutputName,
                  let newOutput = next.selectedPhysicalOutputName,
                  oldOutput != newOutput {
            next = next.recordingRecovery("Recovered route: \(oldOutput) -> \(newOutput)")
        } else if shouldRestartBridge {
            next = next.recordingRecovery("Recovered SonicBloom audio route.")
        }
        routeState = next
        applyDevicePresetIfNeeded()
        if shouldRestartBridge {
            startBridge()
        }
    }

    func recoverAfterSystemWake() {
        let wasRunning = isBridgeRunning
        refreshRoute()
        guard wasRunning else { return }
        routeState = routeState.recordingRecovery("Recovered route after system wake.")
        if routeState.isProcessingAvailable {
            updateBridgePreset()
        }
    }

    func toggleBridge() {
        isBridgeRunning ? stopBridge() : startBridge()
    }

    var primaryActionTitle: String {
        if isTransitioning {
            return isBridgeRunning ? "Turning Off..." : "Turning On..."
        }
        if isBridgeRunning {
            return "Turn Off Enhancement"
        }
        return routeState.isProcessingAvailable ? "Enhance Mac Audio" : "Install SonicBloom Output"
    }

    var primaryActionIcon: String {
        if isBridgeRunning {
            return "power.circle.fill"
        }
        return routeState.isProcessingAvailable ? "sparkles" : "arrow.down.circle.fill"
    }

    func runPrimaryAction() {
        guard !isTransitioning else { return }
        if routeState.isProcessingAvailable || isBridgeRunning {
            toggleBridge()
        } else {
            installVirtualDevice()
        }
    }

    func startBridge() {
        isTransitioning = true
        defer { isTransitioning = false }
        do {
            isBypassed = false
            let plannedRoute = routeManager.currentState()
            guard let inputDeviceID = plannedRoute.bridgeInputDeviceID,
                  let outputDeviceID = plannedRoute.selectedPhysicalOutputID else {
                throw AudioRouteError.bridgeUnavailable("SonicBloom Output and a physical stereo output are required before processing can start.")
            }
            try bridge.start(
                inputDeviceID: inputDeviceID,
                outputDeviceID: outputDeviceID,
                preset: processingPreset,
                bypass: isBypassed,
                loudnessMatchedBypass: settings.loudnessMatchedCompare,
                preferredBufferFrameSize: processingSyncMode.preferredBufferFrameSize
            )
            let selection = try routeManager.activateBridgeSystemOutput()
            bridge.applyBufferPreference(
                inputDeviceID: selection.input.id,
                outputDeviceID: selection.output.id,
                frameSize: processingSyncMode.preferredBufferFrameSize
            )
            bridge.scheduleBufferPreferenceRetries(
                inputDeviceID: selection.input.id,
                outputDeviceID: selection.output.id,
                frameSize: processingSyncMode.preferredBufferFrameSize
            )
            routeState = routeManager.currentState()
            routeState.installHealth = .active
            routeState.bufferSize = Int(processingSyncMode.preferredBufferFrameSize)
            routeState.statusMessage = "Processing active: \(selection.input.name) -> \(selection.output.name)"
            isBridgeRunning = true
            startRouteRecoveryWatchdog()
            lastError = nil
        } catch {
            bridge.stop()
            routeRecoveryTask?.cancel()
            try? routeManager.restorePreviousSystemOutput()
            isBridgeRunning = false
            lastError = error.localizedDescription
            refreshRoute()
        }
    }

    func stopBridge() {
        guard !isTransitioning else { return }
        isTransitioning = true
        isBridgeRunning = false
        isBypassed = false
        meterModel.meter = DSPMeter()
        routeState.statusMessage = "Turning enhancement off..."

        audioControlQueue.async { [bridge, routeManager] in
            bridge.stop()
            try? routeManager.restorePreviousSystemOutput()
            DispatchQueue.main.async { [weak self] in
                self?.refreshRoute()
                self?.isTransitioning = false
                self?.routeRecoveryTask?.cancel()
            }
        }
    }

    func stopBridgeImmediately() {
        bridge.stop()
        try? routeManager.restorePreviousSystemOutput()
        isBridgeRunning = false
        isBypassed = false
        isTransitioning = false
        meterModel.meter = DSPMeter()
        routeRecoveryTask?.cancel()
        refreshRoute()
    }

    func installVirtualDevice() {
        do {
            try routeManager.installVirtualOutputDevice()
            refreshRoute()
            routeState.statusMessage = "Installed SonicBloom Output. Waiting for Core Audio..."
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                refreshRoute()
            }
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    func uninstallVirtualDevice() {
        stopBridgeImmediately()
        do {
            try routeManager.uninstallVirtualOutputDevice()
            refreshRoute()
            routeState.statusMessage = "Uninstalled SonicBloom Output. Waiting for Core Audio..."
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    func startIfAutoEnhanceEnabled() {
        guard settings.autoEnhanceOnLaunch, !isBridgeRunning, !isTransitioning else { return }
        refreshRoute()
        guard routeState.isProcessingAvailable else { return }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 750_000_000)
            if settings.autoEnhanceOnLaunch, !isBridgeRunning, !isTransitioning {
                startBridge()
            }
        }
    }

    func selectPreset(_ preset: DSPPreset) {
        selectedPreset = preset
        try? routeManager.handle(.setPreset(preset))
    }

    func useCurrentOutputAsPreferred() {
        refreshRoute()
        profile.preferredOutputName = routeState.selectedPhysicalOutputName
        rememberSelectedPresetForCurrentOutput()
    }

    func applyCalibration(_ tuning: CalibrationTuning) {
        let tuned = tuning.applying(to: selectedPreset)
        selectedPreset = tuned
        profile.favoritePresetName = tuned.name
        profile.remember(tuned, for: routeState.selectedPhysicalOutputName)
    }

    func applyHeadphoneProfile(_ headphoneProfile: HeadphoneProfile) {
        let tuned = headphoneProfile.applying(to: selectedPreset).with(name: DSPPreset.manual.name)
        selectedPreset = tuned
        profile.favoritePresetName = tuned.name
        profile.remember(tuned, for: routeState.selectedPhysicalOutputName)
    }

    var suggestedCalibrationTuning: CalibrationTuning {
        CalibrationTuning.recommended(for: routeState.selectedPhysicalOutputName)
    }

    var matchedOutputProfile: HeadphoneProfile? {
        HeadphoneProfileCatalog.match(for: routeState.selectedPhysicalOutputName)
    }

    func playCalibrationSound(_ sound: CalibrationSound) {
        calibrationTonePlayer.play(sound)
    }

    func refreshAppMixerRules() {
        appMixerRules = Self.discoveredAppRules(profile: profile)
    }

    func setAppRuleGain(_ rule: AppAudioRule, gainDB: Double) {
        profile.upsert(AppAudioRule(
            bundleIdentifier: rule.bundleIdentifier,
            displayName: rule.displayName,
            gainDB: gainDB,
            isMuted: rule.isMuted,
            presetName: rule.presetName,
            syncMode: rule.syncMode
        ))
        refreshAppMixerRules()
    }

    func toggleAppRuleMute(_ rule: AppAudioRule) {
        profile.upsert(AppAudioRule(
            bundleIdentifier: rule.bundleIdentifier,
            displayName: rule.displayName,
            gainDB: rule.gainDB,
            isMuted: !rule.isMuted,
            presetName: rule.presetName,
            syncMode: rule.syncMode
        ))
        refreshAppMixerRules()
    }

    func setAppRulePreset(_ rule: AppAudioRule, presetName: String?) {
        profile.upsert(AppAudioRule(
            bundleIdentifier: rule.bundleIdentifier,
            displayName: rule.displayName,
            gainDB: rule.gainDB,
            isMuted: rule.isMuted,
            presetName: presetName,
            syncMode: rule.syncMode
        ))
        refreshAppMixerRules()
    }

    func setAppRuleSyncMode(_ rule: AppAudioRule, syncMode: AudioSyncMode?) {
        profile.upsert(AppAudioRule(
            bundleIdentifier: rule.bundleIdentifier,
            displayName: rule.displayName,
            gainDB: rule.gainDB,
            isMuted: rule.isMuted,
            presetName: rule.presetName,
            syncMode: syncMode
        ))
        refreshAppMixerRules()
    }

    var deviceProfileSummary: String {
        guard let outputName = routeState.selectedPhysicalOutputName, !outputName.isEmpty else { return "No output" }
        let source = profile.preset(for: outputName) != nil ? "Saved" : (DeviceProfileAdvisor.preset(for: outputName) != nil ? "Suggested" : "Using")
        return "\(source): \(selectedPreset.name)"
    }

    var trustDiagnostics: [TrustDiagnostic] {
        [
            TrustDiagnostic(title: "Driver", value: routeState.installHealth.rawValue, tint: routeState.isProcessingAvailable ? .green : .orange),
            TrustDiagnostic(title: "Output", value: routeState.selectedPhysicalOutputName ?? "No output", tint: routeState.selectedPhysicalOutputName == nil ? .orange : .blue),
            TrustDiagnostic(title: "Latency", value: String(format: "%.1f ms", routeState.estimatedLatencyMS), tint: .green),
            TrustDiagnostic(title: "Buffer", value: "\(routeState.bufferSize) frames", tint: .blue),
            TrustDiagnostic(title: "App", value: activeAppRule?.displayName ?? "Global", tint: activeAppRule == nil ? .blue : .green),
            TrustDiagnostic(title: "CPU", value: String(format: "%.1f%%", cpuUsagePercent), tint: cpuUsagePercent > 15 ? .orange : .green),
            TrustDiagnostic(title: "Content", value: smartContentProfile.rawValue.capitalized, tint: settings.smartPresetMatching ? .green : .blue),
            TrustDiagnostic(title: "Clips", value: "\(meterModel.meter.limitedSamples) protected", tint: meterModel.meter.limitedSamples > 0 ? .orange : .green),
            TrustDiagnostic(title: "Recovery", value: routeState.recoverySummary, tint: lastError == nil ? .green : .orange)
        ]
    }

    var trustSummary: TrustSummary {
        TrustSummaryBuilder.build(
            routeState: routeState,
            meter: meterModel.meter,
            cpuUsagePercent: cpuUsagePercent,
            lastError: lastError
        )
    }

    func resetSettings() {
        settings = .default
    }

    private func save<T: Encodable>(_ value: T, forKey key: String) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        defaults.set(data, forKey: key)
    }

    private var processingPreset: DSPPreset {
        profile.effectivePreset(
            basePreset: selectedPreset,
            for: foregroundAppBundleIdentifier,
            catalog: presets
        )
        .optimized(for: processingSyncMode)
    }

    private var processingSyncMode: AudioSyncMode {
        profile.effectiveSyncMode(
            for: foregroundAppBundleIdentifier,
            default: settings.syncMode,
            contentProfile: smartContentProfile
        )
    }

    private func updateBridgePreset() {
        bridge.update(preset: processingPreset, bypass: isBypassed, loudnessMatchedBypass: settings.loudnessMatchedCompare)
    }

    private func handleMeter(_ meter: DSPMeter) {
        meterModel.meter = meter
        let oldSyncMode = processingSyncMode
        smartContentProfile = SmartPresetAdvisor.profile(for: meter)
        if oldSyncMode != processingSyncMode {
            routeState.bufferSize = Int(processingSyncMode.preferredBufferFrameSize)
            if isBridgeRunning, !isTransitioning {
                startBridge()
                return
            }
        }
        guard settings.smartPresetMatching,
              isBridgeRunning,
              !isBypassed,
              selectedPreset.name != DSPPreset.manual.name,
              let suggested = smartPresetStabilizer.observe(smartContentProfile),
              suggested.name != selectedPreset.name else { return }

        isApplyingSmartPreset = true
        selectedPreset = suggested
        isApplyingSmartPreset = false
        routeState.statusMessage = "Smart preset: \(suggested.name)"
    }

    private func applyDevicePresetIfNeeded() {
        let outputName = routeState.selectedPhysicalOutputName
        guard outputName != activeProfileOutputName else { return }
        activeProfileOutputName = outputName
        isApplyingDevicePreset = true
        selectedPreset = presetForOutput(outputName)
        isApplyingDevicePreset = false
    }

    private func rememberSelectedPresetForCurrentOutput() {
        guard !isApplyingDevicePreset, !isApplyingSmartPreset else { return }
        profile.favoritePresetName = selectedPreset.name
        profile.remember(selectedPreset, for: routeState.selectedPhysicalOutputName)
    }

    private func favoritePreset() -> DSPPreset {
        presets.first(where: { $0.name == profile.favoritePresetName }) ?? .cleanLoud
    }

    private func presetForOutput(_ outputName: String?) -> DSPPreset {
        profile.preset(for: outputName) ?? DeviceProfileAdvisor.calibratedPreset(for: outputName) ?? favoritePreset()
    }

    private func startAppActivationObserver() {
        appActivationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            Task { @MainActor in
                self?.refreshForegroundApplication(app)
            }
        }
    }

    private func refreshForegroundApplication(_ app: NSRunningApplication? = NSWorkspace.shared.frontmostApplication) {
        guard let bundleIdentifier = app?.bundleIdentifier,
              bundleIdentifier != Bundle.main.bundleIdentifier else { return }
        let oldSyncMode = processingSyncMode
        foregroundAppBundleIdentifier = bundleIdentifier
        activeAppRule = profile.effectiveAppRule(for: bundleIdentifier)
        if oldSyncMode != processingSyncMode {
            routeState.bufferSize = Int(processingSyncMode.preferredBufferFrameSize)
            if isBridgeRunning, !isTransitioning {
                startBridge()
                return
            }
        }
        updateBridgePreset()
    }

    private static func discoveredAppRules(profile: SonicBloomProfile) -> [AppAudioRule] {
        var rules = profile.appRules
        for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular {
            guard let bundleIdentifier = app.bundleIdentifier,
                  bundleIdentifier != Bundle.main.bundleIdentifier else { continue }
            let displayName = app.localizedName ?? bundleIdentifier
            let rule = profile.appRule(for: bundleIdentifier) ?? AppAudioRuleAdvisor.rule(for: bundleIdentifier, displayName: displayName)
            rules[bundleIdentifier] = AppAudioRule(
                bundleIdentifier: bundleIdentifier,
                displayName: displayName,
                gainDB: rule?.gainDB ?? 0,
                isMuted: rule?.isMuted ?? false,
                presetName: rule?.presetName,
                syncMode: rule?.syncMode
            )
        }
        return rules.values.sorted {
            ($0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending)
        }
    }

    private func startCPURefresh() {
        cpuRefreshTask = Task { @MainActor [weak self] in
            guard let self else { return }
            _ = self.cpuSampler.sample()
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                self.cpuUsagePercent = self.cpuSampler.sample()
            }
        }
    }

    private func startRouteRecoveryWatchdog() {
        routeRecoveryTask?.cancel()
        routeRecoveryTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                guard let self, self.isBridgeRunning, !self.isTransitioning else { continue }
                self.refreshRoute()
            }
        }
    }

    private static func load<T: Decodable>(_ type: T.Type, from defaults: UserDefaults, key: String) -> T? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }
}

private enum DefaultsKey {
    static let profile = "sonicbloom.profile"
    static let settings = "sonicbloom.settings"
}

private final class CalibrationTonePlayer {
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!

    init() {
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)
    }

    func play(_ sound: CalibrationSound) {
        let frameCount = AVAudioFrameCount(48_000)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount),
              let data = buffer.floatChannelData?[0] else { return }
        buffer.frameLength = frameCount
        var seed: UInt32 = 0x51A7
        for frame in 0..<Int(frameCount) {
            let t = Double(frame) / format.sampleRate
            let fade = min(1, min(t * 12, (1 - t) * 12))
            switch sound {
            case .tone:
                data[frame] = Float(sin(2 * Double.pi * 440 * t) * 0.18 * fade)
            case .noise:
                seed = 1_664_525 &* seed &+ 1_013_904_223
                let noise = Double(seed % 20_000) / 10_000 - 1
                data[frame] = Float(noise * 0.10 * fade)
            }
        }
        if !engine.isRunning {
            try? engine.start()
        }
        player.stop()
        player.scheduleBuffer(buffer, at: nil, options: .interrupts)
        player.play()
    }
}
