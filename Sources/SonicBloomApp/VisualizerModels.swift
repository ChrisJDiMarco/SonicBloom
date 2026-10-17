import Foundation
import QuartzCore
import SonicBloomCore

private func clamp01(_ value: Double) -> Double {
    min(max(value, 0), 1)
}

private func clamp01(_ value: Float) -> Float {
    min(max(value, 0), 1)
}

struct VisualizerColor: Codable, Equatable, Sendable {
    var red: Double
    var green: Double
    var blue: Double

    init(red: Double, green: Double, blue: Double) {
        self.red = clamp01(red)
        self.green = clamp01(green)
        self.blue = clamp01(blue)
    }

    var simd: SIMD4<Float> {
        SIMD4(Float(red), Float(green), Float(blue), 1)
    }

    private enum CodingKeys: String, CodingKey {
        case red, green, blue
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            red: try values.decodeIfPresent(Double.self, forKey: .red) ?? 0,
            green: try values.decodeIfPresent(Double.self, forKey: .green) ?? 0,
            blue: try values.decodeIfPresent(Double.self, forKey: .blue) ?? 0
        )
    }
}

struct VisualizerPalette: Codable, Equatable, Sendable {
    var background: VisualizerColor
    var primary: VisualizerColor
    var secondary: VisualizerColor
    var accent: VisualizerColor

    init(
        background: VisualizerColor = VisualizerColor(red: 0.005, green: 0.009, blue: 0.014),
        primary: VisualizerColor = VisualizerColor(red: 0.00, green: 0.68, blue: 0.66),
        secondary: VisualizerColor = VisualizerColor(red: 0.00, green: 0.63, blue: 0.32),
        accent: VisualizerColor = VisualizerColor(red: 0.90, green: 0.48, blue: 0.03)
    ) {
        self.background = background
        self.primary = primary
        self.secondary = secondary
        self.accent = accent
    }

    static let `default` = VisualizerPalette()

    private enum CodingKeys: String, CodingKey {
        case background, primary, secondary, accent
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            background: try values.decodeIfPresent(VisualizerColor.self, forKey: .background) ?? Self.default.background,
            primary: try values.decodeIfPresent(VisualizerColor.self, forKey: .primary) ?? Self.default.primary,
            secondary: try values.decodeIfPresent(VisualizerColor.self, forKey: .secondary) ?? Self.default.secondary,
            accent: try values.decodeIfPresent(VisualizerColor.self, forKey: .accent) ?? Self.default.accent
        )
    }
}

struct VisualizerReactiveParameter: Codable, Equatable, Sendable {
    var base: Double
    var bass: Double
    var mid: Double
    var high: Double
    var beat: Double
    var flux: Double
    var peak: Double

    init(
        base: Double = 0,
        bass: Double = 0,
        mid: Double = 0,
        high: Double = 0,
        beat: Double = 0,
        flux: Double = 0,
        peak: Double = 0
    ) {
        self.base = base
        self.bass = bass
        self.mid = mid
        self.high = high
        self.beat = beat
        self.flux = flux
        self.peak = peak
    }

    func value(from audio: VisualizerAudioFrame) -> Float {
        let value = base
            + bass * Double(audio.lowEnvelope)
            + mid * Double(audio.midEnvelope)
            + high * Double(audio.highEnvelope)
            + beat * Double(audio.beatConfidence)
            + flux * Double(audio.spectralFlux)
            + peak * Double(audio.outputPeak)
        return Float(value)
    }

    private enum CodingKeys: String, CodingKey {
        case base, bass, mid, high, beat, flux, peak
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            base: try values.decodeIfPresent(Double.self, forKey: .base) ?? 0,
            bass: try values.decodeIfPresent(Double.self, forKey: .bass) ?? 0,
            mid: try values.decodeIfPresent(Double.self, forKey: .mid) ?? 0,
            high: try values.decodeIfPresent(Double.self, forKey: .high) ?? 0,
            beat: try values.decodeIfPresent(Double.self, forKey: .beat) ?? 0,
            flux: try values.decodeIfPresent(Double.self, forKey: .flux) ?? 0,
            peak: try values.decodeIfPresent(Double.self, forKey: .peak) ?? 0
        )
    }
}

