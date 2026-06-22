import Foundation

public struct StereoFrame: Codable, Equatable, Sendable {
    public var left: Float
    public var right: Float

    public init(left: Float, right: Float) {
        self.left = left
        self.right = right
    }
}

public struct DSPMeter: Codable, Equatable, Sendable {
    public var inputPeak: Float
    public var outputPeak: Float
    public var gainReductionDB: Float
    public var lowEnergy: Float
    public var midEnergy: Float
    public var highEnergy: Float
    public var spectrumBands: [Float]
    public var limitedSamples: UInt32

    public init(
        inputPeak: Float = 0,
        outputPeak: Float = 0,
        gainReductionDB: Float = 0,
        lowEnergy: Float = 0,
        midEnergy: Float = 0,
        highEnergy: Float = 0,
        spectrumBands: [Float] = Array(repeating: 0, count: DSPPreset.bandCount),
        limitedSamples: UInt32 = 0
    ) {
        self.inputPeak = inputPeak
        self.outputPeak = outputPeak
        self.gainReductionDB = gainReductionDB
        self.lowEnergy = lowEnergy
        self.midEnergy = midEnergy
        self.highEnergy = highEnergy
        var normalizedSpectrum = Array(spectrumBands.prefix(DSPPreset.bandCount))
        if normalizedSpectrum.count < DSPPreset.bandCount {
            normalizedSpectrum.append(contentsOf: repeatElement(0, count: DSPPreset.bandCount - normalizedSpectrum.count))
        }
        self.spectrumBands = normalizedSpectrum
        self.limitedSamples = limitedSamples
    }
}

public enum ListeningMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case everyday = "Everyday"
    case music = "Music"
    case movies = "Movies"
    case focus = "Focus"
    case night = "Night"

    public var id: String { rawValue }
}

public enum AudioSyncMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case auto = "Auto"
    case music = "Music"
    case video = "Video"
    case gaming = "Gaming"

    public var id: String { rawValue }

    public var preferredBufferFrameSize: UInt32 {
        switch self {
        case .auto: 64
        case .music: 128
        case .video: 64
        case .gaming: 32
        }
    }

    public func maxQueuedOutputFrames(observedCallbackFrames: Int) -> Int {
        max(512, max(observedCallbackFrames, Int(preferredBufferFrameSize) * 4))
    }
}

public enum CalibrationOutputKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case speakers = "Speakers"
    case headphones = "Headphones"
    case airPods = "AirPods"
    case tinySpeakers = "Tiny Speakers"

    public var id: String { rawValue }
}

public struct CalibrationTuning: Codable, Equatable, Sendable {
    public var outputKind: CalibrationOutputKind
    public var bassPreference: Double
    public var clarityPreference: Double
    public var spatialPreference: Double
    public var loudnessPreference: Double

    public init(
        outputKind: CalibrationOutputKind = .speakers,
        bassPreference: Double = 0.5,
        clarityPreference: Double = 0.5,
        spatialPreference: Double = 0.5,
        loudnessPreference: Double = 0.5
    ) {
        self.outputKind = outputKind
        self.bassPreference = Self.clamp01(bassPreference)
        self.clarityPreference = Self.clamp01(clarityPreference)
        self.spatialPreference = Self.clamp01(spatialPreference)
        self.loudnessPreference = Self.clamp01(loudnessPreference)
    }

    public func applying(to preset: DSPPreset) -> DSPPreset {
        var bands = preset.eqBandsDB
        let bassDB = (bassPreference - 0.5) * 4.0 + outputKind.bassEQOffset
        let clarityDB = (clarityPreference - 0.5) * 3.0 + outputKind.clarityEQOffset
        let loudness = 0.08 + loudnessPreference * 0.48
        add(bassDB, to: 4...10, bands: &bands)
        add(clarityDB, to: 17...26, bands: &bands)

        return preset.with(
            name: DSPPreset.manual.name,
            eqBandsDB: bands.map { min(max($0, -12), 12) },
            inputGainDB: min(max(preset.inputGainDB + loudnessPreference * 2.2, -12), 12),
            bassAmount: min(max(outputKind.baseBass + bassPreference * 0.58, 0), 1),
            widthAmount: min(max(outputKind.baseWidth + spatialPreference * outputKind.widthScale, 0), 1),
            spatialAmount: min(max(outputKind.baseSpatial + spatialPreference * outputKind.spatialScale, 0), 1),
            crossfeedAmount: min(max(outputKind.baseCrossfeed, 0), 1),
            loudnessAmount: max(preset.loudnessAmount, loudness),
            fidelityAmount: min(max(outputKind.baseFidelity + clarityPreference * 0.32, 0), 1),
            hrtfAmount: min(max(outputKind.baseHRTF + spatialPreference * outputKind.hrtfScale, 0), 1),
            limiterCeilingDB: min(preset.limiterCeilingDB, -1 - loudnessPreference * 0.4),
            outputGainDB: min(max(preset.outputGainDB + (loudnessPreference - 0.5) * 1.4, -12), 12)
        )
    }

