import CoreAudio
import AudioToolbox
import XCTest
import SonicBloomDSP
@testable import SonicBloomCore

final class SonicBloomCoreTests: XCTestCase {
    func testAudioUnitEffectDescriptorUsesStableFourCharacterIDs() throws {
        let descriptor = AudioUnitEffectDescriptor(
            name: "Studio EQ",
            manufacturerName: "Apple",
            componentType: kAudioUnitType_Effect,
            componentSubType: fourCC("eqal"),
            componentManufacturer: fourCC("appl")
        )
        let data = try JSONEncoder().encode(descriptor)

        XCTAssertEqual(descriptor.id, "aufx-eqal-appl")
        XCTAssertEqual(descriptor.componentTypeCode, "aufx")
        XCTAssertEqual(descriptor.componentSubTypeCode, "eqal")
        XCTAssertEqual(try JSONDecoder().decode(AudioUnitEffectDescriptor.self, from: data), descriptor)
    }

    func testAudioUnitEffectCatalogOnlySupportsEffects() {
        XCTAssertTrue(AudioUnitEffectCatalog.isSupportedEffectType(kAudioUnitType_Effect))
        XCTAssertTrue(AudioUnitEffectCatalog.isSupportedEffectType(kAudioUnitType_MusicEffect))
        XCTAssertFalse(AudioUnitEffectCatalog.isSupportedEffectType(kAudioUnitType_Output))
    }

    func testAudioUnitEffectCatalogDiscoveryReturnsStableDescriptors() {
        let effects = AudioUnitEffectCatalog.installedEffects()

        XCTAssertEqual(Set(effects.map(\.id)).count, effects.count)
        XCTAssertTrue(effects.allSatisfy { AudioUnitEffectCatalog.isSupportedEffectType($0.componentType) })
    }

    func testAudioUnitEffectPreflightRequiresFindableInstantiableComponent() {
        let descriptor = AudioUnitEffectDescriptor(
            name: "Studio EQ",
            manufacturerName: "Apple",
            componentType: kAudioUnitType_Effect,
            componentSubType: fourCC("eqal"),
            componentManufacturer: fourCC("appl")
        )
        let fakeComponent = AudioComponent(bitPattern: 1)!
        var inspectedDescription: AudioComponentDescription?

        let passing = AudioUnitEffectHostPreflight(
            componentFinder: { description in
                inspectedDescription = description
                return fakeComponent
            },
            instanceChecker: { _ in true }
        )
        XCTAssertTrue(passing.canLoad(descriptor))
        XCTAssertEqual(inspectedDescription?.componentSubType, fourCC("eqal"))

        let missing = AudioUnitEffectHostPreflight(componentFinder: { _ in nil }, instanceChecker: { _ in true })
        XCTAssertFalse(missing.canLoad(descriptor))

        let broken = AudioUnitEffectHostPreflight(componentFinder: { _ in fakeComponent }, instanceChecker: { _ in false })
        XCTAssertFalse(broken.canLoad(descriptor))
    }

    func testBuiltInPresetsAreValidAndCodable() throws {
        let presets = PresetCatalog.builtIns

        XCTAssertEqual(presets.count, 10)
        XCTAssertEqual(Set(presets.map(\.name)).count, presets.count)
        XCTAssertTrue(presets.allSatisfy { $0.eqBandsDB.count == DSPPreset.bandCount })
        XCTAssertTrue(presets.allSatisfy { $0.limiterLookaheadMS <= 0.2 })

        let cleanLoud = try XCTUnwrap(presets.first { $0.name == "Clean Loud" })
        let data = try JSONEncoder().encode(cleanLoud)
        XCTAssertEqual(try JSONDecoder().decode(DSPPreset.self, from: data), cleanLoud)
    }

    func testFlatPresetBypassIsNearTransparent() {
        let frames = (0..<256).map { index in
            StereoFrame(
                left: Float(sin(Double(index) * 0.07) * 0.35),
                right: Float(cos(Double(index) * 0.05) * 0.25)
            )
        }
        let processor = SonicBloomProcessor(sampleRate: 48_000)

        let result = processor.process(frames, preset: .flat, bypass: true)

        XCTAssertEqual(result.frames.count, frames.count)
        for (input, output) in zip(frames, result.frames) {
            XCTAssertEqual(output.left, input.left, accuracy: 0.000_01)
            XCTAssertEqual(output.right, input.right, accuracy: 0.000_01)
        }
    }

    func testBypassDoesNotApplyLimiterCeiling() {
        let frames = [StereoFrame(left: 1.0, right: -1.0)]
        let processor = SonicBloomProcessor(sampleRate: 48_000)

        let result = processor.process(frames, preset: .nightMode, bypass: true)

        XCTAssertEqual(result.frames, frames)
        XCTAssertEqual(result.meter.outputPeak, 1.0, accuracy: 0.000_01)
    }

    func testLoudnessMatchedBypassTracksProcessedLevelSafely() {
        let frames = (0..<4_096).map { index in
            let sample = Float(sin(Double(index) * 0.031) * 0.18)
            return StereoFrame(left: sample, right: -sample)
        }
        let preset = DSPPreset.manual.with(inputGainDB: 7, loudnessAmount: 0.4, limiterCeilingDB: -0.5)
        let raw = SonicBloomProcessor(sampleRate: 48_000).process(frames, preset: preset, bypass: true).frames
        let matchedConfig = preset.makeDSPConfig(sampleRate: 48_000, bypass: true, loudnessMatchedBypass: true)
        let matchedProcessor = SonicBloomProcessor(sampleRate: 48_000)
        var matchedLeft: [Float] = []
        var matchedRight: [Float] = []

        _ = matchedProcessor.process(
            left: frames.map(\.left),
            right: frames.map(\.right),
            outputLeft: &matchedLeft,
            outputRight: &matchedRight,
            config: matchedConfig
        )

        let rawRMS = rms(raw.map(\.left))
        let matchedRMS = rms(matchedLeft)
        let matchedPeak = matchedLeft.map(abs).max() ?? 0

        XCTAssertGreaterThan(matchedRMS, rawRMS * 1.35)
        XCTAssertLessThanOrEqual(matchedPeak, preset.limiterCeilingLinear + 0.000_1)
        XCTAssertEqual(matchedConfig.loudnessMatchedBypass, 1)
    }

    func testLimiterKeepsFullScaleUnderCeiling() {
        let frames = Array(repeating: StereoFrame(left: 2.0, right: -2.0), count: 512)
        let processor = SonicBloomProcessor(sampleRate: 48_000)

        let result = processor.process(frames, preset: .cleanLoud, bypass: false)
        let peak = result.frames.map { max(abs($0.left), abs($0.right)) }.max() ?? 0

        XCTAssertLessThanOrEqual(peak, DSPPreset.cleanLoud.limiterCeilingLinear + 0.000_1)
        XCTAssertGreaterThan(result.meter.gainReductionDB, 0)
        XCTAssertFalse(result.frames.contains { $0.left.isNaN || $0.right.isNaN })
    }

    func testLimiterControlsOversampledTruePeak() {
        let preset = DSPPreset.manual.with(limiterCeilingDB: -3, limiterLookaheadMS: 0.2, limiterReleaseMS: 20)
        let ceiling = preset.limiterCeilingLinear
        let pattern = [-ceiling, ceiling, ceiling, -ceiling]
        let frames = (0..<1_024).map { index in
            let sample = pattern[index % pattern.count]
            return StereoFrame(left: sample, right: sample)
        }
        let processor = SonicBloomProcessor(sampleRate: 48_000)

        let result = processor.process(frames, preset: preset, bypass: false)
        let truePeak = cubicTruePeak(Array(result.frames.dropFirst(96)).map(\.left))

        XCTAssertLessThanOrEqual(truePeak, ceiling + 0.000_1)
    }

    func testBufferProcessorMatchesFrameProcessor() {
        let frames = (0..<384).map { index in
            StereoFrame(
                left: Float(sin(Double(index) * 0.031) * 0.22),
                right: Float(cos(Double(index) * 0.047) * 0.18)
            )
        }
        let left = frames.map(\.left)
        let right = frames.map(\.right)
        let frameProcessor = SonicBloomProcessor(sampleRate: 48_000)
        let bufferProcessor = SonicBloomProcessor(sampleRate: 48_000)
        var outputLeft: [Float] = []
        var outputRight: [Float] = []

        let frameResult = frameProcessor.process(frames, preset: .deepBass, bypass: false)
        let bufferMeter = bufferProcessor.process(
            left: left,
            right: right,
            outputLeft: &outputLeft,
            outputRight: &outputRight,
            preset: .deepBass,
            bypass: false
        )

        XCTAssertEqual(outputLeft.count, frameResult.frames.count)
        XCTAssertEqual(outputRight.count, frameResult.frames.count)
        for index in frameResult.frames.indices {
            XCTAssertEqual(outputLeft[index], frameResult.frames[index].left, accuracy: 0.000_01)
            XCTAssertEqual(outputRight[index], frameResult.frames[index].right, accuracy: 0.000_01)
        }
        XCTAssertEqual(bufferMeter.outputPeak, frameResult.meter.outputPeak, accuracy: 0.000_01)
    }

    func testAudioBufferResizePreservesReservedCapacity() {
        var buffer: [Float] = []

        buffer.resizeAudioBuffer(to: 64, reserveAtLeast: 512)
        let capacity = buffer.capacity
        buffer.resizeAudioBuffer(to: 16, reserveAtLeast: 512)
        buffer.resizeAudioBuffer(to: 256, reserveAtLeast: 512)

        XCTAssertGreaterThanOrEqual(capacity, 512)
        XCTAssertEqual(buffer.count, 256)
        XCTAssertEqual(buffer.capacity, capacity)
    }

    func testSpatialBloomCreatesDelayedStereoEnergyUnderCeiling() {
        let frames = [StereoFrame(left: 1, right: 0)] + Array(repeating: StereoFrame(left: 0, right: 0), count: 128)
        let preset = DSPPreset.manual.with(spatialAmount: 0.9, limiterCeilingDB: -0.1)
        let processor = SonicBloomProcessor(sampleRate: 48_000)

        let result = processor.process(frames, preset: preset, bypass: false)
        let delayedRightPeak = result.frames.dropFirst(2).map { abs($0.right) }.max() ?? 0
        let outputPeak = result.frames.map { max(abs($0.left), abs($0.right)) }.max() ?? 0

        XCTAssertGreaterThan(delayedRightPeak, 0.01)
        XCTAssertLessThanOrEqual(outputPeak, preset.limiterCeilingLinear + 0.000_1)
    }

    func testCrossfeedUsesShortOppositeEarDelay() {
        let frames = [StereoFrame(left: 0.9, right: 0)] + Array(repeating: StereoFrame(left: 0, right: 0), count: 128)
        let preset = DSPPreset.manual.with(crossfeedAmount: 1, limiterCeilingDB: -0.1)

        let result = SonicBloomProcessor(sampleRate: 48_000).process(frames, preset: preset, bypass: false).frames
        let leftPeakIndex = result.indices.max { abs(result[$0].left) < abs(result[$1].left) } ?? 0
        let rightPeakIndex = result.indices.max { abs(result[$0].right) < abs(result[$1].right) } ?? 0

        XCTAssertGreaterThan(rightPeakIndex, leftPeakIndex + 4)
        XCTAssertGreaterThan(abs(result[rightPeakIndex].right), 0.005)
        XCTAssertLessThanOrEqual(result.map { max(abs($0.left), abs($0.right)) }.max() ?? 0, preset.limiterCeilingLinear + 0.000_1)
    }