struct VisualizerReactiveParameters: Codable, Equatable, Sendable {
    var warp: VisualizerReactiveParameter
    var zoom: VisualizerReactiveParameter
    var bloom: VisualizerReactiveParameter
    var rotation: VisualizerReactiveParameter

    init(
        warp: VisualizerReactiveParameter = VisualizerReactiveParameter(base: 0.16, bass: 0.26, beat: 0.16, flux: 0.08),
        zoom: VisualizerReactiveParameter = VisualizerReactiveParameter(base: 0.08, bass: 0.12, peak: 0.06),
        bloom: VisualizerReactiveParameter = VisualizerReactiveParameter(base: 0.32, high: 0.20, beat: 0.24),
        rotation: VisualizerReactiveParameter = VisualizerReactiveParameter(base: 0.04, mid: 0.08, flux: 0.06)
    ) {
        self.warp = warp
        self.zoom = zoom
        self.bloom = bloom
        self.rotation = rotation
    }

    static let `default` = VisualizerReactiveParameters()

    private enum CodingKeys: String, CodingKey {
        case warp, zoom, bloom, rotation
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            warp: try values.decodeIfPresent(VisualizerReactiveParameter.self, forKey: .warp) ?? Self.default.warp,
            zoom: try values.decodeIfPresent(VisualizerReactiveParameter.self, forKey: .zoom) ?? Self.default.zoom,
            bloom: try values.decodeIfPresent(VisualizerReactiveParameter.self, forKey: .bloom) ?? Self.default.bloom,
            rotation: try values.decodeIfPresent(VisualizerReactiveParameter.self, forKey: .rotation) ?? Self.default.rotation
        )
    }
}

struct VisualizerModuleWeights: Codable, Equatable, Sendable {
    var warp: Double
    var ribbons: Double
    var radialSpectrum: Double
    var particles: Double
    var bloom: Double
    var waveform: Double

    init(
        warp: Double = 0.74,
        ribbons: Double = 0.72,
        radialSpectrum: Double = 0.80,
        particles: Double = 0.45,
        bloom: Double = 0.64,
        waveform: Double = 0.55
    ) {
        self.warp = clamp01(warp)
        self.ribbons = clamp01(ribbons)
        self.radialSpectrum = clamp01(radialSpectrum)
        self.particles = clamp01(particles)
        self.bloom = clamp01(bloom)
        self.waveform = clamp01(waveform)
    }

    static let `default` = VisualizerModuleWeights()

    private enum CodingKeys: String, CodingKey {
        case warp, ribbons, radialSpectrum, particles, bloom, waveform
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            warp: try values.decodeIfPresent(Double.self, forKey: .warp) ?? Self.default.warp,
            ribbons: try values.decodeIfPresent(Double.self, forKey: .ribbons) ?? Self.default.ribbons,
            radialSpectrum: try values.decodeIfPresent(Double.self, forKey: .radialSpectrum) ?? Self.default.radialSpectrum,
            particles: try values.decodeIfPresent(Double.self, forKey: .particles) ?? Self.default.particles,
            bloom: try values.decodeIfPresent(Double.self, forKey: .bloom) ?? Self.default.bloom,
            waveform: try values.decodeIfPresent(Double.self, forKey: .waveform) ?? Self.default.waveform
        )
    }
}

struct VisualizerGeneratorSettings: Codable, Equatable, Sendable {
    var particleCount: Int
    var radialComplexity: Double
    var ribbonCount: Int
    var tunnelDepth: Double
    var symmetry: Double
    var folds: Double
    var cellular: Double
    var nebula: Double
    var interference: Double