    private func add(_ value: Double, to range: ClosedRange<Int>, bands: inout [Double]) {
        for index in range where bands.indices.contains(index) {
            bands[index] += value
        }
    }

    private static func clamp01(_ value: Double) -> Double {
        min(max(value, 0), 1)
    }

    private enum CodingKeys: String, CodingKey {
        case outputKind, bassPreference, clarityPreference, spatialPreference, loudnessPreference
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            outputKind: try values.decodeIfPresent(CalibrationOutputKind.self, forKey: .outputKind) ?? .speakers,
            bassPreference: try values.decodeIfPresent(Double.self, forKey: .bassPreference) ?? 0.5,
            clarityPreference: try values.decodeIfPresent(Double.self, forKey: .clarityPreference) ?? 0.5,
            spatialPreference: try values.decodeIfPresent(Double.self, forKey: .spatialPreference) ?? 0.5,
            loudnessPreference: try values.decodeIfPresent(Double.self, forKey: .loudnessPreference) ?? 0.5
        )
    }
}

private extension CalibrationOutputKind {
    var baseBass: Double {
        switch self {
        case .speakers: 0.10
        case .headphones: 0.08
        case .airPods: 0.16
        case .tinySpeakers: 0.20
        }
    }

    var baseFidelity: Double {
        switch self {
        case .speakers: 0.08
        case .headphones: 0.10
        case .airPods: 0.12
        case .tinySpeakers: 0.18
        }
    }

    var baseWidth: Double {
        switch self {
        case .speakers: 0.04
        case .headphones: 0.12
        case .airPods: 0.16
        case .tinySpeakers: 0.03
        }
    }

    var widthScale: Double {
        switch self {
        case .speakers: 0.22
        case .headphones: 0.30
        case .airPods: 0.28
        case .tinySpeakers: 0.12
        }
    }

    var baseSpatial: Double {
        switch self {
        case .speakers: 0.04
        case .headphones: 0.08
        case .airPods: 0.16
        case .tinySpeakers: 0.04
        }
    }

    var spatialScale: Double {
        switch self {
        case .speakers: 0.20
        case .headphones: 0.30
        case .airPods: 0.34
        case .tinySpeakers: 0.22
        }
    }

    var baseCrossfeed: Double {
        switch self {
        case .speakers: 0.04
        case .headphones: 0.24
        case .airPods: 0.20
        case .tinySpeakers: 0.06
        }
    }

    var baseHRTF: Double {
        switch self {
        case .speakers: 0.04
        case .headphones: 0.12
        case .airPods: 0.20
        case .tinySpeakers: 0.03
        }
    }

    var hrtfScale: Double {
        switch self {
        case .speakers: 0.14
        case .headphones: 0.24
        case .airPods: 0.28
        case .tinySpeakers: 0.08
        }
    }

    var bassEQOffset: Double {
        self == .tinySpeakers ? 1.0 : 0
    }

    var clarityEQOffset: Double {
        self == .tinySpeakers ? 0.8 : 0
    }
}

public struct AppAudioRule: Codable, Equatable, Identifiable, Sendable {
    public var id: String { bundleIdentifier }
    public var bundleIdentifier: String
    public var displayName: String
    public var gainDB: Double
    public var isMuted: Bool
    public var presetName: String?
    public var syncMode: AudioSyncMode?

