@preconcurrency import AppKit
import AVFoundation
import Foundation
import SonicBloomCore
import UniformTypeIdentifiers

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
    private let perAppTapCoordinator = PerAppTapCoordinator()
    private let audioProcessInventory = CoreAudioProcessInventory()
    private let calibrationTonePlayer = CalibrationTonePlayer()
    private let audioControlQueue = DispatchQueue(label: "com.chrisdimarco.sonicbloom.audio-control")
    private let defaults: UserDefaults
    private var cpuSampler = ProcessCPUUsageSampler()
    private var cpuRefreshTask: Task<Void, Never>?
    private var routeRecoveryTask: Task<Void, Never>?
    private var appActivationObserver: NSObjectProtocol?
    private var activeProfileOutputName: String?
    private var isApplyingDevicePreset = false
    private var isRememberingSelectedPreset = false
#if DEBUG
    var profileAudioRefreshCountForTesting = 0
#endif
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
            guard !isRememberingSelectedPreset else { return }
#if DEBUG
            profileAudioRefreshCountForTesting += 1
#endif
            refreshAppMixerRules()
            activeAppRule = profile.effectiveAppRule(for: foregroundAppBundleIdentifier)
            updateBridgePreset()
            restartPerAppTapsIfRunning()
        }
    }
    @Published var settings: SonicBloomSettings {
        didSet {
            save(settings, forKey: DefaultsKey.settings)
            if oldValue.syncMode != settings.syncMode {
                routeState.bufferSize = Int(processingSyncMode.preferredBufferFrameSize)
                if isBridgeRunning, !isTransitioning {
                    startBridge()
                    return
                }
            }
            updateBridgePreset()
            restartPerAppTapsIfRunning()
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
    @Published private(set) var appMixerItems: [AppMixerItem] = []
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
            lastError = nil
            startPerAppTaps(sampleRate: selection.output.sampleRate)
            startRouteRecoveryWatchdog()
        } catch {
            perAppTapCoordinator.stop()
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
        isBypassed = false
        meterModel.meter = DSPMeter()
        routeState.statusMessage = "Restoring Mac output..."
        perAppTapCoordinator.stop()

        audioControlQueue.async { [bridge, routeManager] in
            do {
                try routeManager.restorePreviousSystemOutput()
                bridge.stop()
                DispatchQueue.main.async { [weak self] in
                    self?.isBridgeRunning = false
                    self?.refreshRoute()
                    self?.isTransitioning = false
                    self?.routeRecoveryTask?.cancel()
                }
            } catch {
                DispatchQueue.main.async { [weak self] in
                    self?.lastError = error.localizedDescription
                    self?.routeState.statusMessage = "Could not restore Mac output; keeping enhancement on."
                    self?.isTransitioning = false
                }
            }
        }
    }

    func stopBridgeImmediately() {
        perAppTapCoordinator.stop()
        try? routeManager.restorePreviousSystemOutput()
        bridge.stop()
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

    func importAutoEQProfile(name: String, manufacturer: String = "Imported", text: String) throws {
        applyHeadphoneProfile(try AutoEQProfileImporter.profile(name: name, manufacturer: manufacturer, text: text))
    }

    func importAutoEQProfileFromPanel() {
        let panel = NSOpenPanel()
        panel.title = "Import AutoEQ Profile"
        panel.allowedContentTypes = [.plainText, .commaSeparatedText]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            let text = try String(contentsOf: url, encoding: .utf8)
            try importAutoEQProfile(name: url.deletingPathExtension().lastPathComponent, text: text)
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
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
        appMixerItems = Self.discoveredAppMixerItems(
            profile: profile,
            audioProcesses: audioProcessInventory.processes(),
            currentBundleIdentifier: Bundle.main.bundleIdentifier
        )
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
            TrustDiagnostic(title: "Content", value: smartContentProfile.rawValue.capitalized, tint: .blue),
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

#if DEBUG
    var processingPresetForTesting: DSPPreset {
        processingPreset
    }

    var processingSyncModeForTesting: AudioSyncMode {
        processingSyncMode
    }

    func setForegroundAppBundleIdentifierForTesting(_ bundleIdentifier: String?) {
        foregroundAppBundleIdentifier = bundleIdentifier
        activeAppRule = profile.effectiveAppRule(for: bundleIdentifier)
    }

    func handleMeterForTesting(_ meter: DSPMeter) {
        handleMeter(meter)
    }

#endif

    private func save<T: Encodable>(_ value: T, forKey key: String) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        defaults.set(data, forKey: key)
    }

    private var processingPreset: DSPPreset {
        guard settings.applyAppProfilesAutomatically else {
            return selectedPreset.optimized(for: processingSyncMode)
        }
        guard let rule = profile.appRule(for: foregroundAppBundleIdentifier) else {
            return selectedPreset.optimized(for: processingSyncMode)
        }
        let preset = rule.presetName.flatMap { name in presets.first { $0.name == name } } ?? selectedPreset
        let gain = rule.isMuted ? -60 : min(max(preset.outputGainDB + rule.gainDB, -60), 12)
        return preset.with(outputGainDB: gain).optimized(for: rule.syncMode ?? processingSyncMode)
    }

    private var processingSyncMode: AudioSyncMode {
        settings.syncMode == .auto ? .video : settings.syncMode
    }

    private func updateBridgePreset() {
        bridge.update(preset: processingPreset, bypass: isBypassed, loudnessMatchedBypass: settings.loudnessMatchedCompare)
    }

    private func restartPerAppTapsIfRunning() {
        guard isBridgeRunning, !isTransitioning else { return }
        startPerAppTaps(sampleRate: routeState.sampleRate)
    }

    private func startPerAppTaps(sampleRate _: Double) {
        perAppTapCoordinator.stop()
        // ponytail: process taps destabilize the master route; App Profiles stay foreground-only until real taps are worth the risk.
        refreshAppMixerRules()
    }

    private func handleMeter(_ meter: DSPMeter) {
        meterModel.meter = meter
        smartContentProfile = SmartPresetAdvisor.profile(for: meter)
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
        guard !isApplyingDevicePreset else { return }
        isRememberingSelectedPreset = true
        defer { isRememberingSelectedPreset = false }
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
        foregroundAppBundleIdentifier = bundleIdentifier
        activeAppRule = profile.effectiveAppRule(for: bundleIdentifier)
        updateBridgePreset()
    }

    private static func discoveredAppMixerItems(
        profile: SonicBloomProfile,
        audioProcesses: [AudioProcessSnapshot],
        currentBundleIdentifier: String?
    ) -> [AppMixerItem] {
        let runningApps = NSWorkspace.shared.runningApplications.compactMap { app -> RunningAppSnapshot? in
            guard app.activationPolicy == .regular,
                  let bundleIdentifier = app.bundleIdentifier,
                  bundleIdentifier != currentBundleIdentifier else { return nil }
            return RunningAppSnapshot(
                bundleIdentifier: bundleIdentifier,
                displayName: app.localizedName ?? bundleIdentifier,
                processID: app.processIdentifier
            )
        }
        return AppMixerPlanner.items(
            savedRules: profile.appRules,
            runningApps: runningApps,
            audioProcesses: audioProcesses,
            currentBundleIdentifier: currentBundleIdentifier
        )
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