    init(
        particleCount: Int = 72,
        radialComplexity: Double = 0.62,
        ribbonCount: Int = 4,
        tunnelDepth: Double = 0.58,
        symmetry: Double = 0.50,
        folds: Double = 0.32,
        cellular: Double = 0.26,
        nebula: Double = 0.44,
        interference: Double = 0.38
    ) {
        self.particleCount = min(max(particleCount, 12), 160)
        self.radialComplexity = clamp01(radialComplexity)
        self.ribbonCount = min(max(ribbonCount, 1), 8)
        self.tunnelDepth = clamp01(tunnelDepth)
        self.symmetry = clamp01(symmetry)
        self.folds = clamp01(folds)
        self.cellular = clamp01(cellular)
        self.nebula = clamp01(nebula)
        self.interference = clamp01(interference)
    }

    static let `default` = VisualizerGeneratorSettings()

    private enum CodingKeys: String, CodingKey {
        case particleCount, radialComplexity, ribbonCount, tunnelDepth, symmetry, folds, cellular, nebula, interference
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            particleCount: try values.decodeIfPresent(Int.self, forKey: .particleCount) ?? Self.default.particleCount,
            radialComplexity: try values.decodeIfPresent(Double.self, forKey: .radialComplexity) ?? Self.default.radialComplexity,
            ribbonCount: try values.decodeIfPresent(Int.self, forKey: .ribbonCount) ?? Self.default.ribbonCount,
            tunnelDepth: try values.decodeIfPresent(Double.self, forKey: .tunnelDepth) ?? Self.default.tunnelDepth,
            symmetry: try values.decodeIfPresent(Double.self, forKey: .symmetry) ?? Self.default.symmetry,
            folds: try values.decodeIfPresent(Double.self, forKey: .folds) ?? Self.default.folds,
            cellular: try values.decodeIfPresent(Double.self, forKey: .cellular) ?? Self.default.cellular,
            nebula: try values.decodeIfPresent(Double.self, forKey: .nebula) ?? Self.default.nebula,
            interference: try values.decodeIfPresent(Double.self, forKey: .interference) ?? Self.default.interference
        )
    }
}

struct VisualizerMorphSettings: Codable, Equatable, Sendable {
    var rate: Double
    var chaos: Double
    var geometry: Double
    var colorDrift: Double
    var sceneBlend: Double
    var feedbackEcho: Double
    var prism: Double
    var waveComplexity: Double

    init(
        rate: Double = 0.46,
        chaos: Double = 0.34,
        geometry: Double = 0.48,
        colorDrift: Double = 0.36,
        sceneBlend: Double = 0.58,
        feedbackEcho: Double = 0.42,
        prism: Double = 0.26,
        waveComplexity: Double = 0.50
    ) {
        self.rate = clamp01(rate)
        self.chaos = clamp01(chaos)
        self.geometry = clamp01(geometry)
        self.colorDrift = clamp01(colorDrift)
        self.sceneBlend = clamp01(sceneBlend)
        self.feedbackEcho = clamp01(feedbackEcho)
        self.prism = clamp01(prism)
        self.waveComplexity = clamp01(waveComplexity)
    }

    static let `default` = VisualizerMorphSettings()

    private enum CodingKeys: String, CodingKey {
        case rate, chaos, geometry, colorDrift, sceneBlend, feedbackEcho, prism, waveComplexity
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            rate: try values.decodeIfPresent(Double.self, forKey: .rate) ?? Self.default.rate,
            chaos: try values.decodeIfPresent(Double.self, forKey: .chaos) ?? Self.default.chaos,
            geometry: try values.decodeIfPresent(Double.self, forKey: .geometry) ?? Self.default.geometry,
            colorDrift: try values.decodeIfPresent(Double.self, forKey: .colorDrift) ?? Self.default.colorDrift,
            sceneBlend: try values.decodeIfPresent(Double.self, forKey: .sceneBlend) ?? Self.default.sceneBlend,
            feedbackEcho: try values.decodeIfPresent(Double.self, forKey: .feedbackEcho) ?? Self.default.feedbackEcho,
            prism: try values.decodeIfPresent(Double.self, forKey: .prism) ?? Self.default.prism,
            waveComplexity: try values.decodeIfPresent(Double.self, forKey: .waveComplexity) ?? Self.default.waveComplexity
        )
    }
}

