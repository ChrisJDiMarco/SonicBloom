import CoreAudio
import Foundation
import SonicBloomCore
import SonicBloomDSP

private let sonicBloomCaptureIOProc: AudioDeviceIOProc = { _, _, inputData, _, _, _, clientData in
    guard let clientData else { return noErr }
    let bridge = Unmanaged<SonicBloomAudioBridge>.fromOpaque(clientData).takeUnretainedValue()
    bridge.handleInputData(inputData)
    return noErr
}

private let sonicBloomPlaybackIOProc: AudioDeviceIOProc = { _, _, _, _, outputData, _, clientData in
    guard let clientData else { return noErr }
    let bridge = Unmanaged<SonicBloomAudioBridge>.fromOpaque(clientData).takeUnretainedValue()
    bridge.renderOutput(outputData)
    return noErr
}

final class SonicBloomAudioBridge: @unchecked Sendable {
    private static let ringCapacity = 8192
    private static let maxRealtimeScratchFrames = 2048

    private let settingsLock = NSLock()

    private var processor: SonicBloomProcessor?
    private var ring: OpaquePointer?
    private var configBuffer: OpaquePointer?
    private var sampleRate = 48_000.0
    private var preset = DSPPreset.cleanLoud
    private var bypass = false
    private var loudnessMatchedBypass = false
    private var bufferFrameSize = AudioSyncMode.video.preferredBufferFrameSize
    private var captureDeviceID: AudioDeviceID?
    private var playbackDeviceID: AudioDeviceID?
    private var captureIOProcID: AudioDeviceIOProcID?
    private var playbackIOProcID: AudioDeviceIOProcID?
    private var isCaptureStarted = false
    private var isPlaybackStarted = false
    private var scratchLeft: [Float] = []
    private var scratchRight: [Float] = []
    private var processedLeft: [Float] = []
    private var processedRight: [Float] = []
    private var framesSinceMeterUpdate = 0
    private var pendingMeter = MeterAccumulator()

    var meterHandler: (@Sendable (DSPMeter) -> Void)?

    var isRunning: Bool {
        isCaptureStarted && isPlaybackStarted
    }

    func update(preset: DSPPreset, bypass: Bool, loudnessMatchedBypass: Bool = false) {
        settingsLock.lock()
        self.preset = preset
        self.bypass = bypass
        self.loudnessMatchedBypass = loudnessMatchedBypass
        let currentSampleRate = sampleRate
        let buffer = configBuffer
        settingsLock.unlock()

        if let buffer {
            var config = preset.makeDSPConfig(sampleRate: currentSampleRate, bypass: bypass, loudnessMatchedBypass: loudnessMatchedBypass)
            SonicBloomDSPConfigBufferWrite(buffer, &config)
        }
    }

    func start(
        inputDeviceID: UInt32,
        outputDeviceID: UInt32,
        preset: DSPPreset,
        bypass: Bool,
        loudnessMatchedBypass: Bool,
        preferredBufferFrameSize: UInt32
    ) throws {
        stop()

        let inputID = AudioDeviceID(inputDeviceID)
        let outputID = AudioDeviceID(outputDeviceID)
        sampleRate = deviceSampleRate(outputID)
        bufferFrameSize = preferredBufferFrameSize
        try setDeviceSampleRate(inputID, sampleRate)
        applyBufferPreference(inputDeviceID: inputDeviceID, outputDeviceID: outputDeviceID, frameSize: preferredBufferFrameSize)

        processor = SonicBloomProcessor(sampleRate: sampleRate)
        ring = SonicBloomRingBufferCreate(Self.ringCapacity)
        configBuffer = SonicBloomDSPConfigBufferCreate()
        prewarmRealtimeBuffers()
        resetRing()
        update(preset: preset, bypass: bypass, loudnessMatchedBypass: loudnessMatchedBypass)

        do {
            try startPlayback(deviceID: outputID)
            try startCapture(deviceID: inputID)
        } catch {
            stop()
            throw error
        }
    }

    func applyBufferPreference(inputDeviceID: UInt32, outputDeviceID: UInt32, frameSize: UInt32) {
        try? setDeviceBufferFrameSize(AudioDeviceID(inputDeviceID), frameSize)
        try? setDeviceBufferFrameSize(AudioDeviceID(outputDeviceID), frameSize)
    }