    public init(
        bundleIdentifier: String,
        displayName: String,
        gainDB: Double = 0,
        isMuted: Bool = false,
        presetName: String? = nil,
        syncMode: AudioSyncMode? = nil
    ) {
        self.bundleIdentifier = bundleIdentifier
        self.displayName = displayName.isEmpty ? bundleIdentifier : displayName
        self.gainDB = min(max(gainDB, -60), 12)
        self.isMuted = isMuted
        self.presetName = presetName?.isEmpty == false ? presetName : nil
        self.syncMode = syncMode
    }
}

public enum AppAudioRuleAdvisor {
    public static func rule(for bundleIdentifier: String?, displayName: String) -> AppAudioRule? {
        guard let bundleIdentifier, !bundleIdentifier.isEmpty else { return nil }
        let bundle = bundleIdentifier.lowercased()
        if contains(bundle, ["steam", "epicgames", "roblox", "minecraft", "unity"]) {
            return AppAudioRule(bundleIdentifier: bundleIdentifier, displayName: displayName, presetName: DSPPreset.headphones.name, syncMode: .gaming)
        }
        if contains(bundle, ["spotify", "music", "itunes", "tidal", "qobuz", "pandora"]) {
            return AppAudioRule(bundleIdentifier: bundleIdentifier, displayName: displayName, presetName: DSPPreset.cleanLoud.name, syncMode: .music)
        }
        if contains(bundle, ["zoom", "teams", "discord", "facetime"]) {
            return AppAudioRule(bundleIdentifier: bundleIdentifier, displayName: displayName, presetName: DSPPreset.spokenVoice.name, syncMode: .video)
        }
        if contains(bundle, ["chrome", "safari", "firefox", "arc", "youtube", "tv", "quicktime", "vlc", "iina"]) {
            return AppAudioRule(bundleIdentifier: bundleIdentifier, displayName: displayName, presetName: DSPPreset.cleanLoud.name, syncMode: .video)
        }
        if contains(bundle, ["systemuiserver"]) {
            return AppAudioRule(bundleIdentifier: bundleIdentifier, displayName: displayName, gainDB: -6, presetName: DSPPreset.flat.name, syncMode: .video)
        }
        return nil
    }

    private static func contains(_ value: String, _ needles: [String]) -> Bool {
        needles.contains { value.contains($0) }
    }
}

public struct SonicBloomProfile: Codable, Equatable, Sendable {
    public var displayName: String
    public var listeningMode: ListeningMode
    public var favoritePresetName: String
    public var preferredOutputName: String?
    public var devicePresets: [String: DSPPreset]
    public var appRules: [String: AppAudioRule]

    public init(
        displayName: String = "Chris",
        listeningMode: ListeningMode = .everyday,
        favoritePresetName: String = DSPPreset.cleanLoud.name,
        preferredOutputName: String? = nil,
        devicePresets: [String: DSPPreset] = [:],
        appRules: [String: AppAudioRule] = [:]
    ) {
        self.displayName = displayName.isEmpty ? "Chris" : displayName
        self.listeningMode = listeningMode
        self.favoritePresetName = favoritePresetName.isEmpty ? DSPPreset.cleanLoud.name : favoritePresetName
        self.preferredOutputName = preferredOutputName
        self.devicePresets = devicePresets
        self.appRules = appRules
    }

    public static let `default` = SonicBloomProfile()

    public func preset(for outputName: String?) -> DSPPreset? {
        guard let outputName, !outputName.isEmpty else { return nil }
        return devicePresets[outputName]
    }

    public mutating func remember(_ preset: DSPPreset, for outputName: String?) {
        guard let outputName, !outputName.isEmpty else { return }
        devicePresets[outputName] = preset
    }

    public func appRule(for bundleIdentifier: String?) -> AppAudioRule? {
        guard let bundleIdentifier, !bundleIdentifier.isEmpty else { return nil }
        return appRules[bundleIdentifier]
    }

    public func effectiveAppRule(for bundleIdentifier: String?) -> AppAudioRule? {
        appRule(for: bundleIdentifier) ?? AppAudioRuleAdvisor.rule(for: bundleIdentifier, displayName: bundleIdentifier ?? "")
    }