struct VisualizerPreset: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var name: String
    var palette: VisualizerPalette
    var modules: VisualizerModuleWeights
    var generators: VisualizerGeneratorSettings
    var morph: VisualizerMorphSettings
    var transitionDuration: Double
    var reactiveParameters: VisualizerReactiveParameters

    init(
        id: String,
        name: String,
        palette: VisualizerPalette = .default,
        modules: VisualizerModuleWeights = .default,
        generators: VisualizerGeneratorSettings = .default,
        morph: VisualizerMorphSettings = .default,
        transitionDuration: Double = 3.2,
        reactiveParameters: VisualizerReactiveParameters = .default
    ) {
        self.id = id.isEmpty ? "bloom-tunnel" : id
        self.name = name.isEmpty ? "Bloom Tunnel" : name
        self.palette = palette
        self.modules = modules
        self.generators = generators
        self.morph = morph
        self.transitionDuration = min(max(transitionDuration, 0.35), 12)
        self.reactiveParameters = reactiveParameters
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, palette, modules, generators, morph, transitionDuration, reactiveParameters
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try values.decodeIfPresent(String.self, forKey: .id) ?? "bloom-tunnel",
            name: try values.decodeIfPresent(String.self, forKey: .name) ?? "Bloom Tunnel",
            palette: try values.decodeIfPresent(VisualizerPalette.self, forKey: .palette) ?? .default,
            modules: try values.decodeIfPresent(VisualizerModuleWeights.self, forKey: .modules) ?? .default,
            generators: try values.decodeIfPresent(VisualizerGeneratorSettings.self, forKey: .generators) ?? .default,
            morph: try values.decodeIfPresent(VisualizerMorphSettings.self, forKey: .morph) ?? .default,
            transitionDuration: try values.decodeIfPresent(Double.self, forKey: .transitionDuration) ?? 3.2,
            reactiveParameters: try values.decodeIfPresent(VisualizerReactiveParameters.self, forKey: .reactiveParameters) ?? .default
        )
    }
}

