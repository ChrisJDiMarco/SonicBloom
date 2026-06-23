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

private let defaultUpdateFeedURL = URL(string: "https://github.com/ChrisJDiMarco/SonicBloom/releases/latest/download/SonicBloom-update.json")!
typealias UpdateManifestLoader = (URL) async throws -> SonicBloomUpdateManifest
typealias UpdatePackageDownloader = (URL) async throws -> Data
typealias AudioUnitEffectLoader = () -> [AudioUnitEffectDescriptor]
typealias AudioUnitEffectPreflight = (AudioUnitEffectDescriptor) -> Bool

func fetchUpdateManifest(from url: URL) async throws -> SonicBloomUpdateManifest {
    let (data, _) = try await URLSession.shared.data(from: url)
    return try JSONDecoder().decode(SonicBloomUpdateManifest.self, from: data)
}

func fetchUpdatePackage(from url: URL) async throws -> Data {
    let (data, _) = try await URLSession.shared.data(from: url)
    return data
}

private extension JSONEncoder {
    static var prettyPresetShare: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}

@MainActor
final class SonicBloomViewModel: ObservableObject {
    let routeManager = CoreAudioRouteManager()
    private let bridge = SonicBloomAudioBridge()
    private let perAppTapCoordinator = PerAppTapCoordinator()
    private let audioProcessInventory = CoreAudioProcessInventory()
    private lazy var calibrationTonePlayer = CalibrationTonePlayer()
    private let audioControlQueue = DispatchQueue(label: "com.chrisdimarco.sonicbloom.audio-control")
    private let defaults: UserDefaults
    private let currentVersion: String
    private let updateFeedURL: URL
    private let updateManifestLoader: UpdateManifestLoader
    private let updatePackageDownloader: UpdatePackageDownloader
    private let updatePackageDirectory: URL
    private let audioUnitEffectLoader: AudioUnitEffectLoader
    private let audioUnitEffectPreflight: AudioUnitEffectPreflight
    private let presetStore: PresetStore
    private var cpuSampler = ProcessCPUUsageSampler()
    private var cpuRefreshTask: Task<Void, Never>?
    private var routeRecoveryTask: Task<Void, Never>?
    private var appActivationObserver: NSObjectProtocol?
    private var activeProfileOutputName: String?
    private var presetUndoState = PresetUndoState()
    private let liveContextEnabled: Bool
    private var isApplyingDevicePreset = false
    private var isRememberingSelectedPreset = false
#if DEBUG
    var profileAudioRefreshCountForTesting = 0
#endif
    let meterModel = SonicBloomMeterModel()
    @Published private(set) var customPresets: [DSPPreset] = []
    var presets: [DSPPreset] {
        PresetCatalog.builtIns + customPresets
    }
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
    @Published private(set) var hasPlayedSetupTestSound = false
    @Published private(set) var isCheckingForUpdates = false
    @Published private(set) var isDownloadingUpdate = false
    @Published private(set) var updateStatusText = "Updates not checked"
    @Published private(set) var updateDownloadURL: URL?
    @Published private(set) var verifiedUpdatePackageURL: URL?
    @Published private(set) var availableAudioUnitEffects: [AudioUnitEffectDescriptor] = []
    private var availableUpdateManifest: SonicBloomUpdateManifest?