    public func effectivePreset(
        basePreset: DSPPreset,
        for bundleIdentifier: String?,
        catalog: [DSPPreset] = PresetCatalog.builtIns
    ) -> DSPPreset {
        guard let rule = effectiveAppRule(for: bundleIdentifier) else { return basePreset }
        let preset = rule.presetName.flatMap { name in
            catalog.first { $0.name == name }
        } ?? basePreset
        let gain = rule.isMuted ? -60 : min(max(preset.outputGainDB + rule.gainDB, -60), 12)
        return preset.with(outputGainDB: gain)
    }

    public func effectivePreset(
        basePreset: DSPPreset,
        for bundleIdentifier: String?,
        syncMode: AudioSyncMode,
        catalog: [DSPPreset] = PresetCatalog.builtIns
    ) -> DSPPreset {
        effectivePreset(basePreset: basePreset, for: bundleIdentifier, catalog: catalog)
            .optimized(for: effectiveSyncMode(for: bundleIdentifier, default: syncMode))
    }

    public func effectiveSyncMode(for bundleIdentifier: String?, default syncMode: AudioSyncMode) -> AudioSyncMode {
        effectiveAppRule(for: bundleIdentifier)?.syncMode ?? syncMode
    }

    public func effectiveSyncMode(
        for bundleIdentifier: String?,
        default syncMode: AudioSyncMode,
        contentProfile: SmartContentProfile
    ) -> AudioSyncMode {
        SmartSyncAdvisor.syncMode(
            for: effectiveAppRule(for: bundleIdentifier)?.syncMode ?? syncMode,
            bundleIdentifier: bundleIdentifier,
            contentProfile: contentProfile
        )
    }

    public mutating func upsert(_ rule: AppAudioRule) {
        guard !rule.bundleIdentifier.isEmpty else { return }
        appRules[rule.bundleIdentifier] = rule
    }

    public mutating func removeAppRule(for bundleIdentifier: String?) {
        guard let bundleIdentifier, !bundleIdentifier.isEmpty else { return }
        appRules.removeValue(forKey: bundleIdentifier)
    }

    private enum CodingKeys: String, CodingKey {
        case displayName, listeningMode, favoritePresetName, preferredOutputName, devicePresets, appRules
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            displayName: try values.decodeIfPresent(String.self, forKey: .displayName) ?? "Chris",
            listeningMode: try values.decodeIfPresent(ListeningMode.self, forKey: .listeningMode) ?? .everyday,
            favoritePresetName: try values.decodeIfPresent(String.self, forKey: .favoritePresetName) ?? DSPPreset.cleanLoud.name,
            preferredOutputName: try values.decodeIfPresent(String.self, forKey: .preferredOutputName),
            devicePresets: try values.decodeIfPresent([String: DSPPreset].self, forKey: .devicePresets) ?? [:],
            appRules: try values.decodeIfPresent([String: AppAudioRule].self, forKey: .appRules) ?? [:]
        )
    }
}

public struct SonicBloomSettings: Codable, Equatable, Sendable {
    public var autoEnhanceOnLaunch: Bool
    public var reduceMotion: Bool
    public var waveformIntensity: Double
    public var showAdvancedControls: Bool
    public var syncMode: AudioSyncMode
    public var loudnessMatchedCompare: Bool
    public var smartPresetMatching: Bool

    public init(
        autoEnhanceOnLaunch: Bool = false,
        reduceMotion: Bool = false,
        waveformIntensity: Double = 0.72,
        showAdvancedControls: Bool = true,
        syncMode: AudioSyncMode = .auto,
        loudnessMatchedCompare: Bool = true,
        smartPresetMatching: Bool = true
    ) {
        self.autoEnhanceOnLaunch = autoEnhanceOnLaunch
        self.reduceMotion = reduceMotion
        self.waveformIntensity = min(max(waveformIntensity, 0), 1)
        self.showAdvancedControls = showAdvancedControls
        self.syncMode = syncMode
        self.loudnessMatchedCompare = loudnessMatchedCompare
        self.smartPresetMatching = smartPresetMatching
    }

    public static let `default` = SonicBloomSettings()