enum VisualizerPresetLibrary {
    static func bundledPresets(bundle: Bundle = .module) -> [VisualizerPreset] {
        guard let url = bundle.url(forResource: "VisualizerPresets", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let presets = try? JSONDecoder().decode([VisualizerPreset].self, from: data),
              !presets.isEmpty else {
            return fallbackPresets
        }
        return presets
    }

    static let fallbackPresets: [VisualizerPreset] = [
        VisualizerPreset(id: "bloom-tunnel", name: "Bloom Tunnel"),
        VisualizerPreset(
            id: "glass-cathedral",
            name: "Glass Cathedral",
            palette: VisualizerPalette(
                background: VisualizerColor(red: 0.01, green: 0.012, blue: 0.026),
                primary: VisualizerColor(red: 0.38, green: 0.78, blue: 1.0),
                secondary: VisualizerColor(red: 0.72, green: 0.94, blue: 0.88),
                accent: VisualizerColor(red: 0.98, green: 0.82, blue: 0.42)
            ),
            modules: VisualizerModuleWeights(warp: 0.52, ribbons: 0.88, radialSpectrum: 0.54, particles: 0.34, bloom: 0.74, waveform: 0.48),
            generators: VisualizerGeneratorSettings(particleCount: 56, radialComplexity: 0.38, ribbonCount: 6, tunnelDepth: 0.44, symmetry: 0.88)
        ),
        VisualizerPreset(
            id: "solar-bass-garden",
            name: "Solar Bass Garden",
            palette: VisualizerPalette(
                background: VisualizerColor(red: 0.014, green: 0.010, blue: 0.004),
                primary: VisualizerColor(red: 1.0, green: 0.66, blue: 0.12),
                secondary: VisualizerColor(red: 0.12, green: 0.82, blue: 0.45),
                accent: VisualizerColor(red: 1.0, green: 0.22, blue: 0.16)
            ),
            modules: VisualizerModuleWeights(warp: 0.86, ribbons: 0.54, radialSpectrum: 0.76, particles: 0.52, bloom: 0.78, waveform: 0.40),
            generators: VisualizerGeneratorSettings(particleCount: 88, radialComplexity: 0.72, ribbonCount: 3, tunnelDepth: 0.70, symmetry: 0.42)
        ),
        VisualizerPreset(id: "neon-reef", name: "Neon Reef"),
        VisualizerPreset(id: "aurora-circuit", name: "Aurora Circuit"),
        VisualizerPreset(id: "velvet-warp", name: "Velvet Warp"),
        VisualizerPreset(id: "starfield-bloom", name: "Starfield Bloom"),
        VisualizerPreset(id: "signal-mandala", name: "Signal Mandala"),
        VisualizerPreset(id: "chromatic-fold", name: "Chromatic Fold"),
        VisualizerPreset(id: "deep-space-cells", name: "Deep Space Cells"),
        VisualizerPreset(id: "oil-slick-vortex", name: "Oil Slick Vortex"),
        VisualizerPreset(id: "lattice-bloom", name: "Lattice Bloom"),
        VisualizerPreset(id: "smoke-glass", name: "Smoke Glass"),
        VisualizerPreset(id: "pulse-engine", name: "Pulse Engine"),
        VisualizerPreset(id: "quantum-lattice", name: "Quantum Lattice"),
        VisualizerPreset(id: "liquid-prism", name: "Liquid Prism"),
        VisualizerPreset(id: "fractal-ballroom", name: "Fractal Ballroom"),
        VisualizerPreset(id: "bassline-hive", name: "Bassline Hive"),
        VisualizerPreset(id: "ghost-oscilloscope", name: "Ghost Oscilloscope"),
        VisualizerPreset(id: "ion-storm", name: "Ion Storm"),
        VisualizerPreset(id: "cathedral-bloomfield", name: "Cathedral Bloomfield"),
        VisualizerPreset(id: "velvet-hyperspace", name: "Velvet Hyperspace")
    ]
}

struct VisualizerAudioFrame: Equatable, Sendable {
    var bands: [Float]
    var bandDeltas: [Float]
    var lowEnvelope: Float
    var midEnvelope: Float
    var highEnvelope: Float
    var spectralFlux: Float
    var onset: Float
    var beatConfidence: Float
    var beatPhase: Float
    var inputPeak: Float
    var outputPeak: Float

    static let silence = VisualizerAudioFrame(
        bands: Array(repeating: 0, count: DSPPreset.bandCount),
        bandDeltas: Array(repeating: 0, count: DSPPreset.bandCount),
        lowEnvelope: 0,
        midEnvelope: 0,
        highEnvelope: 0,
        spectralFlux: 0,
        onset: 0,
        beatConfidence: 0,
        beatPhase: 0,
        inputPeak: 0,
        outputPeak: 0
    )
}

final class VisualizerAudioAnalyzer {
    private var smoothedBands = Array(repeating: Float(0), count: DSPPreset.bandCount)
    private var previousBands = Array(repeating: Float(0), count: DSPPreset.bandCount)
    private var normalizedBandsScratch = Array(repeating: Float(0), count: DSPPreset.bandCount)
    private var deltasScratch = Array(repeating: Float(0), count: DSPPreset.bandCount)
    private var previousTotalEnergy: Float = 0
    private var previousOutputPeak: Float = 0
    private var lowEnvelope: Float = 0
    private var midEnvelope: Float = 0
    private var highEnvelope: Float = 0
    private var beatConfidence: Float = 0
    private var beatPeriod: TimeInterval = 0.52
    private var lastBeatTime: TimeInterval?
    private var lastTime: TimeInterval?

