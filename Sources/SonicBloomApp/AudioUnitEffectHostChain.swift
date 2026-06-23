import AudioToolbox
import Foundation
import SonicBloomCore

protocol AudioUnitEffectProcessing: AnyObject {
    func process(left: inout [Float], right: inout [Float], frameCount: Int) -> Bool
}

final class AudioUnitEffectHostChain {
    typealias Loader = (AudioUnitEffectDescriptor, Double) -> AnyObject?

    private let loader: Loader
    private let lock = NSLock()
    private var loadedEffects: [AnyObject] = []
    private(set) var activeEffectIDs: [String] = []
    private(set) var failedEffectIDs: [String] = []

    init(loader: @escaping Loader = AudioUnitEffectHostChain.loadEffect) {
        self.loader = loader
    }

    func update(slots: [AudioUnitEffectSlot], sampleRate: Double) {
        let effects = slots
            .filter(\.isEnabled)
            .map(\.effect)
            .filter { AudioUnitEffectCatalog.isSupportedEffectType($0.componentType) }

        var nextLoaded: [AnyObject] = []
        var nextIDs: [String] = []
        var nextFailedIDs: [String] = []
        for effect in effects {
            guard let loaded = loader(effect, sampleRate) else {
                nextFailedIDs.append(effect.id)
                continue
            }
            nextLoaded.append(loaded)
            nextIDs.append(effect.id)
        }

        lock.lock()
        loadedEffects = nextLoaded
        activeEffectIDs = nextIDs
        failedEffectIDs = nextFailedIDs
        lock.unlock()
    }

    func process(left: inout [Float], right: inout [Float], frameCount: Int) {
        lock.lock()
        let effects = loadedEffects
        lock.unlock()

        for effect in effects {
            guard let effect = effect as? AudioUnitEffectProcessing else { continue }
            _ = effect.process(left: &left, right: &right, frameCount: frameCount)
        }
    }

    func reset() {
        lock.lock()
        loadedEffects = []
        activeEffectIDs = []
        failedEffectIDs = []
        lock.unlock()
    }

    private static func loadEffect(_ effect: AudioUnitEffectDescriptor, sampleRate: Double) -> AnyObject? {
        var description = effect.componentDescription
        guard let component = AudioComponentFindNext(nil, &description) else { return nil }

        var instance: AudioComponentInstance?
        guard AudioComponentInstanceNew(component, &instance) == noErr, let instance else { return nil }

        var format = AudioStreamBasicDescription(
            mSampleRate: max(sampleRate, 1),
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked | kAudioFormatFlagIsNonInterleaved,
            mBytesPerPacket: UInt32(MemoryLayout<Float>.size),
            mFramesPerPacket: 1,
            mBytesPerFrame: UInt32(MemoryLayout<Float>.size),
            mChannelsPerFrame: 2,
            mBitsPerChannel: 32,
            mReserved: 0
        )
        let size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        guard AudioUnitSetProperty(instance, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0, &format, size) == noErr,
              AudioUnitSetProperty(instance, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 0, &format, size) == noErr else {
            AudioComponentInstanceDispose(instance)
            return nil
        }

        let effect = AudioUnitEffectInstance(instance)
        guard effect.initialize() else { return nil }
        return effect
    }
}

private final class AudioUnitEffectInstance: AudioUnitEffectProcessing {
    private let instance: AudioComponentInstance
    private var inputLeft: UnsafePointer<Float>?
    private var inputRight: UnsafePointer<Float>?
    private var outputLeft: [Float] = []
    private var outputRight: [Float] = []
    private var sampleTime: Float64 = 0
    private let renderBufferList = AudioUnitEffectInstance.makeStereoBufferList()
    private var isInitialized = false

    private static let inputCallback: AURenderCallback = { refCon, _, _, _, frameCount, ioData in
        let effect = Unmanaged<AudioUnitEffectInstance>.fromOpaque(refCon).takeUnretainedValue()
        return effect.provideInput(ioData, frameCount: Int(frameCount))
    }

    init(_ instance: AudioComponentInstance) {
        self.instance = instance
        var callback = AURenderCallbackStruct(
            inputProc: Self.inputCallback,
            inputProcRefCon: Unmanaged.passUnretained(self).toOpaque()
        )
        AudioUnitSetProperty(
            instance,
            kAudioUnitProperty_SetRenderCallback,
            kAudioUnitScope_Input,
            0,
            &callback,
            UInt32(MemoryLayout<AURenderCallbackStruct>.size)
        )
    }