    func testNightModeCompressorReducesLoudQuietGap() {
        let quiet = Array(repeating: StereoFrame(left: 0.04, right: -0.04), count: 512)
        let loud = Array(repeating: StereoFrame(left: 0.75, right: -0.75), count: 512)
        let frames = quiet + loud
        let dryPreset = DSPPreset.manual.with(limiterCeilingDB: -0.1)
        let nightPreset = dryPreset.with(nightModeAmount: 1, limiterCeilingDB: -0.1)

        let dry = SonicBloomProcessor(sampleRate: 48_000).process(frames, preset: dryPreset, bypass: false).frames
        let night = SonicBloomProcessor(sampleRate: 48_000).process(frames, preset: nightPreset, bypass: false).frames

        let dryRatio = rms(Array(dry[700..<900])) / max(rms(Array(dry[250..<450])), 0.000_001)
        let nightRatio = rms(Array(night[700..<900])) / max(rms(Array(night[250..<450])), 0.000_001)

        XCTAssertLessThan(nightRatio, dryRatio * 0.72)
    }

    func testNightModeCompressesLowBurstsMoreThanUpperDetail() {
        let frames = sineMix(lowFrequency: 80, lowAmplitude: 0.56, highFrequency: 3_500, highAmplitude: 0.08, count: 4_096)
        let dryPreset = DSPPreset.manual.with(limiterCeilingDB: -0.1)
        let nightPreset = dryPreset.with(nightModeAmount: 1)

        let dry = SonicBloomProcessor(sampleRate: 48_000).process(frames, preset: dryPreset, bypass: false).frames
        let night = SonicBloomProcessor(sampleRate: 48_000).process(frames, preset: nightPreset, bypass: false).frames

        let lowRetention = toneMagnitude(night, frequency: 80) / max(toneMagnitude(dry, frequency: 80), 0.000_001)
        let highRetention = toneMagnitude(night, frequency: 3_500) / max(toneMagnitude(dry, frequency: 3_500), 0.000_001)

        XCTAssertLessThan(lowRetention, 0.82)
        XCTAssertGreaterThan(highRetention, lowRetention * 1.18)
    }

    func testNightModeProtectsPresenceFromTrebleBursts() {
        let frames = sineMix(lowFrequency: 1_000, lowAmplitude: 0.08, highFrequency: 6_000, highAmplitude: 0.52, count: 4_096)
        let dryPreset = DSPPreset.manual.with(limiterCeilingDB: -0.1)
        let nightPreset = dryPreset.with(nightModeAmount: 1, limiterCeilingDB: -0.1)

        let dry = SonicBloomProcessor(sampleRate: 48_000).process(frames, preset: dryPreset, bypass: false).frames
        let night = SonicBloomProcessor(sampleRate: 48_000).process(frames, preset: nightPreset, bypass: false).frames

        let midRetention = toneMagnitude(night, frequency: 1_000) / max(toneMagnitude(dry, frequency: 1_000), 0.000_001)
        let trebleRetention = toneMagnitude(night, frequency: 6_000) / max(toneMagnitude(dry, frequency: 6_000), 0.000_001)

        XCTAssertLessThan(trebleRetention, 0.88)
        XCTAssertGreaterThan(midRetention, trebleRetention * 1.25)
    }

    func testBassBloomAddsPsychoacousticHarmonicWeight() {
        let frames = sineMix(lowFrequency: 55, lowAmplitude: 0.28, highFrequency: 0, highAmplitude: 0, count: 4_096)
        let dryPreset = DSPPreset.manual.with(limiterCeilingDB: -0.1)
        let bassPreset = dryPreset.with(bassAmount: 1)

        let dry = SonicBloomProcessor(sampleRate: 48_000).process(frames, preset: dryPreset, bypass: false).frames
        let bass = SonicBloomProcessor(sampleRate: 48_000).process(frames, preset: bassPreset, bypass: false).frames

        XCTAssertGreaterThan(toneMagnitude(bass, frequency: 110), toneMagnitude(dry, frequency: 110) + 0.01)
        XCTAssertGreaterThan(toneMagnitude(bass, frequency: 165), toneMagnitude(dry, frequency: 165) + 0.006)
    }

    func testMeterReportsContentBandEnergy() {
        let processor = SonicBloomProcessor(sampleRate: 48_000)
        let low = processor.process(sineMix(lowFrequency: 70, lowAmplitude: 0.4, highFrequency: 0, highAmplitude: 0, count: 2_048), preset: .flat, bypass: false).meter
        processor.reset(sampleRate: 48_000)
        let high = processor.process(sineMix(lowFrequency: 0, lowAmplitude: 0, highFrequency: 7_000, highAmplitude: 0.4, count: 2_048), preset: .flat, bypass: false).meter

        XCTAssertGreaterThan(low.lowEnergy, low.highEnergy * 2)
        XCTAssertGreaterThan(high.highEnergy, high.lowEnergy * 2)
        XCTAssertGreaterThan(low.spectrumBands[6], low.spectrumBands[26] * 2)
        XCTAssertGreaterThan(high.spectrumBands[26], high.spectrumBands[6] * 2)
    }

    func testFidelityExciterAddsHighFrequencyEnergy() {
        let frames = (0..<1_024).map { index in
            let base = Float(sin(Double(index) * 0.04) * 0.22)
            let dull = base + Float(sin(Double(index) * 0.12) * 0.03)
            return StereoFrame(left: dull, right: dull)
        }
        let dullPreset = DSPPreset.manual.with(limiterCeilingDB: -0.1)
        let brightPreset = dullPreset.with(fidelityAmount: 1)

        let dull = SonicBloomProcessor(sampleRate: 48_000).process(frames, preset: dullPreset, bypass: false).frames
        let bright = SonicBloomProcessor(sampleRate: 48_000).process(frames, preset: brightPreset, bypass: false).frames

        XCTAssertGreaterThan(highFrequencyEnergy(bright), highFrequencyEnergy(dull) * 1.1)
    }

    func testFidelityTamesSibilantSpikes() {
        let frames = sineMix(lowFrequency: 900, lowAmplitude: 0.05, highFrequency: 6_500, highAmplitude: 0.52, count: 4_096)
        let dryPreset = DSPPreset.manual.with(limiterCeilingDB: -0.1)
        let tamerPreset = dryPreset.with(fidelityAmount: 1)

        let dry = SonicBloomProcessor(sampleRate: 48_000).process(frames, preset: dryPreset, bypass: false).frames
        let tamed = SonicBloomProcessor(sampleRate: 48_000).process(frames, preset: tamerPreset, bypass: false).frames

        XCTAssertLessThan(toneMagnitude(tamed, frequency: 6_500), toneMagnitude(dry, frequency: 6_500) * 0.92)
        XCTAssertLessThanOrEqual(tamed.map { max(abs($0.left), abs($0.right)) }.max() ?? 0, tamerPreset.limiterCeilingLinear + 0.000_1)
    }

    func testMasteringTamesHarshBandWithoutCrushingMids() {
        let frames = sineMix(lowFrequency: 1_000, lowAmplitude: 0.10, highFrequency: 6_500, highAmplitude: 0.56, count: 4_096)
        let dryPreset = DSPPreset.manual.with(limiterCeilingDB: -0.1)
        let masteredPreset = dryPreset.with(masteringAmount: 1)

        let dry = SonicBloomProcessor(sampleRate: 48_000).process(frames, preset: dryPreset, bypass: false).frames
        let mastered = SonicBloomProcessor(sampleRate: 48_000).process(frames, preset: masteredPreset, bypass: false).frames

        let dryMid = toneMagnitude(dry, frequency: 1_000)
        let dryHigh = toneMagnitude(dry, frequency: 6_500)
        let masteredMid = toneMagnitude(mastered, frequency: 1_000)
        let masteredHigh = toneMagnitude(mastered, frequency: 6_500)

        XCTAssertLessThan(masteredHigh, dryHigh * 0.86)
        XCTAssertGreaterThan(masteredMid, dryMid * 0.88)
        XCTAssertLessThanOrEqual(mastered.map { max(abs($0.left), abs($0.right)) }.max() ?? 0, masteredPreset.limiterCeilingLinear + 0.000_1)
    }

    func testAmbienceCreatesLateTail() {
        let frames = [StereoFrame(left: 0.8, right: 0.8)] + Array(repeating: StereoFrame(left: 0, right: 0), count: 2_400)
        let preset = DSPPreset.manual.with(ambienceAmount: 1, limiterCeilingDB: -0.1)

        let result = SonicBloomProcessor(sampleRate: 48_000).process(frames, preset: preset, bypass: false).frames
        let lateTail = rms(Array(result[1_100..<2_000]))

        XCTAssertGreaterThan(lateTail, 0.000_5)
    }

    func testAmbienceDiffusesImpulseInsteadOfSparseEchoes() {
        let frames = [StereoFrame(left: 0.8, right: 0)] + Array(repeating: StereoFrame(left: 0, right: 0), count: 7_200)
        let preset = DSPPreset.manual.with(ambienceAmount: 1, limiterCeilingDB: -0.1)

        let result = SonicBloomProcessor(sampleRate: 48_000).process(frames, preset: preset, bypass: false).frames
        let tail = result[4_800..<7_000]
        let activeTailSamples = tail.filter { abs($0.left) > 0.000_02 || abs($0.right) > 0.000_02 }.count
        let rightTail = rms(tail.map(\.right))

        XCTAssertGreaterThan(activeTailSamples, 700)
        XCTAssertGreaterThan(rightTail, 0.000_1)
    }

    func testAmbienceLateTailHasDenseRoomEnergy() {
        let frames = [StereoFrame(left: 0.8, right: 0)] + Array(repeating: StereoFrame(left: 0, right: 0), count: 8_800)
        let preset = DSPPreset.manual.with(ambienceAmount: 1, limiterCeilingDB: -0.1)

        let result = SonicBloomProcessor(sampleRate: 48_000).process(frames, preset: preset, bypass: false).frames
        let tail = Array(result[5_200..<8_500])
        let activeWindows = stride(from: 0, to: tail.count - 64, by: 64).filter { start in
            rms(Array(tail[start..<(start + 64)])) > 0.000_03
        }.count

        let earlyTail = rms(Array(result[1_200..<2_200]))
        let lateTail = rms(Array(result[7_200..<8_500]))

        XCTAssertGreaterThan(activeWindows, 30)
        XCTAssertGreaterThan(lateTail, 0.000_1)
        XCTAssertLessThan(lateTail, earlyTail * 0.7)
    }

    func testHRTFSpatialConvolutionMovesMonoIntoBothChannels() {
        let frames = [StereoFrame(left: 0.8, right: 0)] + Array(repeating: StereoFrame(left: 0, right: 0), count: 256)
        let preset = DSPPreset.manual.with(hrtfAmount: 1, limiterCeilingDB: -0.1)

        let result = SonicBloomProcessor(sampleRate: 48_000).process(frames, preset: preset, bypass: false).frames
        let rightEnergy = result.dropFirst(3).map { abs($0.right) }.max() ?? 0
        let peak = result.map { max(abs($0.left), abs($0.right)) }.max() ?? 0

        XCTAssertGreaterThan(rightEnergy, 0.02)
        XCTAssertLessThanOrEqual(peak, preset.limiterCeilingLinear + 0.000_1)
    }

    func testHRTFHeadShadowReducesFarEarTreble() {
        let preset = DSPPreset.manual.with(hrtfAmount: 1, limiterCeilingDB: -0.1)
        let low = leftOnlyTone(frequency: 500, amplitude: 0.18, count: 4_096)
        let high = leftOnlyTone(frequency: 7_000, amplitude: 0.18, count: 4_096)

        let lowOut = SonicBloomProcessor(sampleRate: 48_000).process(low, preset: preset, bypass: false).frames
        let highOut = SonicBloomProcessor(sampleRate: 48_000).process(high, preset: preset, bypass: false).frames
        let lowFarRatio = channelToneMagnitude(lowOut, frequency: 500, channel: \.right)
            / max(channelToneMagnitude(lowOut, frequency: 500, channel: \.left), 0.000_001)
        let highFarRatio = channelToneMagnitude(highOut, frequency: 7_000, channel: \.right)
            / max(channelToneMagnitude(highOut, frequency: 7_000, channel: \.left), 0.000_001)

        XCTAssertLessThan(highFarRatio, lowFarRatio * 0.72)
    }