    @discardableResult
    func ingest(_ meter: DSPMeter, at time: TimeInterval = CACurrentMediaTime()) -> VisualizerAudioFrame {
        updateNormalizedBands(from: meter.spectrumBands)
        let dt = Float(max(1.0 / 120.0, min(time - (lastTime ?? time), 0.25)))
        let alpha = min(max(dt * 12, 0.12), 0.45)
        var positiveDeltaSum: Float = 0

        for index in 0..<DSPPreset.bandCount {
            smoothedBands[index] += (normalizedBandsScratch[index] - smoothedBands[index]) * alpha
            let delta = smoothedBands[index] - previousBands[index]
            deltasScratch[index] = delta
            positiveDeltaSum += max(delta, 0)
        }

        let inputPeak = clamp01(meter.inputPeak)
        let outputPeak = clamp01(meter.outputPeak)
        let peakLevel = level(max(inputPeak, outputPeak))
        let lowTarget = max(level(meter.lowEnergy), average(smoothedBands, in: 0..<10), peakLevel * 0.50)
        let midTarget = max(level(meter.midEnergy), average(smoothedBands, in: 10..<22), peakLevel * 0.36)
        let highTarget = max(level(meter.highEnergy), average(smoothedBands, in: 22..<DSPPreset.bandCount), peakLevel * 0.24)
        lowEnvelope += (lowTarget - lowEnvelope) * alpha
        midEnvelope += (midTarget - midEnvelope) * alpha
        highEnvelope += (highTarget - highEnvelope) * alpha

        let totalEnergy = lowEnvelope * 0.44 + midEnvelope * 0.34 + highEnvelope * 0.22
        let energyDelta = max(totalEnergy - previousTotalEnergy, 0)
        let peakDelta = max(max(inputPeak, outputPeak) - previousOutputPeak, 0)
        let spectralFlux = clamp01(positiveDeltaSum / Float(DSPPreset.bandCount) * 10.5 + peakDelta * 0.70)
        let onset = clamp01(spectralFlux * 0.70 + energyDelta * 1.70 + peakDelta * 0.95)
        updateBeat(onset: onset, time: time, dt: dt)

        let beatPhase: Float
        if let lastBeatTime {
            let phase = (time - lastBeatTime) / max(beatPeriod, 0.18)
            beatPhase = Float(phase - floor(phase))
        } else {
            beatPhase = 0
        }

        let frame = VisualizerAudioFrame(
            bands: smoothedBands,
            bandDeltas: deltasScratch,
            lowEnvelope: lowEnvelope,
            midEnvelope: midEnvelope,
            highEnvelope: highEnvelope,
            spectralFlux: spectralFlux,
            onset: onset,
            beatConfidence: beatConfidence,
            beatPhase: beatPhase,
            inputPeak: inputPeak,
            outputPeak: outputPeak
        )

        for index in 0..<DSPPreset.bandCount {
            previousBands[index] = smoothedBands[index]
        }
        previousTotalEnergy = totalEnergy
        previousOutputPeak = max(inputPeak, outputPeak)
        lastTime = time
        return frame
    }

    private func updateBeat(onset: Float, time: TimeInterval, dt: Float) {
        beatConfidence *= pow(0.72, dt * 8)
        let timeSinceBeat = time - (lastBeatTime ?? -10)
        let threshold = max(Float(0.10), min(Float(0.48), beatConfidence * 0.62 + 0.12))
        guard onset > threshold, timeSinceBeat > 0.16 else { return }

        if let lastBeatTime {
            beatPeriod += ((time - lastBeatTime) - beatPeriod) * 0.18
            beatPeriod = min(max(beatPeriod, 0.22), 1.4)
        }
        lastBeatTime = time
        beatConfidence = max(beatConfidence, min(1, onset * 1.55))
    }

