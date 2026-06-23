import Foundation
import SonicBloomDSP

public extension DSPPreset {
    func makeDSPConfig(
        sampleRate: Double,
        bypass: Bool,
        loudnessMatchedBypass: Bool = false,
        spatialImpulseProfile: SpatialImpulseProfile? = nil
    ) -> SonicBloomDSPConfig {
        var config = SonicBloomDSPConfig()
        config.sampleRate = Float(sampleRate)
        config.inputGainDB = Float(inputGainDB)
        config.outputGainDB = Float(outputGainDB)
        config.bassAmount = Float(bassAmount)
        config.widthAmount = Float(widthAmount)
        config.spatialAmount = Float(spatialAmount)
        config.crossfeedAmount = Float(crossfeedAmount)
        config.loudnessAmount = Float(loudnessAmount)
        config.ambienceAmount = Float(ambienceAmount)
        config.fidelityAmount = Float(fidelityAmount)
        config.nightModeAmount = Float(nightModeAmount)
        config.masteringAmount = Float(masteringAmount)
        config.hrtfAmount = Float(hrtfAmount)
        config.limiterCeilingDB = Float(limiterCeilingDB)
        config.limiterLookaheadMS = Float(limiterLookaheadMS)
        config.limiterReleaseMS = Float(limiterReleaseMS)
        config.bypass = bypass ? 1 : 0
        config.loudnessMatchedBypass = loudnessMatchedBypass ? 1 : 0
        withUnsafeMutableBytes(of: &config.eqBandsDB) { rawBuffer in
            let bands = rawBuffer.bindMemory(to: Float.self)
            for index in 0..<min(DSPPreset.bandCount, bands.count) {
                bands[index] = Float(eqBandsDB[index])
            }
        }
        if let spatialImpulseProfile {
            let kernels = spatialImpulseProfile.dspKernels(tapCount: Int(SonicBloomDSPHRTFTapCount))
            config.hrtfKernelTapCount = Int32(SonicBloomDSPHRTFTapCount)
            write(kernels.nearEar, to: &config.hrtfNearEar)
            write(kernels.farEar, to: &config.hrtfFarEar)
            write(kernels.roomNear, to: &config.hrtfRoomNear)
            write(kernels.roomFar, to: &config.hrtfRoomFar)
        }
        return config
    }

    private func write<T>(_ samples: [Float], to storage: inout T) {
        withUnsafeMutableBytes(of: &storage) { rawBuffer in
            let buffer = rawBuffer.bindMemory(to: Float.self)
            for index in 0..<min(samples.count, buffer.count) {
                buffer[index] = samples[index]
            }
        }
    }
}

public final class SonicBloomProcessor {
    private let handle: OpaquePointer
    public private(set) var sampleRate: Double

    public init(sampleRate: Double) {
        self.sampleRate = sampleRate
        self.handle = SonicBloomDSPCreate(Float(sampleRate))
    }

    deinit {
        SonicBloomDSPDestroy(handle)
    }

    public func reset(sampleRate: Double) {
        self.sampleRate = sampleRate
        SonicBloomDSPReset(handle, Float(sampleRate))
    }

    public func process(_ frames: [StereoFrame], preset: DSPPreset, bypass: Bool) -> ProcessResult {
        guard !frames.isEmpty else {
            return ProcessResult(frames: [], meter: DSPMeter())
        }

        let left = frames.map(\.left)
        let right = frames.map(\.right)
        var outputLeft: [Float] = []
        var outputRight: [Float] = []
        let meter = process(
            left: left,
            right: right,
            outputLeft: &outputLeft,
            outputRight: &outputRight,
            preset: preset,
            bypass: bypass
        )
        let output = zip(outputLeft, outputRight).map { StereoFrame(left: $0, right: $1) }
        return ProcessResult(frames: output, meter: meter)
    }

    public func process(
        left inputLeft: [Float],
        right inputRight: [Float],
        outputLeft: inout [Float],
        outputRight: inout [Float],
        preset: DSPPreset,
        bypass: Bool
    ) -> DSPMeter {
        let frameCount = min(inputLeft.count, inputRight.count)
        guard frameCount > 0 else {
            outputLeft.removeAll(keepingCapacity: true)
            outputRight.removeAll(keepingCapacity: true)
            return DSPMeter()
        }

        return process(
            left: inputLeft,
            right: inputRight,
            outputLeft: &outputLeft,
            outputRight: &outputRight,
            config: preset.makeDSPConfig(sampleRate: sampleRate, bypass: bypass)
        )
    }

    public func process(
        left inputLeft: [Float],
        right inputRight: [Float],
        outputLeft: inout [Float],
        outputRight: inout [Float],
        config: SonicBloomDSPConfig
    ) -> DSPMeter {
        let frameCount = min(inputLeft.count, inputRight.count)
        guard frameCount > 0 else {
            outputLeft.removeAll(keepingCapacity: true)
            outputRight.removeAll(keepingCapacity: true)
            return DSPMeter()
        }

        outputLeft.resizeAudioBuffer(to: frameCount)
        outputRight.resizeAudioBuffer(to: frameCount)
        var mutableConfig = config
        let cMeter = inputLeft.withUnsafeBufferPointer { leftPointer in
            inputRight.withUnsafeBufferPointer { rightPointer in
                outputLeft.withUnsafeMutableBufferPointer { outputLeftPointer in
                    outputRight.withUnsafeMutableBufferPointer { outputRightPointer in
                        SonicBloomDSPProcess(
                            handle,
                            &mutableConfig,
                            leftPointer.baseAddress,
                            rightPointer.baseAddress,
                            outputLeftPointer.baseAddress,
                            outputRightPointer.baseAddress,
                            frameCount
                        )
                    }
                }
            }
        }

        let spectrumBands = withUnsafeBytes(of: cMeter.spectrumBands) { rawBuffer in
            Array(rawBuffer.bindMemory(to: Float.self).prefix(DSPPreset.bandCount))
        }

        return DSPMeter(
            inputPeak: cMeter.inputPeak,
            outputPeak: cMeter.outputPeak,
            gainReductionDB: cMeter.gainReductionDB,
            lowEnergy: cMeter.lowEnergy,
            midEnergy: cMeter.midEnergy,
            highEnergy: cMeter.highEnergy,
            spectrumBands: spectrumBands,
            limitedSamples: cMeter.limitedSamples
        )
    }
}

public extension Array where Element == Float {
    mutating func resizeAudioBuffer(to count: Int, reserveAtLeast reservedCount: Int = 0) {
        let targetCapacity = Swift.max(count, reservedCount)
        if capacity < targetCapacity {
            reserveCapacity(targetCapacity)
        }
        if self.count < count {
            append(contentsOf: repeatElement(0, count: count - self.count))
        } else if self.count > count {
            removeLast(self.count - count)
        }
    }
}