    func testHeadphoneProfilesApplyCalibrationBands() throws {
        let profile = try XCTUnwrap(HeadphoneProfileCatalog.builtIns.first { $0.id == "airpods-pro" })
        let calibrated = profile.applying(to: .flat)

        XCTAssertEqual(profile.calibrationBandsDB.count, DSPPreset.bandCount)
        XCTAssertEqual(calibrated.eqBandsDB.count, DSPPreset.bandCount)
        XCTAssertNotEqual(calibrated.eqBandsDB, DSPPreset.flat.eqBandsDB)

        let data = try JSONEncoder().encode(profile)
        XCTAssertEqual(try JSONDecoder().decode(HeadphoneProfile.self, from: data), profile)
    }

    func testAutoEQImporterParsesGraphicEQProfile() throws {
        let text = "GraphicEQ: 20 -6.0; 80 -3.0; 1000 1.5; 10000 4.0; 20000 5.0"

        let profile = try AutoEQProfileImporter.profile(
            name: "HD 650 AutoEQ",
            manufacturer: "Sennheiser",
            text: text
        )

        XCTAssertEqual(profile.id, "sennheiser-hd-650-autoeq")
        XCTAssertEqual(profile.calibrationBandsDB.count, DSPPreset.bandCount)
        XCTAssertLessThan(profile.calibrationBandsDB[0], -5)
        XCTAssertGreaterThan(profile.calibrationBandsDB[30], 4)
    }

    func testAutoEQImporterParsesFrequencyGainRows() throws {
        let text = """
        Frequency,Gain
        20,-4
        1000,2
        20000,3
        """

        let profile = try AutoEQProfileImporter.profile(name: "Custom", manufacturer: "", text: text)

        XCTAssertEqual(profile.manufacturer, "Imported")
        XCTAssertLessThan(profile.calibrationBandsDB[0], -3)
        XCTAssertGreaterThan(profile.calibrationBandsDB[17], 1.5)
    }

    func testAutoEQImporterRejectsEmptyProfile() {
        XCTAssertThrowsError(try AutoEQProfileImporter.profile(name: "", manufacturer: "", text: "Filter 1: ON PK Fc 1000 Hz Gain 3 dB Q 1.4"))
    }

    func testRealtimeRingBufferDropsOldestAndZeroFillsUnderflow() {
        let ring = SonicBloomRingBufferCreate(3)
        defer { SonicBloomRingBufferDestroy(ring) }
        let left: [Float] = [1, 2, 3, 4]
        let right: [Float] = [-1, -2, -3, -4]
        var outputLeft = Array(repeating: Float.nan, count: 5)
        var outputRight = Array(repeating: Float.nan, count: 5)
        let outputFrameCount = outputLeft.count

        let written = left.withUnsafeBufferPointer { leftPointer in
            right.withUnsafeBufferPointer { rightPointer in
                SonicBloomRingBufferWrite(ring, leftPointer.baseAddress, rightPointer.baseAddress, left.count)
            }
        }
        let read = outputLeft.withUnsafeMutableBufferPointer { leftPointer in
            outputRight.withUnsafeMutableBufferPointer { rightPointer in
                SonicBloomRingBufferRead(ring, leftPointer.baseAddress, rightPointer.baseAddress, outputFrameCount)
            }
        }

        XCTAssertEqual(written, 4)
        XCTAssertEqual(read, 3)
        XCTAssertEqual(outputLeft, [2, 3, 4, 0, 0])
        XCTAssertEqual(outputRight, [-2, -3, -4, 0, 0])
    }

    func testRealtimeRingBufferTrimKeepsNewestFrames() {
        let ring = SonicBloomRingBufferCreate(8)
        defer { SonicBloomRingBufferDestroy(ring) }
        let left: [Float] = [1, 2, 3, 4, 5, 6]
        var outputLeft = Array(repeating: Float.nan, count: 4)
        var outputRight = Array(repeating: Float.nan, count: 4)

        _ = left.withUnsafeBufferPointer { pointer in
            SonicBloomRingBufferWrite(ring, pointer.baseAddress, nil, left.count)
        }
        let dropped = SonicBloomRingBufferTrim(ring, 3)
        let available = SonicBloomRingBufferAvailable(ring)
        let outputFrameCount = outputLeft.count
        let read = outputLeft.withUnsafeMutableBufferPointer { leftPointer in
            outputRight.withUnsafeMutableBufferPointer { rightPointer in
                SonicBloomRingBufferRead(ring, leftPointer.baseAddress, rightPointer.baseAddress, outputFrameCount)
            }
        }

        XCTAssertEqual(dropped, 3)
        XCTAssertEqual(available, 3)
        XCTAssertEqual(read, 3)
        XCTAssertEqual(outputLeft, [4, 5, 6, 0])
        XCTAssertEqual(outputRight, [4, 5, 6, 0])
    }

    func testRealtimeConfigBufferPublishesPresetConfig() {
        let buffer = SonicBloomDSPConfigBufferCreate()
        defer { SonicBloomDSPConfigBufferDestroy(buffer) }
        var input = DSPPreset.movies.makeDSPConfig(sampleRate: 44_100, bypass: true, loudnessMatchedBypass: true)
        var output = SonicBloomDSPConfig()

        SonicBloomDSPConfigBufferWrite(buffer, &input)
        let didRead = SonicBloomDSPConfigBufferRead(buffer, &output)

        XCTAssertEqual(didRead, 1)
        XCTAssertEqual(output.sampleRate, 44_100)
        XCTAssertEqual(output.bypass, 1)
        XCTAssertEqual(output.loudnessMatchedBypass, 1)
        XCTAssertEqual(output.ambienceAmount, Float(DSPPreset.movies.ambienceAmount))
        XCTAssertEqual(output.hrtfAmount, Float(DSPPreset.movies.hrtfAmount))
        XCTAssertEqual(output.masteringAmount, Float(DSPPreset.movies.masteringAmount))
        XCTAssertEqual(output.limiterLookaheadMS, Float(DSPPreset.movies.limiterLookaheadMS))
        XCTAssertEqual(output.limiterReleaseMS, Float(DSPPreset.movies.limiterReleaseMS))
    }

    func testLimiterTimingIsPresetBackedAndCodable() throws {
        let preset = DSPPreset.manual.with(name: "Limiter Timing", limiterLookaheadMS: 4.5, limiterReleaseMS: 180)
        let config = preset.makeDSPConfig(sampleRate: 48_000, bypass: false)

        XCTAssertEqual(config.limiterLookaheadMS, 4.5, accuracy: 0.000_1)
        XCTAssertEqual(config.limiterReleaseMS, 180, accuracy: 0.000_1)

        let data = try JSONEncoder().encode(preset)
        XCTAssertEqual(try JSONDecoder().decode(DSPPreset.self, from: data), preset)
    }

    func testOlderPresetJSONDefaultsSpatialControls() throws {
        let data = #"{"name":"Old Manual"}"#.data(using: .utf8)!

        let preset = try JSONDecoder().decode(DSPPreset.self, from: data)

        XCTAssertEqual(preset.spatialAmount, 0)
        XCTAssertEqual(preset.crossfeedAmount, 0)
        XCTAssertEqual(preset.ambienceAmount, 0)
        XCTAssertEqual(preset.fidelityAmount, 0)
        XCTAssertEqual(preset.nightModeAmount, 0)
        XCTAssertEqual(preset.masteringAmount, 0)
        XCTAssertEqual(preset.hrtfAmount, 0)
        XCTAssertEqual(preset.limiterLookaheadMS, 0.2)
        XCTAssertEqual(preset.limiterReleaseMS, 120)
        XCTAssertEqual(preset.eqBandsDB.count, DSPPreset.bandCount)
    }

    func testPresetStoreRoundTripsCustomPreset() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let store = PresetStore(directoryURL: directory)
        let preset = DSPPreset.manual.with(
            name: "Desk Speakers",
            bassAmount: 0.4,
            outputGainDB: -2
        )

        try store.saveCustomPreset(preset)