    private func updateNormalizedBands(from bands: [Float]) {
        for index in 0..<DSPPreset.bandCount {
            normalizedBandsScratch[index] = index < bands.count ? clamp01(level(bands[index])) : 0
        }
    }

    private func level(_ value: Float) -> Float {
        clamp01(pow(max(value, 0) * 2.2, 0.58))
    }

    private func average(_ values: [Float], in range: Range<Int>) -> Float {
        var sum: Float = 0
        var count: Float = 0
        for index in range where values.indices.contains(index) {
            sum += values[index]
            count += 1
        }
        return count > 0 ? sum / count : 0
    }
}

struct VisualizerPresetDeck: Equatable {
    private(set) var presets: [VisualizerPreset]
    private(set) var currentIndex: Int
    private(set) var transitionSourceIndex: Int?
    private(set) var comboIndex: Int?
    private(set) var isLocked: Bool
    private(set) var renderSeed: UInt32
    var autoCycleEnabled: Bool
    var cycleSeconds: Double

    private var transitionStartedAt: TimeInterval
    private var transitionDuration: TimeInterval
    private var lastAutoCycleAt: TimeInterval
    private var comboStartedAt: TimeInterval
    private var comboAttackDuration: TimeInterval
    private var comboHoldDuration: TimeInterval
    private var comboReleaseDuration: TimeInterval
    private var nextComboAt: TimeInterval
    private var rngState: UInt64

    init(
        presets: [VisualizerPreset] = VisualizerPresetLibrary.fallbackPresets,
        selectedPresetID: String = VisualizerSettings.default.selectedPresetID,
        autoCycleEnabled: Bool = true,
        cycleSeconds: Double = 28,
        startTime: TimeInterval = 0,
        seed: UInt64 = 0x50A1C_B100D
    ) {
        let safePresets = presets.isEmpty ? VisualizerPresetLibrary.fallbackPresets : presets
        self.presets = safePresets
        self.currentIndex = safePresets.firstIndex { $0.id == selectedPresetID } ?? 0
        self.transitionSourceIndex = nil
        self.comboIndex = nil
        self.isLocked = false
        self.renderSeed = UInt32(truncatingIfNeeded: seed)
        self.autoCycleEnabled = autoCycleEnabled
        self.cycleSeconds = min(max(cycleSeconds, 8), 300)
        self.transitionStartedAt = startTime
        self.transitionDuration = safePresets[currentIndex].transitionDuration
        self.lastAutoCycleAt = startTime
        self.comboStartedAt = startTime
        self.comboAttackDuration = 1.6
        self.comboHoldDuration = 5.4
        self.comboReleaseDuration = 2.8
        self.nextComboAt = startTime + min(max(cycleSeconds * 0.36, 4.5), 12)
        self.rngState = seed
    }

    var currentPreset: VisualizerPreset {
        presets[currentIndex]
    }

    func sourcePreset(at time: TimeInterval) -> VisualizerPreset? {
        guard let transitionSourceIndex, transitionProgress(at: time) < 1 else { return nil }
        return presets[transitionSourceIndex]
    }

    func comboPreset(at time: TimeInterval) -> VisualizerPreset? {
        guard let comboIndex, comboProgress(at: time) > 0 else { return nil }
        return presets[comboIndex]
    }

    func transitionProgress(at time: TimeInterval) -> Double {
        guard transitionSourceIndex != nil else { return 1 }
        guard transitionDuration > 0 else { return 1 }
        return min(max((time - transitionStartedAt) / transitionDuration, 0), 1)
    }