    private enum CodingKeys: String, CodingKey {
        case autoEnhanceOnLaunch, reduceMotion, waveformIntensity, showAdvancedControls, syncMode, loudnessMatchedCompare, smartPresetMatching
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            autoEnhanceOnLaunch: try values.decodeIfPresent(Bool.self, forKey: .autoEnhanceOnLaunch) ?? false,
            reduceMotion: try values.decodeIfPresent(Bool.self, forKey: .reduceMotion) ?? false,
            waveformIntensity: try values.decodeIfPresent(Double.self, forKey: .waveformIntensity) ?? 0.72,
            showAdvancedControls: try values.decodeIfPresent(Bool.self, forKey: .showAdvancedControls) ?? true,
            syncMode: try values.decodeIfPresent(AudioSyncMode.self, forKey: .syncMode) ?? .music,
            loudnessMatchedCompare: try values.decodeIfPresent(Bool.self, forKey: .loudnessMatchedCompare) ?? true,
            smartPresetMatching: try values.decodeIfPresent(Bool.self, forKey: .smartPresetMatching) ?? false
        )
    }
}

public struct ProcessResult: Equatable, Sendable {
    public var frames: [StereoFrame]
    public var meter: DSPMeter

    public init(frames: [StereoFrame], meter: DSPMeter) {
        self.frames = frames
        self.meter = meter
    }
}

public struct DSPPreset: Codable, Equatable, Identifiable, Sendable {
    public static let bandCount = 31

    public var id: String { name }
    public var name: String
    public var eqBandsDB: [Double]
    public var inputGainDB: Double
    public var bassAmount: Double
    public var widthAmount: Double
    public var spatialAmount: Double
    public var crossfeedAmount: Double
    public var loudnessAmount: Double
    public var ambienceAmount: Double
    public var fidelityAmount: Double
    public var nightModeAmount: Double
    public var hrtfAmount: Double
    public var limiterCeilingDB: Double
    public var limiterLookaheadMS: Double
    public var limiterReleaseMS: Double
    public var outputGainDB: Double

    public var limiterCeilingLinear: Float {
        Float(pow(10.0, limiterCeilingDB / 20.0))
    }

    public init(
        name: String,
        eqBandsDB: [Double] = Array(repeating: 0, count: bandCount),
        inputGainDB: Double = 0,
        bassAmount: Double = 0,
        widthAmount: Double = 0,
        spatialAmount: Double = 0,
        crossfeedAmount: Double = 0,
        loudnessAmount: Double = 0,
        ambienceAmount: Double = 0,
        fidelityAmount: Double = 0,
        nightModeAmount: Double = 0,
        hrtfAmount: Double = 0,
        limiterCeilingDB: Double = -1,
        limiterLookaheadMS: Double = 0.2,
        limiterReleaseMS: Double = 120,
        outputGainDB: Double = 0
    ) {
        self.name = name
        self.eqBandsDB = Self.normalizedBands(eqBandsDB)
        self.inputGainDB = inputGainDB
        self.bassAmount = bassAmount
        self.widthAmount = widthAmount
        self.spatialAmount = spatialAmount
        self.crossfeedAmount = crossfeedAmount
        self.loudnessAmount = loudnessAmount
        self.ambienceAmount = ambienceAmount
        self.fidelityAmount = fidelityAmount
        self.nightModeAmount = nightModeAmount
        self.hrtfAmount = hrtfAmount
        self.limiterCeilingDB = limiterCeilingDB
        self.limiterLookaheadMS = min(max(limiterLookaheadMS, 0.2), 10)
        self.limiterReleaseMS = min(max(limiterReleaseMS, 20), 300)
        self.outputGainDB = outputGainDB
    }

    public func with(
        name: String? = nil,
        eqBandsDB: [Double]? = nil,
        inputGainDB: Double? = nil,
        bassAmount: Double? = nil,
        widthAmount: Double? = nil,
        spatialAmount: Double? = nil,
        crossfeedAmount: Double? = nil,
        loudnessAmount: Double? = nil,
        ambienceAmount: Double? = nil,
        fidelityAmount: Double? = nil,
        nightModeAmount: Double? = nil,
        hrtfAmount: Double? = nil,
        limiterCeilingDB: Double? = nil,
        limiterLookaheadMS: Double? = nil,
        limiterReleaseMS: Double? = nil,
        outputGainDB: Double? = nil
    ) -> DSPPreset {
        DSPPreset(
            name: name ?? self.name,
            eqBandsDB: eqBandsDB ?? self.eqBandsDB,
            inputGainDB: inputGainDB ?? self.inputGainDB,
            bassAmount: bassAmount ?? self.bassAmount,
            widthAmount: widthAmount ?? self.widthAmount,
            spatialAmount: spatialAmount ?? self.spatialAmount,
            crossfeedAmount: crossfeedAmount ?? self.crossfeedAmount,
            loudnessAmount: loudnessAmount ?? self.loudnessAmount,
            ambienceAmount: ambienceAmount ?? self.ambienceAmount,
            fidelityAmount: fidelityAmount ?? self.fidelityAmount,
            nightModeAmount: nightModeAmount ?? self.nightModeAmount,
            hrtfAmount: hrtfAmount ?? self.hrtfAmount,
            limiterCeilingDB: limiterCeilingDB ?? self.limiterCeilingDB,
            limiterLookaheadMS: limiterLookaheadMS ?? self.limiterLookaheadMS,
            limiterReleaseMS: limiterReleaseMS ?? self.limiterReleaseMS,
            outputGainDB: outputGainDB ?? self.outputGainDB
        )
    }

