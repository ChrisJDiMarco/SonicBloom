import CoreAudio
import Foundation

public struct AudioDeviceSnapshot: Codable, Equatable, Identifiable, Sendable {
    public var id: UInt32
    public var name: String
    public var inputChannels: Int
    public var outputChannels: Int
    public var sampleRate: Double
    public var isVirtual: Bool

    public init(
        id: UInt32,
        name: String,
        inputChannels: Int,
        outputChannels: Int,
        sampleRate: Double,
        isVirtual: Bool
    ) {
        self.id = id
        self.name = name
        self.inputChannels = inputChannels
        self.outputChannels = outputChannels
        self.sampleRate = sampleRate
        self.isVirtual = isVirtual
    }

    public var isSonicBloomBridge: Bool {
        name == "SonicBloom Output" && inputChannels >= 2 && outputChannels >= 2
    }

    public var isUsableBridgeInput: Bool {
        isSonicBloomBridge
    }

    public var isUsablePhysicalOutput: Bool {
        outputChannels >= 2 && !isVirtual
    }
}

public enum AudioInstallHealth: String, Codable, Equatable, Sendable {
    case notInstalled
    case needsPermission
    case installed
    case active
    case degraded
}

public struct AudioRouteState: Codable, Equatable, Sendable {
    public var virtualDeviceName: String
    public var bridgeInputDeviceID: UInt32?
    public var bridgeInputDeviceName: String?
    public var selectedPhysicalOutputID: UInt32?
    public var selectedPhysicalOutputName: String?
    public var sampleRate: Double
    public var channels: Int
    public var bufferSize: Int
    public var installHealth: AudioInstallHealth
    public var statusMessage: String

    public var isProcessingAvailable: Bool {
        installHealth == .active || installHealth == .installed
    }

    public static let `default` = AudioRouteState(
        virtualDeviceName: "SonicBloom Output",
        bridgeInputDeviceID: nil,
        bridgeInputDeviceName: nil,
        selectedPhysicalOutputID: nil,
        selectedPhysicalOutputName: nil,
        sampleRate: 48_000,
        channels: 2,
        bufferSize: 64,
        installHealth: .notInstalled,
        statusMessage: "Install SonicBloom Output, then choose a physical stereo output."
    )

    public var estimatedLatencyMS: Double {
        guard sampleRate > 0 else { return 0 }
        return Double(max(bufferSize, 0) * 2) / sampleRate * 1_000
    }
}

public struct AudioBridgeSelection: Equatable, Sendable {
    public var input: AudioDeviceSnapshot
    public var output: AudioDeviceSnapshot

    public init(input: AudioDeviceSnapshot, output: AudioDeviceSnapshot) {
        self.input = input
        self.output = output
    }
}

public enum AudioRoutePlanner {
    public static func state(devices: [AudioDeviceSnapshot], defaultOutputDeviceID: UInt32?) -> AudioRouteState {
        guard let selection = selection(devices: devices, defaultOutputDeviceID: defaultOutputDeviceID) else {
            return .default
        }

        return AudioRouteState(
            virtualDeviceName: "SonicBloom Output",
            bridgeInputDeviceID: selection.input.id,
            bridgeInputDeviceName: selection.input.name,
            selectedPhysicalOutputID: selection.output.id,
            selectedPhysicalOutputName: selection.output.name,
            sampleRate: selection.input.sampleRate,
            channels: min(selection.input.inputChannels, selection.output.outputChannels),
            bufferSize: 64,
            installHealth: .installed,
            statusMessage: "Ready: \(selection.input.name) -> \(selection.output.name)"
        )
    }

    public static func selection(devices: [AudioDeviceSnapshot], defaultOutputDeviceID: UInt32?) -> AudioBridgeSelection? {
        guard let input = devices.first(where: \.isUsableBridgeInput),
              let output = preferredPhysicalOutput(devices: devices, defaultOutputDeviceID: defaultOutputDeviceID) else {
            return nil
        }
        return AudioBridgeSelection(input: input, output: output)
    }

    private static func preferredPhysicalOutput(devices: [AudioDeviceSnapshot], defaultOutputDeviceID: UInt32?) -> AudioDeviceSnapshot? {
        if let defaultOutputDeviceID,
           let defaultOutput = devices.first(where: { $0.id == defaultOutputDeviceID && $0.isUsablePhysicalOutput }) {
            return defaultOutput
        }

        return devices.first(where: \.isUsablePhysicalOutput)
    }
}

public enum AudioEngineCommand: Equatable, Sendable {
    case start
    case stop
    case bypass(Bool)
    case setPreset(DSPPreset)
    case setOutputDevice(String)
    case setSampleRate(Double)
    case resetAfterDeviceChange
}

public enum AudioRouteError: Error, Equatable, Sendable {
    case virtualDriverUnavailable(String)
    case bridgeUnavailable(String)
    case coreAudioFailed(String, Int32)
    case installerFailed(String)
}