    func comboProgress(at time: TimeInterval) -> Double {
        guard comboIndex != nil else { return 0 }
        let age = time - comboStartedAt
        guard age > 0 else { return 0 }
        if age < comboAttackDuration {
            return smoothEnvelope(age / max(comboAttackDuration, 0.01))
        }
        let holdEnd = comboAttackDuration + comboHoldDuration
        if age < holdEnd {
            return 1
        }
        let releaseAge = age - holdEnd
        if releaseAge < comboReleaseDuration {
            return 1 - smoothEnvelope(releaseAge / max(comboReleaseDuration, 0.01))
        }
        return 0
    }

    mutating func update(at time: TimeInterval) {
        if transitionSourceIndex != nil, transitionProgress(at: time) >= 1 {
            transitionSourceIndex = nil
        }
        if comboIndex != nil, comboProgress(at: time) <= 0, time > comboStartedAt + comboAttackDuration + comboHoldDuration + comboReleaseDuration {
            comboIndex = nil
        }
        if autoCycleEnabled, !isLocked, presets.count > 2, comboIndex == nil, time >= nextComboAt {
            randomCombo(at: time)
        }
        guard autoCycleEnabled, !isLocked, presets.count > 1, time - lastAutoCycleAt >= cycleSeconds else { return }
        random(at: time)
    }

    mutating func next(at time: TimeInterval) {
        guard presets.count > 1 else { return }
        move(to: (currentIndex + 1) % presets.count, at: time)
    }

    mutating func previous(at time: TimeInterval) {
        guard presets.count > 1 else { return }
        move(to: (currentIndex + presets.count - 1) % presets.count, at: time)
    }

    mutating func random(at time: TimeInterval) {
        guard presets.count > 1 else { return }
        let index = randomIndex(excluding: [currentIndex])
        move(to: index, at: time)
    }

    mutating func randomCombo(at time: TimeInterval) {
        guard presets.count > 2 else { return }
        var excluded = [currentIndex]
        if let transitionSourceIndex {
            excluded.append(transitionSourceIndex)
        }
        if let comboIndex {
            excluded.append(comboIndex)
        }
        comboIndex = randomIndex(excluding: excluded)
        comboStartedAt = time
        comboAttackDuration = 0.8 + nextUnitRandom() * 1.6
        comboHoldDuration = 3.2 + nextUnitRandom() * 5.2
        comboReleaseDuration = 1.4 + nextUnitRandom() * 2.8
        nextComboAt = time + comboAttackDuration + comboHoldDuration + comboReleaseDuration + 2.0 + nextUnitRandom() * 5.0
        renderSeed &+= 1
    }

    mutating func toggleLock() {
        isLocked.toggle()
    }

    mutating func resetSeed() {
        renderSeed &+= 1
    }

    mutating func syncSettings(autoCycleEnabled: Bool, cycleSeconds: Double) {
        self.autoCycleEnabled = autoCycleEnabled
        self.cycleSeconds = min(max(cycleSeconds, 8), 300)
    }

    private mutating func move(to index: Int, at time: TimeInterval) {
        guard presets.indices.contains(index), index != currentIndex else { return }
        transitionSourceIndex = currentIndex
        currentIndex = index
        transitionStartedAt = time
        transitionDuration = currentPreset.transitionDuration
        lastAutoCycleAt = time
        renderSeed &+= 1
    }

    private mutating func randomIndex(excluding excluded: [Int]) -> Int {
        let excludedSet = Set(excluded)
        let available = presets.indices.filter { !excludedSet.contains($0) }
        guard !available.isEmpty else { return currentIndex }
        let index = Int(nextRawRandom() % UInt64(available.count))
        return available[index]
    }

    private mutating func nextRawRandom() -> UInt64 {
        rngState = rngState &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return rngState
    }

    private mutating func nextUnitRandom() -> TimeInterval {
        TimeInterval(nextRawRandom() % 10_000) / 10_000
    }

    private func smoothEnvelope(_ value: Double) -> Double {
        let t = min(max(value, 0), 1)
        return t * t * (3 - 2 * t)
    }
}
