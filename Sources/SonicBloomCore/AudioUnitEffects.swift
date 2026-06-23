import AudioToolbox
import Foundation

public struct AudioUnitEffectDescriptor: Codable, Equatable, Identifiable, Sendable {
    public var name: String
    public var manufacturerName: String
    public var componentType: OSType
    public var componentSubType: OSType
    public var componentManufacturer: OSType

    public init(
        name: String,
        manufacturerName: String,
        componentType: OSType,
        componentSubType: OSType,
        componentManufacturer: OSType
    ) {
        self.name = name
        self.manufacturerName = manufacturerName
        self.componentType = componentType
        self.componentSubType = componentSubType
        self.componentManufacturer = componentManufacturer
    }

    public var id: String {
        "\(componentTypeCode)-\(componentSubTypeCode)-\(componentManufacturerCode)"
    }

    public var componentTypeCode: String {
        Self.fourCharacterCode(componentType)
    }

    public var componentSubTypeCode: String {
        Self.fourCharacterCode(componentSubType)
    }

    public var componentManufacturerCode: String {
        Self.fourCharacterCode(componentManufacturer)
    }

    public var componentDescription: AudioComponentDescription {
        AudioComponentDescription(
            componentType: componentType,
            componentSubType: componentSubType,
            componentManufacturer: componentManufacturer,
            componentFlags: 0,
            componentFlagsMask: 0
        )
    }

    public static func fourCharacterCode(_ value: OSType) -> String {
        let bytes = [
            UInt8((value >> 24) & 0xff),
            UInt8((value >> 16) & 0xff),
            UInt8((value >> 8) & 0xff),
            UInt8(value & 0xff)
        ]
        return String(bytes: bytes.map { (32...126).contains($0) ? $0 : 63 }, encoding: .ascii) ?? "????"
    }
}

public struct AudioUnitEffectHostPreflight {
    public typealias ComponentFinder = (inout AudioComponentDescription) -> AudioComponent?
    public typealias InstanceChecker = (AudioComponent) -> Bool

    private let componentFinder: ComponentFinder
    private let instanceChecker: InstanceChecker

    public init(
        componentFinder: @escaping ComponentFinder = { description in AudioComponentFindNext(nil, &description) },
        instanceChecker: @escaping InstanceChecker = Self.canInstantiate
    ) {
        self.componentFinder = componentFinder
        self.instanceChecker = instanceChecker
    }

    public func canLoad(_ effect: AudioUnitEffectDescriptor) -> Bool {
        var description = effect.componentDescription
        guard let component = componentFinder(&description) else { return false }
        return instanceChecker(component)
    }

    public static func canInstantiate(_ component: AudioComponent) -> Bool {
        var instance: AudioComponentInstance?
        let status = AudioComponentInstanceNew(component, &instance)
        guard status == noErr, let instance else { return false }
        AudioComponentInstanceDispose(instance)
        return true
    }
}

public struct AudioUnitEffectSlot: Codable, Equatable, Identifiable, Sendable {
    public var effect: AudioUnitEffectDescriptor
    public var isEnabled: Bool

    public init(effect: AudioUnitEffectDescriptor, isEnabled: Bool = true) {
        self.effect = effect
        self.isEnabled = isEnabled
    }

    public var id: String {
        effect.id
    }
}

public enum AudioUnitEffectCatalog {
    public static let supportedComponentTypes: [OSType] = [
        kAudioUnitType_Effect,
        kAudioUnitType_MusicEffect
    ]

    public static func isSupportedEffectType(_ componentType: OSType) -> Bool {
        supportedComponentTypes.contains(componentType)
    }

    public static func installedEffects() -> [AudioUnitEffectDescriptor] {
        supportedComponentTypes
            .flatMap(installedEffects(componentType:))
            .sorted { left, right in
                if left.name != right.name { return left.name < right.name }
                if left.manufacturerName != right.manufacturerName { return left.manufacturerName < right.manufacturerName }
                return left.id < right.id
            }
    }

    private static func installedEffects(componentType: OSType) -> [AudioUnitEffectDescriptor] {
        var description = AudioComponentDescription(
            componentType: componentType,
            componentSubType: 0,
            componentManufacturer: 0,
            componentFlags: 0,
            componentFlagsMask: 0
        )
        var component: AudioComponent?
        var descriptors: [AudioUnitEffectDescriptor] = []

        repeat {
            component = AudioComponentFindNext(component, &description)
            if let component, let descriptor = descriptor(for: component) {
                descriptors.append(descriptor)
            }
        } while component != nil

        return descriptors
    }

    private static func descriptor(for component: AudioComponent) -> AudioUnitEffectDescriptor? {
        var description = AudioComponentDescription()
        guard AudioComponentGetDescription(component, &description) == noErr,
              isSupportedEffectType(description.componentType) else {
            return nil
        }

        return AudioUnitEffectDescriptor(
            name: name(for: component),
            manufacturerName: AudioUnitEffectDescriptor.fourCharacterCode(description.componentManufacturer),
            componentType: description.componentType,
            componentSubType: description.componentSubType,
            componentManufacturer: description.componentManufacturer
        )
    }

    private static func name(for component: AudioComponent) -> String {
        var unmanagedName: Unmanaged<CFString>?
        if AudioComponentCopyName(component, &unmanagedName) == noErr,
           let name = unmanagedName?.takeRetainedValue() as String?,
           !name.isEmpty {
            return name
        }
        return "Audio Unit"
    }
}
