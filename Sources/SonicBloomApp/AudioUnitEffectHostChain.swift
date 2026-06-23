import AudioToolbox
import Foundation
import SonicBloomCore

final class AudioUnitEffectHostChain {
    typealias Loader = (AudioUnitEffectDescriptor, Double) -> AnyObject?

    private let loader: Loader
    private var loadedEffects: [AnyObject] = []
    private(set) var activeEffectIDs: [String] = []

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
        for effect in effects {
            guard let loaded = loader(effect, sampleRate) else { continue }
            nextLoaded.append(loaded)
            nextIDs.append(effect.id)
        }

        loadedEffects = nextLoaded
        activeEffectIDs = nextIDs
    }

    func reset() {
        loadedEffects = []
        activeEffectIDs = []
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
              AudioUnitSetProperty(instance, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 0, &format, size) == noErr,
              AudioUnitInitialize(instance) == noErr else {
            AudioComponentInstanceDispose(instance)
            return nil
        }

        return AudioUnitEffectInstance(instance)
    }
}

private final class AudioUnitEffectInstance {
    private let instance: AudioComponentInstance

    init(_ instance: AudioComponentInstance) {
        self.instance = instance
    }

    deinit {
        AudioUnitUninitialize(instance)
        AudioComponentInstanceDispose(instance)
    }
}