    private static func normalizedBands(_ bands: [Double]) -> [Double] {
        Array((bands + Array(repeating: 0, count: bandCount)).prefix(bandCount))
    }

    private enum CodingKeys: String, CodingKey {
        case name, eqBandsDB, inputGainDB, bassAmount, widthAmount, spatialAmount, crossfeedAmount, loudnessAmount, ambienceAmount, fidelityAmount, nightModeAmount, hrtfAmount, limiterCeilingDB, limiterLookaheadMS, limiterReleaseMS, outputGainDB
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            name: try values.decode(String.self, forKey: .name),
            eqBandsDB: try values.decodeIfPresent([Double].self, forKey: .eqBandsDB) ?? [],
            inputGainDB: try values.decodeIfPresent(Double.self, forKey: .inputGainDB) ?? 0,
            bassAmount: try values.decodeIfPresent(Double.self, forKey: .bassAmount) ?? 0,
            widthAmount: try values.decodeIfPresent(Double.self, forKey: .widthAmount) ?? 0,
            spatialAmount: try values.decodeIfPresent(Double.self, forKey: .spatialAmount) ?? 0,
            crossfeedAmount: try values.decodeIfPresent(Double.self, forKey: .crossfeedAmount) ?? 0,
            loudnessAmount: try values.decodeIfPresent(Double.self, forKey: .loudnessAmount) ?? 0,
            ambienceAmount: try values.decodeIfPresent(Double.self, forKey: .ambienceAmount) ?? 0,
            fidelityAmount: try values.decodeIfPresent(Double.self, forKey: .fidelityAmount) ?? 0,
            nightModeAmount: try values.decodeIfPresent(Double.self, forKey: .nightModeAmount) ?? 0,
            hrtfAmount: try values.decodeIfPresent(Double.self, forKey: .hrtfAmount) ?? 0,
            limiterCeilingDB: try values.decodeIfPresent(Double.self, forKey: .limiterCeilingDB) ?? -1,
            limiterLookaheadMS: try values.decodeIfPresent(Double.self, forKey: .limiterLookaheadMS) ?? 0.2,
            limiterReleaseMS: try values.decodeIfPresent(Double.self, forKey: .limiterReleaseMS) ?? 120,
            outputGainDB: try values.decodeIfPresent(Double.self, forKey: .outputGainDB) ?? 0
        )
    }
}

public extension DSPPreset {
    func optimized(for syncMode: AudioSyncMode) -> DSPPreset {
        switch syncMode {
        case .auto:
            return optimized(for: .video)
        case .music:
            return self
        case .video:
            return with(
                spatialAmount: min(spatialAmount, 0.28),
                ambienceAmount: min(ambienceAmount, 0.08),
                hrtfAmount: min(hrtfAmount, 0.24),
                limiterLookaheadMS: 0.2
            )
        case .gaming:
            return with(
                widthAmount: min(widthAmount, 0.12),
                spatialAmount: 0,
                crossfeedAmount: min(crossfeedAmount, 0.12),
                loudnessAmount: min(loudnessAmount, 0.18),
                ambienceAmount: 0,
                hrtfAmount: 0,
                limiterLookaheadMS: 0.2
            )
        }
    }