extension AudioRouteError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .virtualDriverUnavailable(let message), .bridgeUnavailable(let message), .installerFailed(let message):
            return message
        case .coreAudioFailed(let message, let status):
            return "\(message) Core Audio status: \(status)."
        }
    }
}

public protocol AudioRouteManaging {
    func currentState() -> AudioRouteState
    func preferredBridgeSelection() -> AudioBridgeSelection?
    func activateBridgeSystemOutput() throws -> AudioBridgeSelection
    func installVirtualOutputDevice() throws
    func restorePreviousSystemOutput() throws
    func handle(_ command: AudioEngineCommand) throws
}

public final class CoreAudioRouteManager: AudioRouteManaging, @unchecked Sendable {
    private let inventory: CoreAudioDeviceInventory
    private let lock = NSLock()
    private var previousOutputDeviceID: UInt32?

    public init(inventory: CoreAudioDeviceInventory = CoreAudioDeviceInventory()) {
        self.inventory = inventory
    }

    public func currentState() -> AudioRouteState {
        AudioRoutePlanner.state(
            devices: inventory.devices(),
            defaultOutputDeviceID: inventory.defaultOutputDeviceID()
        )
    }

    public func preferredBridgeSelection() -> AudioBridgeSelection? {
        AudioRoutePlanner.selection(
            devices: inventory.devices(),
            defaultOutputDeviceID: inventory.defaultOutputDeviceID()
        )
    }

    public func activateBridgeSystemOutput() throws -> AudioBridgeSelection {
        guard var selection = preferredBridgeSelection() else {
            throw AudioRouteError.bridgeUnavailable("SonicBloom Output and a physical stereo output are required before processing can start.")
        }

        if selection.output.sampleRate > 0 {
            do {
                try inventory.setNominalSampleRate(deviceID: selection.input.id, sampleRate: selection.output.sampleRate)
                selection.input.sampleRate = selection.output.sampleRate
            } catch {
                // Keep routing alive; AVAudioEngine can still resample if a device rejects the rate.
            }
        }

        let currentDefault = inventory.defaultOutputDeviceID()
        if currentDefault != selection.input.id {
            lock.lock()
            previousOutputDeviceID = currentDefault
            lock.unlock()
        }
        try inventory.setDefaultOutputDeviceID(selection.input.id)
        return selection
    }

    public func installVirtualOutputDevice() throws {
        guard let driverURL = SonicBloomHALInstaller.bundledDriverURL() else {
            throw AudioRouteError.virtualDriverUnavailable("SonicBloomHAL.driver was not found in the app bundle. Rebuild the app, then install again.")
        }
        try SonicBloomHALInstaller.install(driverURL: driverURL)
    }

    public func restorePreviousSystemOutput() throws {
        lock.lock()
        let previousOutputDeviceID = previousOutputDeviceID
        lock.unlock()

        guard let previousOutputDeviceID else {
            return
        }
        try inventory.setDefaultOutputDeviceID(previousOutputDeviceID)
        lock.lock()
        self.previousOutputDeviceID = nil
        lock.unlock()
    }

    public func handle(_ command: AudioEngineCommand) throws {
        switch command {
        case .start:
            _ = try activateBridgeSystemOutput()
        case .stop:
            try restorePreviousSystemOutput()
        case .bypass, .setPreset, .setOutputDevice, .setSampleRate, .resetAfterDeviceChange:
            return
        }
    }
}

public enum SonicBloomHALInstaller {
    static let targetPath = "/Library/Audio/Plug-Ins/HAL/SonicBloomHAL.driver"

    public static func bundledDriverURL(fileManager: FileManager = .default) -> URL? {
        let candidates = [
            Bundle.main.url(forResource: "SonicBloomHAL", withExtension: "driver"),
            Bundle.main.resourceURL?.appendingPathComponent("SonicBloomHAL.driver"),
            URL(fileURLWithPath: fileManager.currentDirectoryPath).appendingPathComponent("BuildAssets/SonicBloomHAL.driver")
        ].compactMap { $0 }

        return candidates.first { fileManager.fileExists(atPath: $0.path) }
    }

    static func installScript(driverURL: URL) -> String {
        let source = shellQuote(driverURL.path)
        return """
        /bin/rm -rf \(targetPath)
        /usr/bin/ditto \(source) \(targetPath)
        /usr/sbin/chown -R root:wheel \(targetPath)
        /bin/chmod -R go-w \(targetPath)
        /usr/bin/killall coreaudiod || true
        """
    }

    public static func install(driverURL: URL) throws {
        let script = installScript(driverURL: driverURL)
        let appleScript = "do shell script \(appleScriptLiteral(script)) with administrator privileges"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", appleScript]

        let errorPipe = Pipe()
        process.standardError = errorPipe
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            throw AudioRouteError.installerFailed("Unable to start the SonicBloom Output installer: \(error.localizedDescription)")
        }

        guard process.terminationStatus == 0 else {
            let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
            let message = String(data: errorData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
            throw AudioRouteError.installerFailed(message?.isEmpty == false ? message! : "SonicBloom Output installation was canceled or failed.")
        }
    }