    func initialize() -> Bool {
        isInitialized = AudioUnitInitialize(instance) == noErr
        return isInitialized
    }

    func process(left: inout [Float], right: inout [Float], frameCount: Int) -> Bool {
        let count = min(frameCount, left.count, right.count)
        guard count > 0 else { return true }

        outputLeft.resizeAudioBuffer(to: count, reserveAtLeast: count)
        outputRight.resizeAudioBuffer(to: count, reserveAtLeast: count)

        return left.withUnsafeBufferPointer { leftInput in
            right.withUnsafeBufferPointer { rightInput in
                outputLeft.withUnsafeMutableBufferPointer { leftOutput in
                    outputRight.withUnsafeMutableBufferPointer { rightOutput in
                        inputLeft = leftInput.baseAddress
                        inputRight = rightInput.baseAddress
                        defer {
                            inputLeft = nil
                            inputRight = nil
                        }

                        var flags = AudioUnitRenderActionFlags()
                        var timestamp = AudioTimeStamp()
                        timestamp.mSampleTime = sampleTime
                        timestamp.mFlags = AudioTimeStampFlags(rawValue: 1)

                        let byteSize = UInt32(count * MemoryLayout<Float>.size)
                        UnsafeMutableAudioBufferListPointer(renderBufferList)[0] = AudioBuffer(
                            mNumberChannels: 1,
                            mDataByteSize: byteSize,
                            mData: leftOutput.baseAddress
                        )
                        UnsafeMutableAudioBufferListPointer(renderBufferList)[1] = AudioBuffer(
                            mNumberChannels: 1,
                            mDataByteSize: byteSize,
                            mData: rightOutput.baseAddress
                        )

                        let status = AudioUnitRender(instance, &flags, &timestamp, 0, UInt32(count), renderBufferList)

                        sampleTime += Float64(count)
                        guard status == noErr else { return false }
                        for index in 0..<count {
                            left[index] = outputLeft[index]
                            right[index] = outputRight[index]
                        }
                        return true
                    }
                }
            }
        }
    }

    private func provideInput(_ ioData: UnsafeMutablePointer<AudioBufferList>?, frameCount: Int) -> OSStatus {
        guard let inputLeft, let inputRight, let ioData else { return noErr }
        let buffers = UnsafeMutableAudioBufferListPointer(ioData)
        guard !buffers.isEmpty else { return noErr }

        if buffers.count == 1 {
            copyInterleavedInput(to: buffers[0], frameCount: frameCount, inputLeft: inputLeft, inputRight: inputRight)
        } else {
            copyPlanarInput(to: buffers[0], frameCount: frameCount, input: inputLeft)
            copyPlanarInput(to: buffers[1], frameCount: frameCount, input: inputRight)
        }
        return noErr
    }

    private func copyPlanarInput(to buffer: AudioBuffer, frameCount: Int, input: UnsafePointer<Float>) {
        guard let data = buffer.mData?.assumingMemoryBound(to: Float.self) else { return }
        let count = min(frameCount, Int(buffer.mDataByteSize) / MemoryLayout<Float>.size)
        for index in 0..<count {
            data[index] = input[index]
        }
    }

    private func copyInterleavedInput(
        to buffer: AudioBuffer,
        frameCount: Int,
        inputLeft: UnsafePointer<Float>,
        inputRight: UnsafePointer<Float>
    ) {
        guard let data = buffer.mData?.assumingMemoryBound(to: Float.self) else { return }
        let channels = max(Int(buffer.mNumberChannels), 1)
        let frames = min(frameCount, Int(buffer.mDataByteSize) / MemoryLayout<Float>.size / channels)
        for frame in 0..<frames {
            let base = frame * channels
            data[base] = inputLeft[frame]
            if channels > 1 {
                data[base + 1] = inputRight[frame]
            }
        }
    }

    private static func makeStereoBufferList() -> UnsafeMutablePointer<AudioBufferList> {
        let byteCount = MemoryLayout<AudioBufferList>.size + MemoryLayout<AudioBuffer>.size
        let rawPointer = UnsafeMutableRawPointer.allocate(
            byteCount: byteCount,
            alignment: MemoryLayout<AudioBufferList>.alignment
        )
        let bufferList = rawPointer.bindMemory(to: AudioBufferList.self, capacity: 1)
        bufferList.pointee.mNumberBuffers = 2
        return bufferList
    }

    deinit {
        if isInitialized {
            AudioUnitUninitialize(instance)
        }
        AudioComponentInstanceDispose(instance)
        UnsafeMutableRawPointer(renderBufferList).deallocate()
    }
}