    init(
        defaults: UserDefaults = .standard,
        routeState initialRouteState: AudioRouteState? = nil,
        startLiveContext: Bool = true,
        currentVersion: String? = nil,
        updateFeedURL: URL = defaultUpdateFeedURL,
        updateManifestLoader: @escaping UpdateManifestLoader = fetchUpdateManifest,
        updatePackageDownloader: @escaping UpdatePackageDownloader = fetchUpdatePackage,
        updatePackageDirectory: URL = FileManager.default.temporaryDirectory,
        audioUnitEffectLoader: @escaping AudioUnitEffectLoader = AudioUnitEffectCatalog.installedEffects,
        audioUnitEffectPreflight: @escaping AudioUnitEffectPreflight = AudioUnitEffectHostPreflight().canLoad,
        presetStore: PresetStore = PresetStore()
    ) {
        self.defaults = defaults
        self.currentVersion = currentVersion ?? (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1.0")
        self.updateFeedURL = updateFeedURL
        self.updateManifestLoader = updateManifestLoader
        self.updatePackageDownloader = updatePackageDownloader
        self.updatePackageDirectory = updatePackageDirectory
        self.audioUnitEffectLoader = audioUnitEffectLoader
        self.audioUnitEffectPreflight = audioUnitEffectPreflight
        self.presetStore = presetStore
        liveContextEnabled = startLiveContext
        profile = Self.load(SonicBloomProfile.self, from: defaults, key: DefaultsKey.profile) ?? .default
        settings = Self.load(SonicBloomSettings.self, from: defaults, key: DefaultsKey.settings) ?? .default
        routeState = initialRouteState ?? routeManager.currentState()
        activeProfileOutputName = routeState.selectedPhysicalOutputName
        selectedPreset = presetForOutput(routeState.selectedPhysicalOutputName)
        availableAudioUnitEffects = audioUnitEffectLoader()
        customPresets = (try? presetStore.loadCustomPresets()) ?? []
        bridge.meterHandler = { [weak self] meter in
            Task { @MainActor in
                self?.handleMeter(meter)
            }
        }
        if startLiveContext {
            refreshAppMixerRules()
            refreshForegroundApplication()
            startAppActivationObserver()
            startCPURefresh()
        }
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

    func toggleRawCompare() {
        guard isBridgeRunning, !isTransitioning else { return }
        isBypassed.toggle()
    }

    func checkForUpdates() async {
        guard !isCheckingForUpdates else { return }
        isCheckingForUpdates = true
        updateStatusText = "Checking for updates..."
        updateDownloadURL = nil
        verifiedUpdatePackageURL = nil
        availableUpdateManifest = nil
        defer { isCheckingForUpdates = false }

        do {
            let manifest = try await updateManifestLoader(updateFeedURL)
            switch SonicBloomUpdater.decision(currentVersion: currentVersion, manifest: manifest) {
            case .updateAvailable(let manifest):
                updateStatusText = "Update \(manifest.version) available"
                updateDownloadURL = manifest.packageURL
                availableUpdateManifest = manifest
            case .invalidVersion:
                updateStatusText = "Update version invalid"
            case .unsupported(let manifest):
                updateStatusText = "Update \(manifest.version) requires macOS \(manifest.minimumSystemVersion)"
            case .insecurePackageURL:
                updateStatusText = "Update package URL must use HTTPS"
            case .invalidPackageURL:
                updateStatusText = "Update package must be a .pkg installer"
            case .missingChecksum:
                updateStatusText = "Update package checksum missing"
            case .invalidChecksum:
                updateStatusText = "Update package checksum invalid"
            case .upToDate:
                updateStatusText = "SonicBloom is up to date"
            }
        } catch {
            updateStatusText = "Could not check for updates"
        }
    }

    func downloadVerifiedUpdate() async {
        guard let manifest = availableUpdateManifest, !isDownloadingUpdate else { return }
        isDownloadingUpdate = true
        updateStatusText = "Downloading update..."
        verifiedUpdatePackageURL = nil
        defer { isDownloadingUpdate = false }

        do {
            let data = try await updatePackageDownloader(manifest.packageURL)
            guard SonicBloomUpdatePackageVerifier.verify(data, expectedSHA256: manifest.packageSHA256) else {
                updateStatusText = "Update checksum failed"
                return
            }
            try FileManager.default.createDirectory(at: updatePackageDirectory, withIntermediateDirectories: true)
            let localURL = updatePackageDirectory.appendingPathComponent(
                SonicBloomUpdatePackageVerifier.safePackageFilename(version: manifest.version)
            )
            try data.write(to: localURL, options: .atomic)
            verifiedUpdatePackageURL = localURL
            updateStatusText = "Update package verified"
        } catch {
            updateStatusText = "Could not download update"
        }
    }

    func openUpdateDownload() {
        guard let url = verifiedUpdatePackageURL else { return }
        NSWorkspace.shared.open(url)
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
        presetUndoState.clear()
        selectedPreset = preset
        try? routeManager.handle(.setPreset(preset))
    }

    var canUndoPresetChange: Bool {
        presetUndoState.canUndo
    }

    func editSelectedPreset(_ preset: DSPPreset) {
        guard preset != selectedPreset else { return }
        presetUndoState.captureIfNeeded(selectedPreset)
        selectedPreset = preset
    }

    func undoPresetChange() {
        guard let preset = presetUndoState.undo(current: selectedPreset) else { return }
        selectedPreset = preset
    }

    func saveSelectedPresetAsCustom() throws {
        try presetStore.saveCustomPreset(selectedPreset)
        customPresets = try presetStore.loadCustomPresets()
    }

    func importPreset(from data: Data) throws {
        let preset = try presetStore.importPreset(from: data)
        customPresets = try presetStore.loadCustomPresets()
        selectPreset(preset)
    }

    func exportSelectedPresetData() throws -> Data {
        try JSONEncoder.prettyPresetShare.encode(PresetShareDocument(preset: selectedPreset))
    }

    func saveSelectedPresetAsCustomFromPanel() {
        do {
            try saveSelectedPresetAsCustom()
            lastError = nil
            routeState.statusMessage = "Saved preset: \(selectedPreset.name)"
        } catch {
            lastError = error.localizedDescription
        }
    }

    func importPresetFromPanel() {
        let panel = NSOpenPanel()
        panel.title = "Import SonicBloom Preset"
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            try importPreset(from: Data(contentsOf: url))
            lastError = nil
            routeState.statusMessage = "Imported preset: \(selectedPreset.name)"
        } catch {
            lastError = error.localizedDescription
        }
    }

    func exportSelectedPresetFromPanel() {
        let panel = NSSavePanel()
        panel.title = "Export SonicBloom Preset"
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "\(selectedPreset.name.replacingOccurrences(of: "/", with: "-")).sonicbloom-preset.json"
        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            try exportSelectedPresetData().write(to: url, options: .atomic)
            lastError = nil
            routeState.statusMessage = "Exported preset: \(selectedPreset.name)"
        } catch {
            lastError = error.localizedDescription
        }
    }