    private static func shellQuote(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\"'\"'"))'"
    }

    private static func appleScriptLiteral(_ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }
}

public final class CoreAudioDeviceInventory {
    public init() {}

    public func devices() -> [AudioDeviceSnapshot] {
        deviceIDs().compactMap(deviceSnapshot)
    }

    public func defaultOutputDeviceID() -> UInt32? {
        getDeviceID(selector: kAudioHardwarePropertyDefaultOutputDevice)
    }

    public func setDefaultOutputDeviceID(_ deviceID: UInt32) throws {
        try setDeviceID(deviceID, selector: kAudioHardwarePropertyDefaultOutputDevice)
        try setDeviceID(deviceID, selector: kAudioHardwarePropertyDefaultSystemOutputDevice)
    }

    public func setNominalSampleRate(deviceID: UInt32, sampleRate: Double) throws {
        var rate = Float64(sampleRate)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectSetPropertyData(
            AudioDeviceID(deviceID),
            &address,
            0,
            nil,
            UInt32(MemoryLayout<Float64>.size),
            &rate
        )
        guard status == noErr else {
            throw AudioRouteError.coreAudioFailed("Unable to set SonicBloom Output sample rate.", status)
        }
    }

    private func deviceIDs() -> [UInt32] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr else {
            return []
        }

        let count = Int(size) / MemoryLayout<AudioDeviceID>.size
        var devices = Array(repeating: AudioDeviceID(0), count: count)
        let status = devices.withUnsafeMutableBufferPointer { pointer in
            AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject),
                &address,
                0,
                nil,
                &size,
                pointer.baseAddress!
            )
        }
        guard status == noErr else {
            return []
        }
        return devices
    }

    private func deviceSnapshot(id: UInt32) -> AudioDeviceSnapshot? {
        guard let name = stringProperty(deviceID: id, selector: kAudioObjectPropertyName) else {
            return nil
        }

        return AudioDeviceSnapshot(
            id: id,
            name: name,
            inputChannels: channelCount(deviceID: id, scope: kAudioDevicePropertyScopeInput),
            outputChannels: channelCount(deviceID: id, scope: kAudioDevicePropertyScopeOutput),
            sampleRate: sampleRate(deviceID: id),
            isVirtual: isVirtual(name: name)
        )
    }

    private func isVirtual(name: String) -> Bool {
        ["SonicBloom", "BlackHole", "BoomAudio", "ZoomAudioDevice", "CleanShot", "Parrot", "quantum"].contains {
            name.localizedCaseInsensitiveContains($0)
        }
    }

    private func getDeviceID(selector: AudioObjectPropertySelector) -> UInt32? {
        var deviceID = AudioDeviceID(0)
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &size,
            &deviceID
        )
        return status == noErr && deviceID != 0 ? UInt32(deviceID) : nil
    }

    private func setDeviceID(_ deviceID: UInt32, selector: AudioObjectPropertySelector) throws {
        var resolvedDeviceID = AudioDeviceID(deviceID)
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectSetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            UInt32(MemoryLayout<AudioDeviceID>.size),
            &resolvedDeviceID
        )
        guard status == noErr else {
            throw AudioRouteError.coreAudioFailed("Unable to set default output device.", status)
        }
    }

    private func stringProperty(deviceID: UInt32, selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size = UInt32(MemoryLayout<CFString?>.size)
        let pointer = UnsafeMutablePointer<CFString?>.allocate(capacity: 1)
        pointer.initialize(to: nil)
        defer {
            pointer.deinitialize(count: 1)
            pointer.deallocate()
        }

        let status = AudioObjectGetPropertyData(
            AudioDeviceID(deviceID),
            &address,
            0,
            nil,
            &size,
            pointer
        )
        guard status == noErr, let value = pointer.pointee else {
            return nil
        }
        return value as String
    }

    private func sampleRate(deviceID: UInt32) -> Double {
        var rate = Float64(48_000)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size = UInt32(MemoryLayout<Float64>.size)
        let status = AudioObjectGetPropertyData(
            AudioDeviceID(deviceID),
            &address,
            0,
            nil,
            &size,
            &rate
        )
        return status == noErr ? rate : 48_000
    }

    private func channelCount(deviceID: UInt32, scope: AudioObjectPropertyScope) -> Int {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioDeviceID(deviceID), &address, 0, nil, &size) == noErr, size > 0 else {
            return 0
        }

        let rawPointer = UnsafeMutableRawPointer.allocate(
            byteCount: Int(size),
            alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer { rawPointer.deallocate() }

        let bufferList = rawPointer.bindMemory(to: AudioBufferList.self, capacity: 1)
        guard AudioObjectGetPropertyData(AudioDeviceID(deviceID), &address, 0, nil, &size, bufferList) == noErr else {
            return 0
        }

        return UnsafeMutableAudioBufferListPointer(bufferList).reduce(0) { count, buffer in
            count + Int(buffer.mNumberChannels)
        }
    }
}