    func scheduleBufferPreferenceRetries(inputDeviceID: UInt32, outputDeviceID: UInt32, frameSize: UInt32) {
        for delay in [0.15, 0.5, 1.0] {
            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.applyBufferPreference(inputDeviceID: inputDeviceID, outputDeviceID: outputDeviceID, frameSize: frameSize)
            }
        }
    }

    func stop() {
        stopCapture()
        stopPlayback()

        settingsLock.lock()
        let configBufferToDestroy = configBuffer
        configBuffer = nil
        settingsLock.unlock()

        processor = nil
        scratchLeft.removeAll(keepingCapacity: true)
        scratchRight.removeAll(keepingCapacity: true)
        processedLeft.removeAll(keepingCapacity: true)
        processedRight.removeAll(keepingCapacity: true)
        framesSinceMeterUpdate = 0
        pendingMeter.reset()
        if let ring {
            SonicBloomRingBufferDestroy(ring)
            self.ring = nil
        }
        if let configBufferToDestroy {
            SonicBloomDSPConfigBufferDestroy(configBufferToDestroy)
        }
    }

    private func startCapture(deviceID: AudioDeviceID) throws {
        let clientData = Unmanaged.passUnretained(self).toOpaque()
        var procID: AudioDeviceIOProcID?
        var status = AudioDeviceCreateIOProcID(deviceID, sonicBloomCaptureIOProc, clientData, &procID)
        guard status == noErr, let procID else {
            throw AudioRouteError.coreAudioFailed("Unable to create SonicBloom input IOProc.", status)
        }

        captureDeviceID = deviceID
        captureIOProcID = procID
        status = AudioDeviceStart(deviceID, procID)
        guard status == noErr else {
            AudioDeviceDestroyIOProcID(deviceID, procID)
            captureDeviceID = nil
            captureIOProcID = nil
            throw AudioRouteError.coreAudioFailed("Unable to start SonicBloom input capture.", status)
        }

        isCaptureStarted = true
    }

    private func startPlayback(deviceID: AudioDeviceID) throws {
        let clientData = Unmanaged.passUnretained(self).toOpaque()
        var procID: AudioDeviceIOProcID?
        var status = AudioDeviceCreateIOProcID(deviceID, sonicBloomPlaybackIOProc, clientData, &procID)
        guard status == noErr, let procID else {
            throw AudioRouteError.coreAudioFailed("Unable to create physical output IOProc.", status)
        }

        playbackDeviceID = deviceID
        playbackIOProcID = procID
        status = AudioDeviceStart(deviceID, procID)
        guard status == noErr else {
            AudioDeviceDestroyIOProcID(deviceID, procID)
            playbackDeviceID = nil
            playbackIOProcID = nil
            throw AudioRouteError.coreAudioFailed("Unable to start physical output playback.", status)
        }

        isPlaybackStarted = true
    }

    private func stopCapture() {
        let deviceID = captureDeviceID
        let procID = captureIOProcID
        let wasStarted = isCaptureStarted
        captureDeviceID = nil
        captureIOProcID = nil
        isCaptureStarted = false

        guard let deviceID, let procID else { return }
        if wasStarted {
            AudioDeviceStop(deviceID, procID)
        }
        AudioDeviceDestroyIOProcID(deviceID, procID)
    }

    private func stopPlayback() {
        let deviceID = playbackDeviceID
        let procID = playbackIOProcID
        let wasStarted = isPlaybackStarted
        playbackDeviceID = nil
        playbackIOProcID = nil
        isPlaybackStarted = false

        guard let deviceID, let procID else { return }
        if wasStarted {
            AudioDeviceStop(deviceID, procID)
        }
        AudioDeviceDestroyIOProcID(deviceID, procID)
    }

    fileprivate func handleInputData(_ inputData: UnsafePointer<AudioBufferList>) {
        guard let processor, let configBuffer, readInputData(inputData) else { return }
        var config = SonicBloomDSPConfig()
        guard SonicBloomDSPConfigBufferRead(configBuffer, &config) != 0 else { return }

        let frameCount = scratchLeft.count
        let meter = processor.process(
            left: scratchLeft,
            right: scratchRight,
            outputLeft: &processedLeft,
            outputRight: &processedRight,
            config: config
        )

        writeOutput(left: processedLeft, right: processedRight, maxQueuedFrames: max(frameCount, Int(bufferFrameSize) * 2))
        publishMeterIfNeeded(meter, frameCount: frameCount)
    }

    fileprivate func renderOutput(_ outputData: UnsafeMutablePointer<AudioBufferList>) {
        let buffers = UnsafeMutableAudioBufferListPointer(outputData)
        guard let ring else {
            clear(buffers)
            return
        }

        if buffers.count == 1 {
            renderInterleaved(buffers[0], ring: ring)
            return
        }

        guard buffers.count >= 2,
              let leftData = buffers[0].mData?.assumingMemoryBound(to: Float.self),
              let rightData = buffers[1].mData?.assumingMemoryBound(to: Float.self) else {
            clear(buffers)
            return
        }

        let frameCount = min(
            Int(buffers[0].mDataByteSize) / MemoryLayout<Float>.size,
            Int(buffers[1].mDataByteSize) / MemoryLayout<Float>.size
        )
        SonicBloomRingBufferRead(ring, leftData, rightData, frameCount)

        for bufferIndex in 2..<buffers.count {
            clear(buffers[bufferIndex])
        }
    }

    private func renderInterleaved(_ buffer: AudioBuffer, ring: OpaquePointer) {
        let channels = max(Int(buffer.mNumberChannels), 1)
        let samples = Int(buffer.mDataByteSize) / MemoryLayout<Float>.size
        guard let data = buffer.mData?.assumingMemoryBound(to: Float.self) else { return }
        let frameCount = samples / channels

        SonicBloomRingBufferReadInterleaved(ring, data, frameCount, channels)
    }

    private func writeOutput(left: [Float], right: [Float], maxQueuedFrames: Int) {
        guard let ring else { return }
        _ = left.withUnsafeBufferPointer { leftPointer in
            right.withUnsafeBufferPointer { rightPointer in
                SonicBloomRingBufferWrite(ring, leftPointer.baseAddress, rightPointer.baseAddress, left.count)
            }
        }
        SonicBloomRingBufferTrim(ring, max(1, maxQueuedFrames))
    }

    private func resetRing() {
        if let ring {
            SonicBloomRingBufferClear(ring)
        }
    }

    private func readInputData(_ inputData: UnsafePointer<AudioBufferList>) -> Bool {
        let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inputData))
        let frameCount = inputFrameCount(buffers)
        guard frameCount > 0 else { return false }

        scratchLeft.resizeAudioBuffer(to: frameCount, reserveAtLeast: Self.maxRealtimeScratchFrames)
        scratchRight.resizeAudioBuffer(to: frameCount, reserveAtLeast: Self.maxRealtimeScratchFrames)
        scratchLeft.withUnsafeMutableBufferPointer { $0.initialize(repeating: 0) }
        scratchRight.withUnsafeMutableBufferPointer { $0.initialize(repeating: 0) }

        if buffers.count == 1 {
            copyInterleavedInput(buffers[0], frameCount: frameCount)
        } else {
            copyPlanarInput(buffers[0], to: &scratchLeft, frameCount: frameCount)
            if buffers.count > 1 {
                copyPlanarInput(buffers[1], to: &scratchRight, frameCount: frameCount)
            } else {
                scratchRight = scratchLeft
            }
        }

        return true
    }

    private func inputFrameCount(_ buffers: UnsafeMutableAudioBufferListPointer) -> Int {
        buffers.reduce(0) { result, buffer in
            let channels = max(Int(buffer.mNumberChannels), 1)
            let samples = Int(buffer.mDataByteSize) / MemoryLayout<Float>.size
            return max(result, samples / channels)
        }
    }

    private func copyInterleavedInput(_ buffer: AudioBuffer, frameCount: Int) {
        let channels = max(Int(buffer.mNumberChannels), 1)
        guard let data = buffer.mData?.assumingMemoryBound(to: Float.self) else { return }

        for frame in 0..<frameCount {
            let base = frame * channels
            let left = data[base]
            scratchLeft[frame] = left
            scratchRight[frame] = channels > 1 ? data[base + 1] : left
        }
    }

    private func copyPlanarInput(_ buffer: AudioBuffer, to target: inout [Float], frameCount: Int) {
        guard let data = buffer.mData?.assumingMemoryBound(to: Float.self) else { return }

        let sampleCount = min(frameCount, Int(buffer.mDataByteSize) / MemoryLayout<Float>.size)
        for index in 0..<sampleCount {
            target[index] = data[index]
        }
    }

    private func prewarmRealtimeBuffers() {
        scratchLeft.resizeAudioBuffer(to: 0, reserveAtLeast: Self.maxRealtimeScratchFrames)
        scratchRight.resizeAudioBuffer(to: 0, reserveAtLeast: Self.maxRealtimeScratchFrames)
        processedLeft.resizeAudioBuffer(to: 0, reserveAtLeast: Self.maxRealtimeScratchFrames)
        processedRight.resizeAudioBuffer(to: 0, reserveAtLeast: Self.maxRealtimeScratchFrames)
    }

    private func clear(_ buffers: UnsafeMutableAudioBufferListPointer) {
        for buffer in buffers {
            clear(buffer)
        }
    }

    private func clear(_ buffer: AudioBuffer) {
        guard let data = buffer.mData?.assumingMemoryBound(to: Float.self) else { return }
        let samples = Int(buffer.mDataByteSize) / MemoryLayout<Float>.size
        for index in 0..<samples {
            data[index] = 0
        }
    }

    private func deviceSampleRate(_ deviceID: AudioDeviceID) -> Double {
        var rate = Float64(48_000)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size = UInt32(MemoryLayout<Float64>.size)
        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &rate)
        return status == noErr ? rate : 48_000
    }

    private func setDeviceSampleRate(_ deviceID: AudioDeviceID, _ sampleRate: Double) throws {
        var rate = Float64(sampleRate)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectSetPropertyData(deviceID, &address, 0, nil, UInt32(MemoryLayout<Float64>.size), &rate)
        guard status == noErr else {
            throw AudioRouteError.coreAudioFailed("Unable to match SonicBloom Output sample rate to the physical output.", status)
        }
    }

    private func setDeviceBufferFrameSize(_ deviceID: AudioDeviceID, _ frameSize: UInt32) throws {
        var frames = frameSize
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyBufferFrameSize,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectSetPropertyData(
            deviceID,
            &address,
            0,
            nil,
            UInt32(MemoryLayout<UInt32>.size),
            &frames
        )
        guard status == noErr else {
            throw AudioRouteError.coreAudioFailed("Unable to set low-latency buffer size.", status)
        }
    }

    private func publishMeterIfNeeded(_ meter: DSPMeter, frameCount: Int) {
        pendingMeter.add(meter, frameCount: frameCount)
        framesSinceMeterUpdate += frameCount
        let updateInterval = max(Int(sampleRate / 30), frameCount)
        guard framesSinceMeterUpdate >= updateInterval else { return }

        framesSinceMeterUpdate = 0
        meterHandler?(pendingMeter.snapshot())
        pendingMeter.reset()
    }
}

