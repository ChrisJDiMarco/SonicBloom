import XCTest
import SonicBloomDSP
@testable import SonicBloomCore

final class SonicBloomCoreTests: XCTestCase {
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

    func testHeadphoneProfilesApplyCalibrationBands() throws {
        let profile = try XCTUnwrap(HeadphoneProfileCatalog.builtIns.first { $0.id == "airpods-pro" })
        let calibrated = profile.applying(to: .flat)

        XCTAssertEqual(profile.calibrationBandsDB.count, DSPPreset.bandCount)
        XCTAssertEqual(calibrated.eqBandsDB.count, DSPPreset.bandCount)
        XCTAssertNotEqual(calibrated.eqBandsDB, DSPPreset.flat.eqBandsDB)

        let data = try JSONEncoder().encode(profile)
        XCTAssertEqual(try JSONDecoder().decode(HeadphoneProfile.self, from: data), profile)
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

    func testProfileDefaultsAreStableAndCodable() throws {
        let profile = SonicBloomProfile.default

        XCTAssertEqual(profile.displayName, "Chris")
        XCTAssertEqual(profile.favoritePresetName, DSPPreset.cleanLoud.name)
        XCTAssertEqual(profile.listeningMode, .everyday)
        XCTAssertEqual(profile.devicePresets, [:])
        XCTAssertEqual(profile.appRules, [:])

        let data = try JSONEncoder().encode(profile)
        XCTAssertEqual(try JSONDecoder().decode(SonicBloomProfile.self, from: data), profile)
    }

    func testOlderProfileJSONDefaultsDevicePresets() throws {
        let data = #"{"displayName":"Chris","listeningMode":"Everyday","favoritePresetName":"Clean Loud"}"#.data(using: .utf8)!

        let profile = try JSONDecoder().decode(SonicBloomProfile.self, from: data)

        XCTAssertEqual(profile.devicePresets, [:])
        XCTAssertEqual(profile.appRules, [:])
        XCTAssertEqual(profile.favoritePresetName, DSPPreset.cleanLoud.name)
    }

    func testProfileRemembersPresetPerOutput() {
        var profile = SonicBloomProfile.default
        let tuned = DSPPreset.movies.with(name: "Movie Desk", bassAmount: 0.44)

        profile.remember(tuned, for: "AudioBox USB")

        XCTAssertEqual(profile.preset(for: "AudioBox USB"), tuned)
        XCTAssertNil(profile.preset(for: nil))
        XCTAssertNil(profile.preset(for: ""))
    }

    func testProfileStoresPerAppAudioRules() {
        var profile = SonicBloomProfile.default
        let rule = AppAudioRule(
            bundleIdentifier: "com.spotify.client",
            displayName: "Spotify",
            gainDB: 18,
            isMuted: true,
            presetName: DSPPreset.deepBass.name
        )

        profile.upsert(rule)

        XCTAssertEqual(profile.appRule(for: "com.spotify.client")?.gainDB, 12)
        XCTAssertEqual(profile.appRule(for: "com.spotify.client")?.isMuted, true)
        XCTAssertEqual(profile.appRule(for: "com.spotify.client")?.presetName, DSPPreset.deepBass.name)
        XCTAssertNil(profile.appRule(for: ""))

        profile.removeAppRule(for: "com.spotify.client")
        XCTAssertNil(profile.appRule(for: "com.spotify.client"))
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

    func testCalibrationTuningBuildsOutputSpecificPreset() {
        let tuning = CalibrationTuning(
            outputKind: .tinySpeakers,
            bassPreference: 1,
            clarityPreference: 0.75,
            spatialPreference: 0.2
        )

        let tuned = tuning.applying(to: .flat)

        XCTAssertEqual(tuned.name, DSPPreset.manual.name)
        XCTAssertGreaterThan(tuned.bassAmount, 0.55)
        XCTAssertGreaterThan(tuned.fidelityAmount, 0.2)
        XCTAssertGreaterThan(tuned.eqBandsDB[6], DSPPreset.flat.eqBandsDB[6])
        XCTAssertLessThan(tuned.spatialAmount, 0.18)
        XCTAssertLessThanOrEqual(tuned.limiterCeilingDB, -1)
    }

    func testCalibrationTuningClampsAndCodableRoundTrips() throws {
        let tuning = CalibrationTuning(
            outputKind: .headphones,
            bassPreference: -2,
            clarityPreference: 3,
            spatialPreference: 1
        )

        let tuned = tuning.applying(to: .flat)

        XCTAssertEqual(tuning.bassPreference, 0)
        XCTAssertEqual(tuning.clarityPreference, 1)
        XCTAssertGreaterThan(tuned.crossfeedAmount, 0.2)
        XCTAssertGreaterThan(tuned.hrtfAmount, 0.25)

        let data = try JSONEncoder().encode(tuning)
        XCTAssertEqual(try JSONDecoder().decode(CalibrationTuning.self, from: data), tuning)
    }

    func testSettingsClampVisualizerIntensity() throws {
        let quiet = SonicBloomSettings(waveformIntensity: -3)
        let loud = SonicBloomSettings(waveformIntensity: 4)

        XCTAssertEqual(quiet.waveformIntensity, 0)
        XCTAssertEqual(loud.waveformIntensity, 1)
        XCTAssertEqual(SonicBloomSettings.default.syncMode, .music)
        XCTAssertFalse(SonicBloomSettings.default.smartPresetMatching)

        let data = try JSONEncoder().encode(SonicBloomSettings.default)
        XCTAssertEqual(try JSONDecoder().decode(SonicBloomSettings.self, from: data), .default)
    }

    func testOlderSettingsJSONDefaultsToMusicSyncMode() throws {
        let data = #"{"autoEnhanceOnLaunch":true,"reduceMotion":false,"waveformIntensity":0.5,"showAdvancedControls":true}"#.data(using: .utf8)!

        let settings = try JSONDecoder().decode(SonicBloomSettings.self, from: data)

        XCTAssertEqual(settings.syncMode, .music)
        XCTAssertTrue(settings.loudnessMatchedCompare)
        XCTAssertFalse(settings.smartPresetMatching)
    }

    func testSyncModeOptimizesSpatialLatencyCost() {
        let cinematic = DSPPreset.movies
        let video = cinematic.optimized(for: .video)
        let gaming = cinematic.optimized(for: .gaming)

        XCTAssertLessThanOrEqual(video.ambienceAmount, 0.08)
        XCTAssertLessThanOrEqual(video.hrtfAmount, 0.24)
        XCTAssertLessThanOrEqual(video.spatialAmount, cinematic.spatialAmount)
        XCTAssertEqual(gaming.ambienceAmount, 0)
        XCTAssertEqual(gaming.hrtfAmount, 0)
        XCTAssertEqual(gaming.spatialAmount, 0)
        XCTAssertEqual(gaming.limiterLookaheadMS, 0.2)
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
}