    static let flat = DSPPreset(name: "Flat")
    static let cleanLoud = DSPPreset(
        name: "Clean Loud",
        eqBandsDB: [
            0, 0, 0, 0, 0.5, 0.8, 1.0, 0.8,
            0.4, 0, 0, 0, 0, 0, 0,
            0.2, 0.4, 0.6, 0.5, 0.3, 0.2,
            0.4, 0.8, 1.0, 0.8, 0.5, 0.3,
            0.2, 0, 0, 0
        ],
        inputGainDB: 3.5,
        bassAmount: 0.22,
        widthAmount: 0.18,
        spatialAmount: 0.18,
        loudnessAmount: 0.32,
        fidelityAmount: 0.18,
        hrtfAmount: 0.12,
        limiterCeilingDB: -1,
        outputGainDB: 0
    )
    static let deepBass = DSPPreset(
        name: "Deep Bass",
        eqBandsDB: [
            2.8, 3.2, 3.8, 4.2, 4.0, 3.6, 2.8, 2.0,
            1.0, 0.2, -0.4, -0.6, -0.4, 0, 0,
            0, 0, 0.2, 0.3, 0.3, 0.2,
            0.2, 0.4, 0.6, 0.5, 0.3, 0,
            0, 0, 0, 0
        ],
        inputGainDB: 1.5,
        bassAmount: 0.8,
        widthAmount: 0.1,
        spatialAmount: 0.12,
        loudnessAmount: 0.28,
        ambienceAmount: 0.05,
        fidelityAmount: 0.08,
        limiterCeilingDB: -1.2,
        outputGainDB: -1
    )
    static let spokenVoice = DSPPreset(
        name: "Spoken Voice",
        eqBandsDB: [
            -4, -4, -4, -3.5, -3, -2.5, -2, -1,
            0, 0.5, 1, 1.5, 2, 2.4, 2.6,
            2.4, 2, 1.5, 1, 0.8, 0.5,
            0.2, 0, -0.3, -0.5, -0.8, -1,
            -1.5, -2, -2.5, -3
        ],
        inputGainDB: 2,
        loudnessAmount: 0.18,
        fidelityAmount: 0.28,
        nightModeAmount: 0.12,
        limiterCeilingDB: -1
    )
    static let tinySpeakers = DSPPreset(
        name: "Tiny Speakers",
        eqBandsDB: [
            -5, -5, -4.5, -4, -3, -2, -1, 0,
            1.2, 2, 2.4, 2.6, 2.4, 2, 1.4,
            1, 0.8, 0.8, 0.8, 1, 1.2,
            1.4, 1.6, 1.6, 1.2, 0.8, 0.4,
            0, -0.5, -1, -1.5
        ],
        inputGainDB: 3,
        bassAmount: 0.45,
        loudnessAmount: 0.35,
        fidelityAmount: 0.22,
        limiterCeilingDB: -1.2
    )
    static let airPods = DSPPreset(name: "AirPods", inputGainDB: 2, bassAmount: 0.28, widthAmount: 0.18, spatialAmount: 0.24, crossfeedAmount: 0.22, loudnessAmount: 0.24, fidelityAmount: 0.14, hrtfAmount: 0.28)
    static let headphones = DSPPreset(name: "Headphones", inputGainDB: 1.5, bassAmount: 0.2, widthAmount: 0.28, spatialAmount: 0.18, crossfeedAmount: 0.35, loudnessAmount: 0.18, fidelityAmount: 0.12, hrtfAmount: 0.2)
    static let movies = DSPPreset(name: "Movies", inputGainDB: 2.5, bassAmount: 0.38, widthAmount: 0.42, spatialAmount: 0.62, crossfeedAmount: 0.08, loudnessAmount: 0.26, ambienceAmount: 0.24, fidelityAmount: 0.14, hrtfAmount: 0.54, limiterCeilingDB: -1.1, limiterReleaseMS: 150)
    static let nightMode = DSPPreset(name: "Night Mode", inputGainDB: 1, bassAmount: 0.05, widthAmount: 0.05, spatialAmount: 0.06, crossfeedAmount: 0.18, loudnessAmount: 0.14, ambienceAmount: 0.02, nightModeAmount: 0.86, hrtfAmount: 0.08, limiterCeilingDB: -4, limiterReleaseMS: 220, outputGainDB: -3)
    static let manual = DSPPreset(name: "Manual")
}