        XCTAssertEqual(try store.loadCustomPresets(), [preset])
    }

    func testPresetStoreExportsAndImportsShareDocument() throws {
        let sourceDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let targetDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let source = PresetStore(directoryURL: sourceDirectory)
        let target = PresetStore(directoryURL: targetDirectory)
        let preset = DSPPreset.manual.with(name: "AirPods Max Movie Mode", bassAmount: 0.34, hrtfAmount: 0.42)

        try source.saveCustomPreset(preset)
        let data = try XCTUnwrap(source.exportPreset(named: preset.name))
        let imported = try target.importPreset(from: data)

        XCTAssertEqual(imported, preset)
        XCTAssertEqual(try target.loadCustomPresets(), [preset])
        XCTAssertNil(try source.exportPreset(named: "Missing"))
    }

    func testPresetUndoStateCapturesFirstEditUntilUndo() {
        var undo = PresetUndoState()
        var preset = DSPPreset.cleanLoud

        undo.captureIfNeeded(preset)
        preset = preset.with(bassAmount: 0.7)
        undo.captureIfNeeded(preset)
        preset = preset.with(widthAmount: 0.6)

        XCTAssertTrue(undo.canUndo)
        XCTAssertEqual(undo.undo(current: preset), DSPPreset.cleanLoud)
        XCTAssertFalse(undo.canUndo)
    }

    func testProfileDefaultsAreStableAndCodable() throws {
        let profile = SonicBloomProfile.default

        XCTAssertEqual(profile.displayName, "Chris")
        XCTAssertEqual(profile.favoritePresetName, DSPPreset.cleanLoud.name)
        XCTAssertEqual(profile.listeningMode, .everyday)
        XCTAssertEqual(profile.devicePresets, [:])
        XCTAssertEqual(profile.appRules, [:])
        XCTAssertEqual(profile.audioUnitEffects, [])

        let data = try JSONEncoder().encode(profile)
        XCTAssertEqual(try JSONDecoder().decode(SonicBloomProfile.self, from: data), profile)
    }

    func testOlderProfileJSONDefaultsDevicePresets() throws {
        let data = #"{"displayName":"Chris","listeningMode":"Everyday","favoritePresetName":"Clean Loud"}"#.data(using: .utf8)!

        let profile = try JSONDecoder().decode(SonicBloomProfile.self, from: data)

        XCTAssertEqual(profile.devicePresets, [:])
        XCTAssertEqual(profile.appRules, [:])
        XCTAssertEqual(profile.audioUnitEffects, [])
        XCTAssertEqual(profile.favoritePresetName, DSPPreset.cleanLoud.name)
    }

    func testProfileStoresAudioUnitEffectChain() throws {
        var profile = SonicBloomProfile.default
        let descriptor = AudioUnitEffectDescriptor(
            name: "Studio EQ",
            manufacturerName: "Apple",
            componentType: kAudioUnitType_Effect,
            componentSubType: fourCC("eqal"),
            componentManufacturer: fourCC("appl")
        )
        let slot = AudioUnitEffectSlot(effect: descriptor, isEnabled: false)

        profile.addAudioUnitEffect(slot)
        profile.addAudioUnitEffect(slot)
        profile.setAudioUnitEffectEnabled(slot.id, true)

        XCTAssertEqual(profile.audioUnitEffects.count, 1)
        XCTAssertEqual(profile.audioUnitEffects.first?.id, "aufx-eqal-appl")
        XCTAssertEqual(profile.audioUnitEffects.first?.isEnabled, true)

        let data = try JSONEncoder().encode(profile)
        XCTAssertEqual(try JSONDecoder().decode(SonicBloomProfile.self, from: data), profile)
    }

    func testProfileRemovesAudioUnitEffectByID() {
        var profile = SonicBloomProfile.default
        let slot = AudioUnitEffectSlot(
            effect: AudioUnitEffectDescriptor(
                name: "Delay",
                manufacturerName: "Apple",
                componentType: kAudioUnitType_Effect,
                componentSubType: fourCC("dely"),
                componentManufacturer: fourCC("appl")
            )
        )

        profile.addAudioUnitEffect(slot)
        profile.removeAudioUnitEffect(slot.id)

        XCTAssertEqual(profile.audioUnitEffects, [])
    }

    func testProfileRemembersPresetPerOutput() {
        var profile = SonicBloomProfile.default
        let tuned = DSPPreset.movies.with(name: "Movie Desk", bassAmount: 0.44)

        profile.remember(tuned, for: "AudioBox USB")

        XCTAssertEqual(profile.preset(for: "AudioBox USB"), tuned)
        XCTAssertNil(profile.preset(for: nil))
        XCTAssertNil(profile.preset(for: ""))
    }

    func testDeviceProfileAdvisorSuggestsOutputSpecificPresets() {
        XCTAssertEqual(DeviceProfileAdvisor.preset(for: "MacBook Pro Speakers")?.name, DSPPreset.tinySpeakers.name)
        XCTAssertEqual(DeviceProfileAdvisor.preset(for: "Chris AirPods Pro")?.name, DSPPreset.airPods.name)
        XCTAssertEqual(DeviceProfileAdvisor.preset(for: "Sennheiser HD 600")?.name, DSPPreset.headphones.name)
        XCTAssertEqual(DeviceProfileAdvisor.preset(for: "LG TV")?.name, DSPPreset.movies.name)
        XCTAssertNil(DeviceProfileAdvisor.preset(for: nil))
    }

    func testHeadphoneCatalogMatchesCommonOutputNames() throws {
        XCTAssertEqual(HeadphoneProfileCatalog.match(for: "Chris AirPods Pro")?.id, "airpods-pro")
        XCTAssertEqual(HeadphoneProfileCatalog.match(for: "WH-1000XM5")?.id, "sony-wh1000xm5")
        XCTAssertEqual(HeadphoneProfileCatalog.match(for: "Bose QuietComfort Ultra")?.id, "bose-qc-ultra")
        XCTAssertEqual(HeadphoneProfileCatalog.match(for: "MacBook Pro Speakers")?.id, "macbook-speakers")
        XCTAssertNil(HeadphoneProfileCatalog.match(for: "AudioBox USB"))
    }

    func testDeviceProfileAdvisorAppliesMatchedCalibration() throws {
        let profile = try XCTUnwrap(HeadphoneProfileCatalog.match(for: "Chris AirPods Pro"))
        let calibrated = try XCTUnwrap(DeviceProfileAdvisor.calibratedPreset(for: "Chris AirPods Pro"))

        XCTAssertEqual(calibrated.name, DSPPreset.airPods.name)
        XCTAssertEqual(calibrated.eqBandsDB, profile.applying(to: DSPPreset.airPods).eqBandsDB)
        XCTAssertNotEqual(calibrated.eqBandsDB, DSPPreset.airPods.eqBandsDB)
    }

    func testRecommendedCalibrationTuningUsesOutputName() {
        let airPods = CalibrationTuning.recommended(for: "Chris AirPods Pro")
        let macBook = CalibrationTuning.recommended(for: "MacBook Pro Speakers")
        let unknown = CalibrationTuning.recommended(for: "AudioBox USB")

        XCTAssertEqual(airPods.outputKind, .airPods)
        XCTAssertEqual(macBook.outputKind, .tinySpeakers)
        XCTAssertEqual(unknown.outputKind, .speakers)
        XCTAssertGreaterThan(macBook.bassPreference, airPods.bassPreference)
        XCTAssertGreaterThan(airPods.spatialPreference, unknown.spatialPreference)
    }

    func testProfileStoresPerAppAudioRules() {
        var profile = SonicBloomProfile.default
        let rule = AppAudioRule(
            bundleIdentifier: "com.spotify.client",
            displayName: "Spotify",
            gainDB: 18,
            isMuted: true,
            presetName: DSPPreset.deepBass.name,
            syncMode: .music
        )

        profile.upsert(rule)

        XCTAssertEqual(profile.appRule(for: "com.spotify.client")?.gainDB, 12)
        XCTAssertEqual(profile.appRule(for: "com.spotify.client")?.isMuted, true)
        XCTAssertEqual(profile.appRule(for: "com.spotify.client")?.presetName, DSPPreset.deepBass.name)
        XCTAssertEqual(profile.appRule(for: "com.spotify.client")?.syncMode, .music)
        XCTAssertNil(profile.appRule(for: ""))

        profile.removeAppRule(for: "com.spotify.client")
        XCTAssertNil(profile.appRule(for: "com.spotify.client"))
    }

    func testOlderAppAudioRuleJSONDefaultsSyncMode() throws {
        let data = #"{"bundleIdentifier":"com.spotify.client","displayName":"Spotify","gainDB":2,"isMuted":false,"presetName":"Deep Bass"}"#.data(using: .utf8)!

        let rule = try JSONDecoder().decode(AppAudioRule.self, from: data)

        XCTAssertNil(rule.syncMode)
        XCTAssertEqual(rule.presetName, DSPPreset.deepBass.name)
    }

    func testAppAudioRuleAdvisorSuggestsCommonAppPersonalities() {
        let spotify = AppAudioRuleAdvisor.rule(for: "com.spotify.client", displayName: "Spotify")
        let chrome = AppAudioRuleAdvisor.rule(for: "com.google.Chrome", displayName: "Chrome")
        let zoom = AppAudioRuleAdvisor.rule(for: "us.zoom.xos", displayName: "Zoom")
        let steam = AppAudioRuleAdvisor.rule(for: "com.valvesoftware.steam", displayName: "Steam")

        XCTAssertEqual(spotify?.presetName, DSPPreset.cleanLoud.name)
        XCTAssertEqual(spotify?.syncMode, .music)
        XCTAssertEqual(chrome?.presetName, DSPPreset.cleanLoud.name)
        XCTAssertEqual(chrome?.syncMode, .video)
        XCTAssertEqual(zoom?.presetName, DSPPreset.spokenVoice.name)
        XCTAssertEqual(zoom?.syncMode, .video)
        XCTAssertEqual(steam?.syncMode, .gaming)
        XCTAssertNil(AppAudioRuleAdvisor.rule(for: "com.example.notes", displayName: "Notes"))
    }

    func testAppMixerPlannerMarksCoreAudioCaptureReadiness() {
        let apps = [
            RunningAppSnapshot(bundleIdentifier: "com.spotify.client", displayName: "Spotify", processID: 101),
            RunningAppSnapshot(bundleIdentifier: "us.zoom.xos", displayName: "Zoom", processID: 202),
            RunningAppSnapshot(bundleIdentifier: "com.apple.TextEdit", displayName: "TextEdit", processID: 303)
        ]
        let processes = [
            AudioProcessSnapshot(processID: 101, bundleIdentifier: "com.spotify.client", isRunningOutput: true, isAudible: true),
            AudioProcessSnapshot(processID: 202, bundleIdentifier: "us.zoom.xos", isRunningOutput: false, isAudible: true),
            AudioProcessSnapshot(processID: 303, bundleIdentifier: "com.apple.TextEdit", isRunningOutput: true, isAudible: false)
        ]

        let items = AppMixerPlanner.items(savedRules: [:], runningApps: apps, audioProcesses: processes, currentBundleIdentifier: "com.chrisdimarco.SonicBloom")

        XCTAssertEqual(items.first { $0.rule.bundleIdentifier == "com.spotify.client" }?.captureStatus, .ready)
        XCTAssertEqual(items.first { $0.rule.bundleIdentifier == "us.zoom.xos" }?.captureStatus, .waitingForOutput)
        XCTAssertEqual(items.first { $0.rule.bundleIdentifier == "com.apple.TextEdit" }?.captureStatus, .silent)
        XCTAssertTrue(items.first { $0.rule.bundleIdentifier == "com.spotify.client" }?.isTapEligible == true)
    }

    func testAppMixerPlannerKeepsSavedRulesWhenAppIsNotRunning() {
        let saved = AppAudioRule(bundleIdentifier: "com.apple.Music", displayName: "Music", gainDB: -3, presetName: DSPPreset.cleanLoud.name)

        let items = AppMixerPlanner.items(savedRules: [saved.bundleIdentifier: saved], runningApps: [], audioProcesses: [], currentBundleIdentifier: nil)

        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items[0].rule, saved)
        XCTAssertEqual(items[0].captureStatus, .notRunning)
        XCTAssertFalse(items[0].isTapEligible)
    }

    func testAppMixerPlannerExposesProcessTapReadiness() throws {
        let apps = [
            RunningAppSnapshot(bundleIdentifier: "com.spotify.client", displayName: "Spotify", processID: 101)
        ]
        let processes = [
            AudioProcessSnapshot(processID: 101, bundleIdentifier: "com.spotify.client", isRunningOutput: true, isAudible: true, audioObjectID: 9001)
        ]

        let item = try XCTUnwrap(AppMixerPlanner.items(savedRules: [:], runningApps: apps, audioProcesses: processes, currentBundleIdentifier: nil).first)

        XCTAssertEqual(item.processObjectID, 9001)
        XCTAssertTrue(item.canCreateProcessTap)
    }

    func testProcessTapManagerCreatesAndDestroysTap() throws {
        var createdProcessObjects: [UInt32] = []
        var destroyedTaps: [UInt32] = []
        let manager = CoreAudioProcessTapManager(
            createTap: { ids in
                createdProcessObjects = ids
                return 777
            },
            destroyTap: { id in
                destroyedTaps.append(id)
                return noErr
            }
        )
        let item = AppMixerItem(
            rule: AppAudioRule(bundleIdentifier: "com.spotify.client", displayName: "Spotify"),
            processID: 101,
            processObjectID: 9001,
            captureStatus: .ready
        )

        let tap = try manager.createTap(for: item)
        manager.destroyAll()

        XCTAssertEqual(tap.id, 777)
        XCTAssertEqual(createdProcessObjects, [9001])
        XCTAssertEqual(destroyedTaps, [777])
    }

    func testProcessTapManagerCreatesReadableTapDeviceAndDestroysInOrder() throws {
        var aggregateDescription: CoreAudioTapAggregateDescription?
        var destroyedAggregates: [UInt32] = []
        var destroyedTaps: [UInt32] = []
        let manager = CoreAudioProcessTapManager(
            createTap: { _ in 777 },
            tapUID: { id in "tap-\(id)" },
            createAggregateDevice: { description in
                aggregateDescription = description
                return 888
            },
            destroyAggregateDevice: { id in
                destroyedAggregates.append(id)
                return noErr
            },
            destroyTap: { id in
                destroyedTaps.append(id)
                return noErr
            }
        )
        let item = AppMixerItem(
            rule: AppAudioRule(bundleIdentifier: "com.spotify.client", displayName: "Spotify"),
            processID: 101,
            processObjectID: 9001,
            captureStatus: .ready
        )

        let route = try manager.createReadableTapDevice(for: item)
        manager.destroyAll()

        XCTAssertEqual(route.tap.id, 777)
        XCTAssertEqual(route.aggregateDeviceID, 888)
        XCTAssertEqual(aggregateDescription?.tapUID, "tap-777")
        XCTAssertEqual(destroyedAggregates, [888])
        XCTAssertEqual(destroyedTaps, [777])
    }

    func testProcessTapManagerDestroysTapWhenAggregateCreationFails() {
        var destroyedTaps: [UInt32] = []
        let manager = CoreAudioProcessTapManager(
            createTap: { _ in 777 },
            tapUID: { _ in "tap-777" },
            createAggregateDevice: { _ in throw AudioRouteError.coreAudioFailed("no aggregate", -1) },
            destroyAggregateDevice: { _ in noErr },
            destroyTap: { id in
                destroyedTaps.append(id)
                return noErr
            }
        )
        let item = AppMixerItem(
            rule: AppAudioRule(bundleIdentifier: "com.spotify.client", displayName: "Spotify"),
            processID: 101,
            processObjectID: 9001,
            captureStatus: .ready
        )

        XCTAssertThrowsError(try manager.createReadableTapDevice(for: item))
        XCTAssertEqual(destroyedTaps, [777])
    }

    func testProcessTapManagerRejectsAppWithoutCoreAudioObjectID() {
        let manager = CoreAudioProcessTapManager(createTap: { _ in 1 }, destroyTap: { _ in noErr })
        let item = AppMixerItem(
            rule: AppAudioRule(bundleIdentifier: "com.apple.TextEdit", displayName: "TextEdit"),
            processID: 303,
            captureStatus: .ready
        )

        XCTAssertThrowsError(try manager.createTap(for: item))
    }

    func testTapSourceStartsAndStopsAggregateIOProc() throws {
        let ioProc: AudioDeviceIOProcID = { _, _, _, _, _, _, _ in noErr }
        var events: [String] = []
        let source = CoreAudioTapSource(
            route: CoreAudioProcessTapRoute(
                tap: CoreAudioProcessTap(id: 777, processObjectIDs: [9001]),
                aggregateDeviceID: 888,
                aggregateUID: "tap-device"
            ),
            createIOProc: { _, deviceID in
                events.append("create \(deviceID)")
                return ioProc
            },
            startDevice: { deviceID, _ in events.append("start \(deviceID)") },
            stopDevice: { deviceID, _ in events.append("stop \(deviceID)") },
            destroyIOProc: { deviceID, _ in events.append("destroy \(deviceID)") }
        )

        try source.start()
        XCTAssertTrue(source.isRunning)
        source.stop()

        XCTAssertFalse(source.isRunning)
        XCTAssertEqual(events, ["create 888", "start 888", "stop 888", "destroy 888"])
    }

    func testTapSourceDestroysIOProcWhenStartFails() {
        let ioProc: AudioDeviceIOProcID = { _, _, _, _, _, _, _ in noErr }
        var events: [String] = []
        let source = CoreAudioTapSource(
            route: CoreAudioProcessTapRoute(
                tap: CoreAudioProcessTap(id: 777, processObjectIDs: [9001]),
                aggregateDeviceID: 888,
                aggregateUID: "tap-device"
            ),
            createIOProc: { _, deviceID in
                events.append("create \(deviceID)")
                return ioProc
            },
            startDevice: { _, _ in throw AudioRouteError.coreAudioFailed("start failed", -1) },
            stopDevice: { deviceID, _ in events.append("stop \(deviceID)") },
            destroyIOProc: { deviceID, _ in events.append("destroy \(deviceID)") }
        )

        XCTAssertThrowsError(try source.start())
        XCTAssertFalse(source.isRunning)
        XCTAssertEqual(events, ["create 888", "destroy 888"])
    }

    func testTapInputBufferExtractsInterleavedStereoFrames() {
        var samples: [Float] = [0.1, 0.2, 0.3, 0.4]
        let byteSize = UInt32(samples.count * MemoryLayout<Float>.size)
        let frames = samples.withUnsafeMutableBufferPointer { pointer in
            let buffer = AudioBuffer(
                mNumberChannels: 2,
                mDataByteSize: byteSize,
                mData: pointer.baseAddress
            )
            var list = AudioBufferList(mNumberBuffers: 1, mBuffers: buffer)
            return withUnsafePointer(to: &list) { CoreAudioStereoBuffer(inputData: $0).frames }
        }

        XCTAssertEqual(frames, [
            StereoFrame(left: 0.1, right: 0.2),
            StereoFrame(left: 0.3, right: 0.4)
        ])
    }

    func testTapInputBufferExtractsPlanarStereoFrames() {
        var left: [Float] = [0.1, 0.3]
        var right: [Float] = [0.2, 0.4]
        let leftByteSize = UInt32(left.count * MemoryLayout<Float>.size)
        let rightByteSize = UInt32(right.count * MemoryLayout<Float>.size)
        let frames = left.withUnsafeMutableBufferPointer { leftPointer in
            right.withUnsafeMutableBufferPointer { rightPointer in
                let buffers = [
                    AudioBuffer(mNumberChannels: 1, mDataByteSize: leftByteSize, mData: leftPointer.baseAddress),
                    AudioBuffer(mNumberChannels: 1, mDataByteSize: rightByteSize, mData: rightPointer.baseAddress)
                ]
                let byteCount = MemoryLayout<AudioBufferList>.size + MemoryLayout<AudioBuffer>.size
                let rawPointer = UnsafeMutableRawPointer.allocate(byteCount: byteCount, alignment: MemoryLayout<AudioBufferList>.alignment)
                defer { rawPointer.deallocate() }
                let list = rawPointer.bindMemory(to: AudioBufferList.self, capacity: 1)
                list.pointee.mNumberBuffers = 2
                UnsafeMutableAudioBufferListPointer(list)[0] = buffers[0]
                UnsafeMutableAudioBufferListPointer(list)[1] = buffers[1]
                return CoreAudioStereoBuffer(inputData: UnsafePointer(list)).frames
            }
        }

        XCTAssertEqual(frames, [
            StereoFrame(left: 0.1, right: 0.2),
            StereoFrame(left: 0.3, right: 0.4)
        ])
    }

    func testTapSourceEmitsDecodedStereoFrames() throws {
        var emitted: [StereoFrame] = []
        let source = CoreAudioTapSource(
            route: CoreAudioProcessTapRoute(
                tap: CoreAudioProcessTap(id: 777, processObjectIDs: [9001]),
                aggregateDeviceID: 888,
                aggregateUID: "tap-device"
            ),
            stereoFrameHandler: { emitted = $0.frames },
            createIOProc: { source, _ in
                var samples: [Float] = [0.5, -0.5]
                let byteSize = UInt32(samples.count * MemoryLayout<Float>.size)
                samples.withUnsafeMutableBufferPointer { pointer in
                    let buffer = AudioBuffer(mNumberChannels: 2, mDataByteSize: byteSize, mData: pointer.baseAddress)
                    var list = AudioBufferList(mNumberBuffers: 1, mBuffers: buffer)
                    withUnsafePointer(to: &list) { source.handleInputData($0) }
                }
                return { _, _, _, _, _, _, _ in noErr }
            },
            startDevice: { _, _ in },
            stopDevice: { _, _ in },
            destroyIOProc: { _, _ in }
        )

        try source.start()

        XCTAssertEqual(emitted, [StereoFrame(left: 0.5, right: -0.5)])
    }

    func testPerAppAudioLaneAppliesRuleGain() {
        let lane = PerAppAudioLane(
            rule: AppAudioRule(bundleIdentifier: "com.spotify.client", displayName: "Spotify", gainDB: 6),
            basePreset: .flat
        )

        let frames = lane.process(CoreAudioStereoBuffer(frames: Array(repeating: StereoFrame(left: 0.05, right: -0.05), count: 64)))
        let leftPeak = frames.map { abs($0.left) }.max() ?? 0
        let rightPeak = frames.map { abs($0.right) }.max() ?? 0

        XCTAssertEqual(frames.count, 64)
        XCTAssertEqual(leftPeak, 0.0998, accuracy: 0.002)
        XCTAssertEqual(rightPeak, 0.0998, accuracy: 0.002)
    }

    func testPerAppAudioLaneMutesRule() {
        let lane = PerAppAudioLane(
            rule: AppAudioRule(bundleIdentifier: "us.zoom.xos", displayName: "Zoom", gainDB: 12, isMuted: true),
            basePreset: .flat
        )

        let frames = lane.process(CoreAudioStereoBuffer(frames: [StereoFrame(left: 0.5, right: -0.5)]))

        XCTAssertLessThan(abs(frames[0].left), 0.001)
        XCTAssertLessThan(abs(frames[0].right), 0.001)
    }

    func testPerAppAudioLaneMixesIntoBaseFrames() {
        let mixed = PerAppAudioLane.mix(
            [StereoFrame(left: 0.2, right: -0.2), StereoFrame(left: 0.1, right: 0.1)],
            into: [StereoFrame(left: 0.1, right: 0.1)]
        )

        XCTAssertEqual(mixed, [
            StereoFrame(left: 0.3, right: -0.1),
            StereoFrame(left: 0.1, right: 0.1)
        ])
    }

    func testPerAppTapCoordinatorStartsLaneAndEmitsProcessedFrames() throws {
        let ioProc: AudioDeviceIOProcID = { _, _, _, _, _, _, _ in noErr }
        var events: [String] = []
        var emittedRule: AppAudioRule?
        var emittedFrames: [StereoFrame] = []
        let item = AppMixerItem(
            rule: AppAudioRule(bundleIdentifier: "com.spotify.client", displayName: "Spotify", gainDB: 6),
            processID: 101,
            processObjectID: 9001,
            captureStatus: .ready
        )
        let coordinator = PerAppTapCoordinator(
            createRoute: { item in
                events.append("route \(item.rule.bundleIdentifier)")
                return CoreAudioProcessTapRoute(
                    tap: CoreAudioProcessTap(id: 777, processObjectIDs: [item.processObjectID ?? 0]),
                    aggregateDeviceID: 888,
                    aggregateUID: "tap-device"
                )
            },
            destroyRoutes: { events.append("destroy routes") },
            makeSource: { route, handler in
                CoreAudioTapSource(
                    route: route,
                    stereoFrameHandler: handler,
                    createIOProc: { source, deviceID in
                        events.append("create \(deviceID)")
                        var samples = Array(repeating: Float(0), count: 128)
                        for index in stride(from: 0, to: samples.count, by: 2) {
                            samples[index] = 0.05
                            samples[index + 1] = -0.05
                        }
                        let byteSize = UInt32(samples.count * MemoryLayout<Float>.size)
                        samples.withUnsafeMutableBufferPointer { pointer in
                            let buffer = AudioBuffer(mNumberChannels: 2, mDataByteSize: byteSize, mData: pointer.baseAddress)
                            var list = AudioBufferList(mNumberBuffers: 1, mBuffers: buffer)
                            withUnsafePointer(to: &list) { source.handleInputData($0) }
                        }
                        return ioProc
                    },
                    startDevice: { deviceID, _ in events.append("start \(deviceID)") },
                    stopDevice: { deviceID, _ in events.append("stop \(deviceID)") },
                    destroyIOProc: { deviceID, _ in events.append("destroy \(deviceID)") }
                )
            }
        )

        try coordinator.start(items: [item], basePreset: .flat) { rule, frames in
            emittedRule = rule
            emittedFrames = frames
        }

        XCTAssertEqual(coordinator.activeBundleIdentifiers, ["com.spotify.client"])
        XCTAssertEqual(emittedRule?.bundleIdentifier, "com.spotify.client")
        XCTAssertGreaterThan(emittedFrames.map { abs($0.left) }.max() ?? 0, 0.09)

        coordinator.stop()

        XCTAssertEqual(events, ["route com.spotify.client", "create 888", "start 888", "stop 888", "destroy 888", "destroy routes"])
    }

    func testPerAppTapCoordinatorSkipsAppsWithoutTapObject() throws {
        var routeRequests = 0
        let coordinator = PerAppTapCoordinator(
            createRoute: { item in
                routeRequests += 1
                return CoreAudioProcessTapRoute(
                    tap: CoreAudioProcessTap(id: 777, processObjectIDs: [item.processObjectID ?? 0]),
                    aggregateDeviceID: 888,
                    aggregateUID: "tap-device"
                )
            },
            destroyRoutes: {},
            makeSource: { route, handler in CoreAudioTapSource(route: route, stereoFrameHandler: handler) }
        )

        try coordinator.start(
            items: [AppMixerItem(rule: AppAudioRule(bundleIdentifier: "com.apple.TextEdit", displayName: "TextEdit"), processID: 303, captureStatus: .ready)],
            basePreset: .flat
        ) { _, _ in }

        XCTAssertEqual(routeRequests, 0)
        XCTAssertTrue(coordinator.activeBundleIdentifiers.isEmpty)
    }

    func testProfileEffectiveAppRuleUsesSuggestionsUntilSavedRuleExists() {
        var profile = SonicBloomProfile.default

        XCTAssertEqual(profile.effectiveAppRule(for: "us.zoom.xos")?.presetName, DSPPreset.spokenVoice.name)

        profile.upsert(AppAudioRule(
            bundleIdentifier: "us.zoom.xos",
            displayName: "Zoom",
            presetName: nil,
            syncMode: .music
        ))

        XCTAssertNil(profile.effectiveAppRule(for: "us.zoom.xos")?.presetName)
        XCTAssertEqual(profile.effectiveSyncMode(for: "us.zoom.xos", default: .auto, contentProfile: .speech), .music)
    }

    func testProfileResolvesEffectivePerAppPreset() {
        var profile = SonicBloomProfile.default
        profile.upsert(AppAudioRule(
            bundleIdentifier: "com.spotify.client",
            displayName: "Spotify",
            gainDB: 4,
            presetName: DSPPreset.deepBass.name
        ))
        profile.upsert(AppAudioRule(
            bundleIdentifier: "us.zoom.xos",
            displayName: "Zoom",
            isMuted: true,
            presetName: DSPPreset.spokenVoice.name
        ))

        let spotify = profile.effectivePreset(basePreset: .cleanLoud, for: "com.spotify.client")
        let zoom = profile.effectivePreset(basePreset: .cleanLoud, for: "us.zoom.xos")

        XCTAssertEqual(profile.effectivePreset(basePreset: .cleanLoud, for: "com.apple.Safari"), .cleanLoud)
        XCTAssertEqual(spotify.name, DSPPreset.deepBass.name)
        XCTAssertEqual(spotify.outputGainDB, 3)
        XCTAssertEqual(zoom.name, DSPPreset.spokenVoice.name)
        XCTAssertEqual(zoom.outputGainDB, -60)
    }

    func testProfileResolvesPerAppPresetWithSyncMode() {
        var profile = SonicBloomProfile.default
        profile.upsert(AppAudioRule(
            bundleIdentifier: "com.google.Chrome",
            displayName: "Chrome",
            gainDB: 2,
            presetName: DSPPreset.movies.name
        ))

        let preset = profile.effectivePreset(
            basePreset: .cleanLoud,
            for: "com.google.Chrome",
            syncMode: .gaming
        )

        XCTAssertEqual(preset.name, DSPPreset.movies.name)
        XCTAssertEqual(preset.outputGainDB, 2)
        XCTAssertEqual(preset.ambienceAmount, 0)
        XCTAssertEqual(preset.hrtfAmount, 0)
        XCTAssertEqual(preset.spatialAmount, 0)
    }

    func testProfileResolvesPerAppSyncModeOverride() {
        var profile = SonicBloomProfile.default
        profile.upsert(AppAudioRule(
            bundleIdentifier: "com.apple.TV",
            displayName: "TV",
            presetName: DSPPreset.movies.name,
            syncMode: .gaming
        ))

        let preset = profile.effectivePreset(
            basePreset: .cleanLoud,
            for: "com.apple.TV",
            syncMode: .music
        )

        XCTAssertEqual(profile.effectiveSyncMode(for: "com.apple.TV", default: .music), .gaming)
        XCTAssertEqual(preset.name, DSPPreset.movies.name)
        XCTAssertEqual(preset.ambienceAmount, 0)
        XCTAssertEqual(preset.hrtfAmount, 0)
        XCTAssertEqual(preset.spatialAmount, 0)
    }

    func testCalibrationTuningBuildsOutputSpecificPreset() {
        let tuning = CalibrationTuning(
            outputKind: .tinySpeakers,
            bassPreference: 1,
            clarityPreference: 0.75,
            spatialPreference: 0.2,
            loudnessPreference: 1
        )

        let tuned = tuning.applying(to: .flat)

        XCTAssertEqual(tuned.name, DSPPreset.manual.name)
        XCTAssertGreaterThan(tuned.bassAmount, 0.55)
        XCTAssertGreaterThan(tuned.fidelityAmount, 0.2)
        XCTAssertGreaterThan(tuned.loudnessAmount, 0.45)
        XCTAssertGreaterThan(tuned.inputGainDB, DSPPreset.flat.inputGainDB)
        XCTAssertGreaterThan(tuned.eqBandsDB[6], DSPPreset.flat.eqBandsDB[6])
        XCTAssertLessThan(tuned.spatialAmount, 0.18)
        XCTAssertLessThanOrEqual(tuned.limiterCeilingDB, -1)
    }

    func testCalibrationTuningClampsAndCodableRoundTrips() throws {
        let tuning = CalibrationTuning(
            outputKind: .headphones,
            bassPreference: -2,
            clarityPreference: 3,
            spatialPreference: 1,
            loudnessPreference: -4
        )

        let tuned = tuning.applying(to: .flat)

        XCTAssertEqual(tuning.bassPreference, 0)
        XCTAssertEqual(tuning.clarityPreference, 1)
        XCTAssertEqual(tuning.loudnessPreference, 0)
        XCTAssertGreaterThan(tuned.crossfeedAmount, 0.2)
        XCTAssertGreaterThan(tuned.hrtfAmount, 0.25)
        XCTAssertLessThanOrEqual(tuned.loudnessAmount, 0.18)
        XCTAssertLessThanOrEqual(tuned.outputGainDB, 0)

        let data = try JSONEncoder().encode(tuning)
        XCTAssertEqual(try JSONDecoder().decode(CalibrationTuning.self, from: data), tuning)
    }

    func testOlderCalibrationTuningJSONDefaultsLoudnessPreference() throws {
        let data = #"{"outputKind":"Speakers","bassPreference":0.4,"clarityPreference":0.6,"spatialPreference":0.7}"#.data(using: .utf8)!

        let tuning = try JSONDecoder().decode(CalibrationTuning.self, from: data)

        XCTAssertEqual(tuning.loudnessPreference, 0.5)
    }

    func testSettingsClampVisualizerIntensity() throws {
        let quiet = SonicBloomSettings(waveformIntensity: -3)
        let loud = SonicBloomSettings(waveformIntensity: 4)

        XCTAssertEqual(quiet.waveformIntensity, 0)
        XCTAssertEqual(loud.waveformIntensity, 1)
        XCTAssertEqual(SonicBloomSettings.default.syncMode, .auto)
        XCTAssertTrue(SonicBloomSettings.default.smartPresetMatching)
        XCTAssertFalse(SonicBloomSettings.default.showAdvancedControls)
        XCTAssertFalse(SonicBloomSettings.default.applyAppProfilesAutomatically)

        let studio = SonicBloomSettings(showAdvancedControls: true)
        let data = try JSONEncoder().encode(studio)
        XCTAssertEqual(try JSONDecoder().decode(SonicBloomSettings.self, from: data), studio)
    }

    func testOlderSettingsJSONDefaultsToMusicSyncMode() throws {
        let data = #"{"autoEnhanceOnLaunch":true,"reduceMotion":false,"waveformIntensity":0.5,"showAdvancedControls":true}"#.data(using: .utf8)!

        let settings = try JSONDecoder().decode(SonicBloomSettings.self, from: data)

        XCTAssertEqual(settings.syncMode, .music)
        XCTAssertTrue(settings.loudnessMatchedCompare)
        XCTAssertFalse(settings.smartPresetMatching)
        XCTAssertFalse(settings.applyAppProfilesAutomatically)
    }

    func testSyncModeOptimizesSpatialLatencyCost() {
        let cinematic = DSPPreset.movies
        let auto = cinematic.optimized(for: .auto)
        let video = cinematic.optimized(for: .video)
        let gaming = cinematic.optimized(for: .gaming)

        XCTAssertEqual(auto, video)
        XCTAssertLessThanOrEqual(video.ambienceAmount, 0.08)
        XCTAssertLessThanOrEqual(video.hrtfAmount, 0.24)
        XCTAssertLessThanOrEqual(video.spatialAmount, cinematic.spatialAmount)
        XCTAssertEqual(gaming.ambienceAmount, 0)
        XCTAssertEqual(gaming.hrtfAmount, 0)
        XCTAssertEqual(gaming.spatialAmount, 0)
        XCTAssertEqual(gaming.limiterLookaheadMS, 0.2)
    }

    func testSyncModeChoosesHardwareBufferFrameSize() {
        XCTAssertEqual(AudioSyncMode.auto.preferredBufferFrameSize, 64)
        XCTAssertEqual(AudioSyncMode.music.preferredBufferFrameSize, 128)
        XCTAssertEqual(AudioSyncMode.video.preferredBufferFrameSize, 64)
        XCTAssertEqual(AudioSyncMode.gaming.preferredBufferFrameSize, 32)
        XCTAssertEqual(AudioSyncMode.auto.maxQueuedOutputFrames(observedCallbackFrames: 64), 512)
        XCTAssertEqual(AudioSyncMode.music.maxQueuedOutputFrames(observedCallbackFrames: 128), 512)
        XCTAssertEqual(AudioSyncMode.video.maxQueuedOutputFrames(observedCallbackFrames: 64), 512)
        XCTAssertEqual(AudioSyncMode.gaming.maxQueuedOutputFrames(observedCallbackFrames: 1024), 1024)
    }

    func testAutoSyncModeResolvesFromAppAndContent() {
        let profile = SonicBloomProfile.default

        XCTAssertEqual(profile.effectiveSyncMode(for: "com.spotify.client", default: .auto, contentProfile: .speech), .music)
        XCTAssertEqual(profile.effectiveSyncMode(for: "com.google.Chrome", default: .auto, contentProfile: .music), .video)
        XCTAssertEqual(profile.effectiveSyncMode(for: "com.valvesoftware.steam", default: .auto, contentProfile: .music), .gaming)
        XCTAssertEqual(profile.effectiveSyncMode(for: nil, default: .auto, contentProfile: .music), .music)
        XCTAssertEqual(profile.effectiveSyncMode(for: nil, default: .auto, contentProfile: .speech), .video)
        XCTAssertEqual(profile.effectiveSyncMode(for: nil, default: .auto, contentProfile: .quiet), .video)
    }

    func testAppRuleSyncModeStillOverridesAutoSyncMode() {
        var profile = SonicBloomProfile.default
        profile.upsert(AppAudioRule(
            bundleIdentifier: "com.google.Chrome",
            displayName: "Chrome",
            syncMode: .gaming
        ))

        XCTAssertEqual(profile.effectiveSyncMode(for: "com.google.Chrome", default: .auto, contentProfile: .music), .gaming)
    }

    func testSmartPresetAdvisorClassifiesAndStabilizesContent() {
        XCTAssertEqual(SmartPresetAdvisor.profile(for: DSPMeter(lowEnergy: 0.02, midEnergy: 0.32, highEnergy: 0.04)), .speech)
        XCTAssertEqual(SmartPresetAdvisor.profile(for: DSPMeter(lowEnergy: 0.42, midEnergy: 0.18, highEnergy: 0.08)), .movie)
        XCTAssertEqual(SmartPresetAdvisor.profile(for: DSPMeter(lowEnergy: 0.14, midEnergy: 0.20, highEnergy: 0.18)), .music)

        var stabilizer = SmartPresetStabilizer(requiredMatches: 3)
        XCTAssertNil(stabilizer.observe(.movie))
        XCTAssertNil(stabilizer.observe(.movie))
        XCTAssertEqual(stabilizer.observe(.movie), .movies)
        XCTAssertNil(stabilizer.observe(.speech))
    }

    func testSmartPresetStabilizerPreventsRapidPresetFlips() {
        var stabilizer = SmartPresetStabilizer(requiredMatches: 2, cooldownObservations: 3)

        XCTAssertNil(stabilizer.observe(.movie))
        XCTAssertEqual(stabilizer.observe(.movie), .movies)
        XCTAssertNil(stabilizer.observe(.speech))
        XCTAssertNil(stabilizer.observe(.speech))
        XCTAssertNil(stabilizer.observe(.speech))
        XCTAssertEqual(stabilizer.observe(.speech), .spokenVoice)
    }

    private func rms(_ samples: [Float]) -> Float {
        let meanSquare = samples.reduce(Float(0)) { $0 + $1 * $1 } / Float(samples.count)
        return sqrt(meanSquare)
    }

    func testRouteStateStartsWithMissingVirtualDevice() {
        let state = AudioRouteState.default

        XCTAssertEqual(state.virtualDeviceName, "SonicBloom Output")
        XCTAssertEqual(state.installHealth, .notInstalled)
        XCTAssertFalse(state.isProcessingAvailable)
    }

    func testFirstRunSetupGuideStartsWithDriverInstall() {
        let steps = FirstRunSetupGuide.steps(
            routeState: .default,
            isBridgeRunning: false,
            hasPlayedTestSound: false
        )

        XCTAssertEqual(steps.first?.id, .installDriver)
        XCTAssertFalse(steps.first?.isComplete ?? true)
        XCTAssertEqual(steps.first?.actionTitle, "Install Driver")
        XCTAssertFalse(FirstRunSetupGuide.isComplete(steps))
    }

    func testFirstRunSetupGuideCompletesWhenRouteTestAndEnhancementAreReady() {
        let route = AudioRouteState(
            virtualDeviceName: "SonicBloom Output",
            bridgeInputDeviceID: 9,
            bridgeInputDeviceName: "SonicBloom Output",
            selectedPhysicalOutputID: 1,
            selectedPhysicalOutputName: "MacBook Speakers",
            sampleRate: 48_000,
            channels: 2,
            bufferSize: 64,
            installHealth: .active,
            statusMessage: "Processing active"
        )

        let steps = FirstRunSetupGuide.steps(
            routeState: route,
            isBridgeRunning: true,
            hasPlayedTestSound: true
        )

        XCTAssertEqual(steps.map(\.id), [.installDriver, .chooseOutput, .testSound, .turnOnEnhancement])
        XCTAssertTrue(FirstRunSetupGuide.isComplete(steps))
    }

    func testRouteStateEstimatesRoundTripLatencyFromBuffer() {
        let state = AudioRouteState(
            virtualDeviceName: "SonicBloom Output",
            bridgeInputDeviceID: 1,
            bridgeInputDeviceName: "SonicBloom Output",
            selectedPhysicalOutputID: 2,
            selectedPhysicalOutputName: "AudioBox USB",
            sampleRate: 48_000,
            channels: 2,
            bufferSize: 64,
            installHealth: .active,
            statusMessage: "Ready"
        )

        XCTAssertEqual(state.estimatedLatencyMS, 2.666, accuracy: 0.001)
    }

    func testRouteStateRecordsLastRecoveryWithoutDroppingRoute() {
        let state = AudioRouteState(
            virtualDeviceName: "SonicBloom Output",
            bridgeInputDeviceID: 1,
            bridgeInputDeviceName: "SonicBloom Output",
            selectedPhysicalOutputID: 2,
            selectedPhysicalOutputName: "AudioBox USB",
            sampleRate: 48_000,
            channels: 2,
            bufferSize: 64,
            installHealth: .active,
            statusMessage: "Processing"
        )

        let recovered = state.recordingRecovery("Recovered route after output change.")

        XCTAssertEqual(recovered.selectedPhysicalOutputName, "AudioBox USB")
        XCTAssertEqual(recovered.installHealth, .active)
        XCTAssertEqual(recovered.recoveryAttempts, 1)
        XCTAssertEqual(recovered.recoveryMessage, "Recovered route after output change.")
        XCTAssertEqual(recovered.recoverySummary, "Recovered route after output change.")
    }

    func testRouteStateRecordsDegradedRecovery() {
        let state = AudioRouteState.default

        let degraded = state.recordingDegradedRecovery("Route degraded: SonicBloom Output unavailable.")

        XCTAssertEqual(degraded.installHealth, .degraded)
        XCTAssertEqual(degraded.recoveryAttempts, 1)
        XCTAssertEqual(degraded.recoverySummary, "Route degraded: SonicBloom Output unavailable.")
    }

    func testRouteStateEscalatesRepeatedDegradedRecovery() {
        let degraded = AudioRouteState.default
            .recordingDegradedRecovery("Route degraded: SonicBloom Output unavailable.")
            .recordingDegradedRecovery("Route degraded: SonicBloom Output unavailable.")
            .recordingDegradedRecovery("Route degraded: SonicBloom Output unavailable.")

        XCTAssertEqual(degraded.recoveryAttempts, 3)
        XCTAssertTrue(degraded.recoverySummary.contains("Needs attention"))
        XCTAssertTrue(degraded.recoverySummary.contains("3 attempts"))
    }

    func testRouteStateRequestsBridgeRestartAfterCoreAudioRecovery() {
        let degraded = AudioRouteState.default
            .recordingDegradedRecovery("Route degraded: SonicBloom Output unavailable.")
        let recovered = AudioRouteState(
            virtualDeviceName: "SonicBloom Output",
            bridgeInputDeviceID: 1,
            bridgeInputDeviceName: "SonicBloom Output",
            selectedPhysicalOutputID: 2,
            selectedPhysicalOutputName: "AudioBox USB",
            sampleRate: 48_000,
            channels: 2,
            bufferSize: 64,
            installHealth: .installed,
            statusMessage: "Ready"
        )

        XCTAssertTrue(recovered.needsBridgeRestart(after: degraded, bridgeWasRunning: true))
        XCTAssertFalse(recovered.needsBridgeRestart(after: degraded, bridgeWasRunning: false))
        XCTAssertFalse(AudioRouteState.default.needsBridgeRestart(after: degraded, bridgeWasRunning: true))
    }

    func testRouteStateRequestsBridgeRestartAfterOutputChange() {
        let previous = AudioRouteState(
            virtualDeviceName: "SonicBloom Output",
            bridgeInputDeviceID: 1,
            bridgeInputDeviceName: "SonicBloom Output",
            selectedPhysicalOutputID: 2,
            selectedPhysicalOutputName: "AudioBox USB",
            sampleRate: 48_000,
            channels: 2,
            bufferSize: 64,
            installHealth: .active,
            statusMessage: "Processing"
        )
        let next = AudioRouteState(
            virtualDeviceName: "SonicBloom Output",
            bridgeInputDeviceID: 1,
            bridgeInputDeviceName: "SonicBloom Output",
            selectedPhysicalOutputID: 3,
            selectedPhysicalOutputName: "MacBook Speakers",
            sampleRate: 48_000,
            channels: 2,
            bufferSize: 64,
            installHealth: .installed,
            statusMessage: "Ready"
        )

        XCTAssertTrue(next.needsBridgeRestart(after: previous, bridgeWasRunning: true))
    }

    func testRouteStateDoesNotRestartForBufferDisplayMismatch() {
        let previous = AudioRouteState(
            virtualDeviceName: "SonicBloom Output",
            bridgeInputDeviceID: 1,
            bridgeInputDeviceName: "SonicBloom Output",
            selectedPhysicalOutputID: 2,
            selectedPhysicalOutputName: "AudioBox USB",
            sampleRate: 48_000,
            channels: 2,
            bufferSize: 128,
            installHealth: .active,
            statusMessage: "Processing"
        )
        let next = AudioRouteState(
            virtualDeviceName: "SonicBloom Output",
            bridgeInputDeviceID: 1,
            bridgeInputDeviceName: "SonicBloom Output",
            selectedPhysicalOutputID: 2,
            selectedPhysicalOutputName: "AudioBox USB",
            sampleRate: 48_000,
            channels: 2,
            bufferSize: 64,
            installHealth: .installed,
            statusMessage: "Ready"
        )

        XCTAssertFalse(next.needsBridgeRestart(after: previous, bridgeWasRunning: true))
    }

    func testOlderRouteStateJSONDefaultsRecoveryFields() throws {
        let data = #"{"virtualDeviceName":"SonicBloom Output","sampleRate":48000,"channels":2,"bufferSize":64,"installHealth":"installed","statusMessage":"Ready"}"#.data(using: .utf8)!

        let state = try JSONDecoder().decode(AudioRouteState.self, from: data)

        XCTAssertNil(state.recoveryMessage)
        XCTAssertEqual(state.recoveryAttempts, 0)
        XCTAssertEqual(state.recoverySummary, "No recovery needed")
    }

    func testProcessCPUUsageSamplerUsesDeltaTime() {
        var sampler = ProcessCPUUsageSampler()

        XCTAssertEqual(sampler.sample(wallTime: 10, processCPUTime: 2), 0)
        XCTAssertEqual(sampler.sample(wallTime: 11, processCPUTime: 2.25), 25, accuracy: 0.001)
        XCTAssertEqual(sampler.sample(wallTime: 11, processCPUTime: 3), 0)
    }

    func testTrustSummaryUsesUserFacingProtectionCopy() {
        var route = AudioRouteState.default
        route.installHealth = .active
        route.selectedPhysicalOutputName = "AirPods Pro"
        route.bufferSize = 64

        let clean = TrustSummaryBuilder.build(routeState: route, meter: DSPMeter(limitedSamples: 0), cpuUsagePercent: 4, lastError: nil)
        let protected = TrustSummaryBuilder.build(routeState: route, meter: DSPMeter(limitedSamples: 1_536), cpuUsagePercent: 4, lastError: nil)
        let degraded = TrustSummaryBuilder.build(routeState: route.recordingDegradedRecovery("Route unavailable."), meter: DSPMeter(), cpuUsagePercent: 28, lastError: "Route unavailable.")

        XCTAssertEqual(clean.headline, "Audio protected")
        XCTAssertEqual(clean.clipping, "No clipping")
        XCTAssertEqual(clean.route, "Route healthy -> AirPods Pro")
        XCTAssertEqual(clean.cpu, "CPU normal")
        XCTAssertEqual(protected.clipping, "1,536 peaks protected")
        XCTAssertEqual(degraded.headline, "Needs attention")
        XCTAssertEqual(degraded.route, "Route degraded")
        XCTAssertEqual(degraded.cpu, "CPU high")
    }

    func testRoutePlannerRequiresOwnedSonicBloomDriver() {
        let devices = [
            AudioDeviceSnapshot(id: 1, name: "AudioBox USB", inputChannels: 2, outputChannels: 2, sampleRate: 44_100, isVirtual: false),
            AudioDeviceSnapshot(id: 2, name: "BlackHole 2ch", inputChannels: 2, outputChannels: 2, sampleRate: 48_000, isVirtual: true),
            AudioDeviceSnapshot(id: 3, name: "ZoomAudioDevice", inputChannels: 2, outputChannels: 2, sampleRate: 48_000, isVirtual: true)
        ]

        let state = AudioRoutePlanner.state(devices: devices, defaultOutputDeviceID: 1)

        XCTAssertEqual(state.installHealth, .notInstalled)
        XCTAssertNil(state.bridgeInputDeviceName)
        XCTAssertNil(state.bridgeInputDeviceID)
        XCTAssertFalse(state.isProcessingAvailable)
    }

    func testRoutePlannerPrefersOwnedSonicBloomDriverOverBlackHole() {
        let devices = [
            AudioDeviceSnapshot(id: 1, name: "AudioBox USB", inputChannels: 2, outputChannels: 2, sampleRate: 44_100, isVirtual: false),
            AudioDeviceSnapshot(id: 2, name: "BlackHole 2ch", inputChannels: 2, outputChannels: 2, sampleRate: 48_000, isVirtual: true),
            AudioDeviceSnapshot(id: 9, name: "SonicBloom Output", inputChannels: 2, outputChannels: 2, sampleRate: 48_000, isVirtual: true)
        ]

        let state = AudioRoutePlanner.state(devices: devices, defaultOutputDeviceID: 1)

        XCTAssertEqual(state.bridgeInputDeviceName, "SonicBloom Output")
        XCTAssertEqual(state.bridgeInputDeviceID, 9)
        XCTAssertEqual(state.selectedPhysicalOutputName, "AudioBox USB")
        XCTAssertTrue(state.statusMessage.contains("SonicBloom Output"))
    }

    func testRoutePlannerIgnoresVirtualOutputAsPhysicalOutput() {
        let devices = [
            AudioDeviceSnapshot(id: 2, name: "BlackHole 2ch", inputChannels: 2, outputChannels: 2, sampleRate: 48_000, isVirtual: true),
            AudioDeviceSnapshot(id: 3, name: "ZoomAudioDevice", inputChannels: 2, outputChannels: 2, sampleRate: 48_000, isVirtual: true)
        ]

        let state = AudioRoutePlanner.state(devices: devices, defaultOutputDeviceID: 2)

        XCTAssertEqual(state.installHealth, .notInstalled)
        XCTAssertNil(state.selectedPhysicalOutputID)
        XCTAssertFalse(state.isProcessingAvailable)
    }

    func testRoutePlannerRestoresPhysicalOutputWhenDefaultIsSonicBloom() {
        let devices = [
            AudioDeviceSnapshot(id: 1, name: "AudioBox USB", inputChannels: 2, outputChannels: 2, sampleRate: 44_100, isVirtual: false),
            AudioDeviceSnapshot(id: 9, name: "SonicBloom Output", inputChannels: 2, outputChannels: 2, sampleRate: 48_000, isVirtual: true)
        ]

        let output = AudioRoutePlanner.physicalOutputToRestore(
            devices: devices,
            defaultOutputDeviceID: 9,
            previousOutputDeviceID: nil
        )

        XCTAssertEqual(output?.id, 1)
    }

    func testRoutePlannerRecoversAbandonedSonicBloomOutputOnlyWhenAppIsGone() {
        let devices = [
            AudioDeviceSnapshot(id: 1, name: "MacBook Speakers", inputChannels: 0, outputChannels: 2, sampleRate: 48_000, isVirtual: false),
            AudioDeviceSnapshot(id: 9, name: "SonicBloom Output", inputChannels: 2, outputChannels: 2, sampleRate: 48_000, isVirtual: true)
        ]

        XCTAssertNil(AudioRoutePlanner.abandonedBridgeRecoveryOutput(devices: devices, defaultOutputDeviceID: 9, appIsRunning: true))
        XCTAssertEqual(
            AudioRoutePlanner.abandonedBridgeRecoveryOutput(devices: devices, defaultOutputDeviceID: 9, appIsRunning: false)?.id,
            1
        )
    }

    func testHALInstallerScriptInstallsSonicBloomDriver() {
        let driverURL = URL(fileURLWithPath: "/tmp/Driver's Test/SonicBloomHAL.driver")

        let script = SonicBloomHALInstaller.installScript(driverURL: driverURL)

        XCTAssertTrue(script.contains("/usr/bin/ditto '/tmp/Driver'\"'\"'s Test/SonicBloomHAL.driver' /Library/Audio/Plug-Ins/HAL/SonicBloomHAL.driver"))
        XCTAssertTrue(script.contains("/usr/sbin/chown -R root:wheel /Library/Audio/Plug-Ins/HAL/SonicBloomHAL.driver"))
        XCTAssertTrue(script.contains("/usr/bin/killall coreaudiod || true"))
        XCTAssertFalse(script.contains("BlackHole"))
    }

    func testHALInstallerScriptUninstallsOnlySonicBloomDriver() {
        let script = SonicBloomHALInstaller.uninstallScript()

        XCTAssertTrue(script.contains("/bin/rm -rf /Library/Audio/Plug-Ins/HAL/SonicBloomHAL.driver"))
        XCTAssertTrue(script.contains("/usr/bin/killall coreaudiod || true"))
        XCTAssertFalse(script.contains("BlackHole"))
        XCTAssertFalse(script.contains("Soundflower"))
    }

    func testReleaseShipsCleanSonicBloomUninstaller() throws {
        let packageScript = try String(contentsOf: URL(fileURLWithPath: "Scripts/package_release.sh"))
        let uninstallScript = try String(contentsOf: URL(fileURLWithPath: "Scripts/uninstall_sonicbloom.sh"))

        XCTAssertTrue(packageScript.contains("SonicBloom-Uninstall.command"))
        XCTAssertTrue(uninstallScript.contains("/Applications/SonicBloom.app"))
        XCTAssertTrue(uninstallScript.contains("\"$app/Contents/MacOS/SonicBloomRecovery\" --once"))
        XCTAssertTrue(uninstallScript.contains("/Library/Audio/Plug-Ins/HAL/SonicBloomHAL.driver"))
        XCTAssertTrue(uninstallScript.contains("com.chrisdimarco.sonicbloom.recovery.plist"))
        XCTAssertFalse(uninstallScript.contains("BlackHole"))
        XCTAssertFalse(uninstallScript.contains("Soundflower"))
    }

    func testReleaseShipsSupportGuide() throws {
        let packageScript = try String(contentsOf: URL(fileURLWithPath: "Scripts/package_release.sh"))
        let supportGuide = try String(contentsOf: URL(fileURLWithPath: "Docs/Support.md"))

        XCTAssertTrue(packageScript.contains("SonicBloom-Support.md"))
        XCTAssertTrue(supportGuide.contains("If audio goes silent"))
        XCTAssertTrue(supportGuide.contains("Reset Mac Output"))
        XCTAssertTrue(supportGuide.contains("microphone permission"))
        XCTAssertTrue(supportGuide.contains("diagnostics"))
    }

    func testUpdateManifestReportsAvailableRelease() throws {
        let data = Data("""
        {
          "version": "0.2.0",
          "minimumSystemVersion": "13.0",
          "packageURL": "https://example.com/SonicBloom-0.2.0.pkg",
          "packageSHA256": "abc123",
          "notes": "Stability fixes"
        }
        """.utf8)
        let manifest = try JSONDecoder().decode(SonicBloomUpdateManifest.self, from: data)

        XCTAssertEqual(manifest.packageSHA256, "abc123")
        XCTAssertEqual(
            SonicBloomUpdater.decision(currentVersion: "0.1.0", manifest: manifest),
            .updateAvailable(manifest)
        )
        XCTAssertEqual(
            SonicBloomUpdater.decision(currentVersion: "0.2.0", manifest: manifest),
            .upToDate
        )
    }

    func testUpdatePackageVerifierMatchesSHA256() {
        let data = Data("SonicBloom package".utf8)
        let checksum = SonicBloomUpdatePackageVerifier.sha256Hex(for: data)

        XCTAssertTrue(SonicBloomUpdatePackageVerifier.verify(data, expectedSHA256: checksum))
        XCTAssertFalse(SonicBloomUpdatePackageVerifier.verify(data, expectedSHA256: "bad"))
        XCTAssertTrue(SonicBloomUpdatePackageVerifier.verify(data, expectedSHA256: nil))
    }

    func testPackageReleaseWritesUpdateManifest() throws {
        let packageScript = try String(contentsOf: URL(fileURLWithPath: "Scripts/package_release.sh"))

        XCTAssertTrue(packageScript.contains("SonicBloom-update.json"))
        XCTAssertTrue(packageScript.contains("packageURL"))
        XCTAssertTrue(packageScript.contains("packageSHA256"))
        XCTAssertTrue(packageScript.contains("shasum -a 256"))
        XCTAssertTrue(packageScript.contains("minimumSystemVersion"))
    }

    func testPackageReleaseRequiresSigningIdentityForNotarization() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [
            "SONICBLOOM_NOTARY_PROFILE=test-profile",
            "Scripts/package_release.sh",
            "--dry-run",
            "--skip-build"
        ]
        let errorPipe = Pipe()
        process.standardOutput = FileHandle.nullDevice
        process.standardError = errorPipe

        try process.run()
        process.waitUntilExit()

        let errorText = String(data: errorPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        XCTAssertNotEqual(process.terminationStatus, 0)
        XCTAssertTrue(errorText.contains("SONICBLOOM_INSTALLER_IDENTITY"))
    }

    private func rms(_ frames: [StereoFrame]) -> Float {
        guard !frames.isEmpty else { return 0 }
        let sum = frames.reduce(Float(0)) { partial, frame in
            partial + frame.left * frame.left + frame.right * frame.right
        }
        return sqrt(sum / Float(frames.count * 2))
    }

    private func highFrequencyEnergy(_ frames: [StereoFrame]) -> Float {
        guard frames.count > 1 else { return 0 }
        return zip(frames.dropFirst(), frames).reduce(Float(0)) { partial, pair in
            partial + abs(pair.0.left - pair.1.left) + abs(pair.0.right - pair.1.right)
        }
    }

    private func cubicTruePeak(_ samples: [Float]) -> Float {
        guard samples.count >= 4 else { return samples.map(abs).max() ?? 0 }
        var peak = samples.map(abs).max() ?? 0
        for index in 3..<samples.count {
            for step in 1..<4 {
                let t = Float(step) / 4
                let sample = catmullRom(
                    samples[index - 3],
                    samples[index - 2],
                    samples[index - 1],
                    samples[index],
                    t
                )
                peak = max(peak, abs(sample))
            }
        }
        return peak
    }

    private func catmullRom(_ y0: Float, _ y1: Float, _ y2: Float, _ y3: Float, _ t: Float) -> Float {
        0.5 * (
            2 * y1
            + (-y0 + y2) * t
            + (2 * y0 - 5 * y1 + 4 * y2 - y3) * t * t
            + (-y0 + 3 * y1 - 3 * y2 + y3) * t * t * t
        )
    }

    private func sineMix(lowFrequency: Double, lowAmplitude: Double, highFrequency: Double, highAmplitude: Double, count: Int) -> [StereoFrame] {
        (0..<count).map { index in
            let time = Double(index) / 48_000
            let low = sin(2 * Double.pi * lowFrequency * time) * lowAmplitude
            let high = highFrequency > 0 ? sin(2 * Double.pi * highFrequency * time) * highAmplitude : 0
            let sample = Float(low + high)
            return StereoFrame(left: sample, right: sample)
        }
    }

    private func leftOnlyTone(frequency: Double, amplitude: Double, count: Int) -> [StereoFrame] {
        (0..<count).map { index in
            let time = Double(index) / 48_000
            let sample = Float(sin(2 * Double.pi * frequency * time) * amplitude)
            return StereoFrame(left: sample, right: 0)
        }
    }

    private func channelToneMagnitude(_ frames: [StereoFrame], frequency: Double, channel: KeyPath<StereoFrame, Float>) -> Float {
        guard !frames.isEmpty else { return 0 }
        var real = 0.0
        var imag = 0.0
        for (index, frame) in frames.enumerated() {
            let phase = 2 * Double.pi * frequency * Double(index) / 48_000
            let sample = Double(frame[keyPath: channel])
            real += sample * cos(phase)
            imag -= sample * sin(phase)
        }
        return Float(2 * sqrt(real * real + imag * imag) / Double(frames.count))
    }

    private func toneMagnitude(_ frames: [StereoFrame], frequency: Double) -> Float {
        guard !frames.isEmpty else { return 0 }
        var real = 0.0
        var imag = 0.0
        for (index, frame) in frames.enumerated() {
            let phase = 2 * Double.pi * frequency * Double(index) / 48_000
            let sample = Double((frame.left + frame.right) * 0.5)
            real += sample * cos(phase)
            imag -= sample * sin(phase)
        }
        return Float(2 * sqrt(real * real + imag * imag) / Double(frames.count))
    }

    private func fourCC(_ value: String) -> OSType {
        value.utf8.reduce(OSType(0)) { ($0 << 8) | OSType($1) }
    }
}