private struct MeterAccumulator {
    private var frames = 0
    private var inputPeak: Float = 0
    private var outputPeak: Float = 0
    private var gainReductionDB: Float = 0
    private var lowPower: Float = 0
    private var midPower: Float = 0
    private var highPower: Float = 0
    private var spectrumPower = Array(repeating: Float(0), count: DSPPreset.bandCount)
    private var limitedSamples: UInt32 = 0

    mutating func add(_ meter: DSPMeter, frameCount: Int) {
        let count = max(frameCount, 1)
        frames += count
        inputPeak = max(inputPeak, meter.inputPeak)
        outputPeak = max(outputPeak, meter.outputPeak)
        gainReductionDB = max(gainReductionDB, meter.gainReductionDB)
        lowPower += meter.lowEnergy * meter.lowEnergy * Float(count)
        midPower += meter.midEnergy * meter.midEnergy * Float(count)
        highPower += meter.highEnergy * meter.highEnergy * Float(count)
        for index in 0..<min(spectrumPower.count, meter.spectrumBands.count) {
            let value = meter.spectrumBands[index]
            spectrumPower[index] += value * value * Float(count)
        }
        limitedSamples &+= meter.limitedSamples
    }

    func snapshot() -> DSPMeter {
        let count = Float(max(frames, 1))
        let bands = spectrumPower.map { sqrt($0 / count) }
        return DSPMeter(
            inputPeak: inputPeak,
            outputPeak: outputPeak,
            gainReductionDB: gainReductionDB,
            lowEnergy: sqrt(lowPower / count),
            midEnergy: sqrt(midPower / count),
            highEnergy: sqrt(highPower / count),
            spectrumBands: bands,
            limitedSamples: limitedSamples
        )
    }

    mutating func reset() {
        frames = 0
        inputPeak = 0
        outputPeak = 0
        gainReductionDB = 0
        lowPower = 0
        midPower = 0
        highPower = 0
        for index in spectrumPower.indices {
            spectrumPower[index] = 0
        }
        limitedSamples = 0
    }
}