    func useCurrentOutputAsPreferred() {
        refreshRoute()
        profile.preferredOutputName = routeState.selectedPhysicalOutputName
        rememberSelectedPresetForCurrentOutput()
    }

    func applyCalibration(_ tuning: CalibrationTuning) {
        let tuned = tuning.applying(to: selectedPreset)
        editSelectedPreset(tuned)
        profile.favoritePresetName = tuned.name
        profile.remember(tuned, for: routeState.selectedPhysicalOutputName)
    }

    func applyHeadphoneProfile(_ headphoneProfile: HeadphoneProfile) {
        let tuned = headphoneProfile.applying(to: selectedPreset).with(name: DSPPreset.manual.name)
        editSelectedPreset(tuned)
        profile.favoritePresetName = tuned.name
        profile.remember(tuned, for: routeState.selectedPhysicalOutputName)
    }

    func importAutoEQProfile(name: String, manufacturer: String = "Imported", text: String) throws {
        let headphoneProfile = try AutoEQProfileImporter.profile(name: name, manufacturer: manufacturer, text: text)
        profile.addCustomHeadphoneProfile(headphoneProfile)
        applyHeadphoneProfile(headphoneProfile)
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

    func addAudioUnitEffect(_ effect: AudioUnitEffectDescriptor) {
        guard audioUnitEffectPreflight(effect) else {
            lastError = "\(effect.name) could not be loaded as an Audio Unit effect."
            return
        }
        lastError = nil
        profile.addAudioUnitEffect(AudioUnitEffectSlot(effect: effect))
    }

    func refreshAudioUnitEffects() {
        availableAudioUnitEffects = audioUnitEffectLoader()
    }

    func removeAudioUnitEffect(_ id: String) {
        profile.removeAudioUnitEffect(id)
    }

    func setAudioUnitEffectEnabled(_ id: String, _ isEnabled: Bool) {
        profile.setAudioUnitEffectEnabled(id, isEnabled)
    }

    var suggestedCalibrationTuning: CalibrationTuning {
        CalibrationTuning.recommended(for: routeState.selectedPhysicalOutputName)
    }

    var matchedOutputProfile: HeadphoneProfile? {
        HeadphoneProfileCatalog.match(for: routeState.selectedPhysicalOutputName)
    }

    var availableHeadphoneProfiles: [HeadphoneProfile] {
        HeadphoneProfileCatalog.builtIns + profile.customHeadphoneProfiles
    }

    func removeCustomHeadphoneProfile(_ id: String) {
        profile.removeCustomHeadphoneProfile(id)
    }

    func playCalibrationSound(_ sound: CalibrationSound) {
        hasPlayedSetupTestSound = true
        calibrationTonePlayer.play(sound)
    }

    func refreshAppMixerRules() {
        guard liveContextEnabled else { return }
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

    var setupGuideSteps: [FirstRunSetupStep] {
        FirstRunSetupGuide.steps(
            routeState: routeState,
            isBridgeRunning: isBridgeRunning,
            hasPlayedTestSound: hasPlayedSetupTestSound
        )
    }

    var isSetupGuideComplete: Bool {
        FirstRunSetupGuide.isComplete(setupGuideSteps)
    }

    func runSetupGuideAction(_ stepID: FirstRunSetupStepID) {
        switch stepID {
        case .installDriver:
            installVirtualDevice()
        case .chooseOutput:
            useCurrentOutputAsPreferred()
        case .testSound:
            playCalibrationSound(.tone)
        case .turnOnEnhancement:
            guard routeState.isProcessingAvailable, !isBridgeRunning else { return }
            startBridge()
        }
    }

    var trustSummary: TrustSummary {
        TrustSummaryBuilder.build(
            routeState: routeState,
            meter: meterModel.meter,
            cpuUsagePercent: cpuUsagePercent,
            lastError: lastError
        )
    }

    var diagnosticsReport: String {
        SonicBloomDiagnosticsReport.build(
            routeState: routeState,
            meter: meterModel.meter,
            cpuUsagePercent: cpuUsagePercent,
            selectedPresetName: selectedPreset.name,
            syncMode: processingSyncMode,
            settings: settings,
            lastError: lastError
        )
    }

    func copyDiagnosticsReport() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(diagnosticsReport, forType: .string)
        routeState.statusMessage = "Copied diagnostics to clipboard."
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
        presetUndoState.clear()
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