public enum PresetCatalog {
    public static let builtIns: [DSPPreset] = [
        .flat,
        .cleanLoud,
        .deepBass,
        .spokenVoice,
        .tinySpeakers,
        .airPods,
        .headphones,
        .movies,
        .nightMode,
        .manual
    ]
}

public enum DeviceProfileAdvisor {
    public static func preset(for outputName: String?) -> DSPPreset? {
        guard let name = outputName?.lowercased(), !name.isEmpty else { return nil }
        if contains(name, ["airpods"]) { return .airPods }
        if contains(name, ["macbook", "built-in", "internal speakers"]) { return .tinySpeakers }
        if contains(name, ["tv", "hdmi", "display", "quicktime"]) { return .movies }
        if contains(name, ["headphone", "hd 600", "quietcomfort", "wh-1000", "sony", "bose", "sennheiser"]) { return .headphones }
        if contains(name, ["speaker", "bluetooth", "jbl", "sonos"]) { return .cleanLoud }
        return nil
    }

    private static func contains(_ value: String, _ needles: [String]) -> Bool {
        needles.contains { value.contains($0) }
    }
}

public struct HeadphoneProfile: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var manufacturer: String
    public var name: String
    public var calibrationBandsDB: [Double]

    public init(
        id: String,
        manufacturer: String,
        name: String,
        calibrationBandsDB: [Double]
    ) {
        self.id = id
        self.manufacturer = manufacturer
        self.name = name
        self.calibrationBandsDB = Array((calibrationBandsDB + Array(repeating: 0, count: DSPPreset.bandCount)).prefix(DSPPreset.bandCount))
    }

    public func applying(to preset: DSPPreset) -> DSPPreset {
        let calibrated = zip(preset.eqBandsDB, calibrationBandsDB).map { band, correction in
            min(max(band + correction, -12), 12)
        }
        return preset.with(eqBandsDB: calibrated)
    }
}

public enum HeadphoneProfileCatalog {
    public static let builtIns: [HeadphoneProfile] = [
        HeadphoneProfile(
            id: "airpods-pro",
            manufacturer: "Apple",
            name: "AirPods Pro",
            calibrationBandsDB: curve(low: 1.2, lowerMid: -0.4, presence: 0.7, air: -0.8)
        ),
        HeadphoneProfile(
            id: "airpods-max",
            manufacturer: "Apple",
            name: "AirPods Max",
            calibrationBandsDB: curve(low: 0.6, lowerMid: -0.2, presence: 0.4, air: -0.5)
        ),
        HeadphoneProfile(
            id: "macbook-speakers",
            manufacturer: "Apple",
            name: "MacBook Speakers",
            calibrationBandsDB: curve(low: 2.4, lowerMid: 0.9, presence: 0.6, air: 0.2)
        ),
        HeadphoneProfile(
            id: "sony-wh1000xm5",
            manufacturer: "Sony",
            name: "WH-1000XM5",
            calibrationBandsDB: curve(low: -1.4, lowerMid: 0.2, presence: 0.8, air: 0.9)
        ),
        HeadphoneProfile(
            id: "bose-qc35",
            manufacturer: "Bose",
            name: "QuietComfort 35",
            calibrationBandsDB: curve(low: -0.8, lowerMid: 0.5, presence: 0.9, air: 0.4)
        ),
        HeadphoneProfile(
            id: "sennheiser-hd600",
            manufacturer: "Sennheiser",
            name: "HD 600",
            calibrationBandsDB: curve(low: 1.1, lowerMid: 0.0, presence: -0.2, air: 0.8)
        )
    ]

    private static func curve(low: Double, lowerMid: Double, presence: Double, air: Double) -> [Double] {
        (0..<DSPPreset.bandCount).map { index in
            let position = Double(index) / Double(DSPPreset.bandCount - 1)
            switch position {
            case ..<0.23:
                return interpolate(from: low, to: lowerMid, position: position / 0.23)
            case ..<0.58:
                return interpolate(from: lowerMid, to: presence, position: (position - 0.23) / 0.35)
            default:
                return interpolate(from: presence, to: air, position: (position - 0.58) / 0.42)
            }
        }
    }

    private static func interpolate(from start: Double, to end: Double, position: Double) -> Double {
        start + (end - start) * min(max(position, 0), 1)
    }
}
