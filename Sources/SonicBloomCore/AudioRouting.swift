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
    public var recoveryMessage: String?
    public var recoveryAttempts: Int

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

    public var recoverySummary: String {
        if installHealth == .degraded, recoveryAttempts >= 3 {
            let message = recoveryMessage ?? "Audio route degraded."
            return "Needs attention: \(message) (\(recoveryAttempts) attempts)"
        }
        return recoveryMessage ?? "No recovery needed"
    }

    public init(
        virtualDeviceName: String,
        bridgeInputDeviceID: UInt32?,
        bridgeInputDeviceName: String?,
        selectedPhysicalOutputID: UInt32?,
        selectedPhysicalOutputName: String?,
        sampleRate: Double,
        channels: Int,
        bufferSize: Int,
        installHealth: AudioInstallHealth,
        statusMessage: String,
        recoveryMessage: String? = nil,
        recoveryAttempts: Int = 0
    ) {
        self.virtualDeviceName = virtualDeviceName
        self.bridgeInputDeviceID = bridgeInputDeviceID
        self.bridgeInputDeviceName = bridgeInputDeviceName
        self.selectedPhysicalOutputID = selectedPhysicalOutputID
        self.selectedPhysicalOutputName = selectedPhysicalOutputName
        self.sampleRate = sampleRate
        self.channels = channels
        self.bufferSize = bufferSize
        self.installHealth = installHealth
        self.statusMessage = statusMessage
        self.recoveryMessage = recoveryMessage?.isEmpty == false ? recoveryMessage : nil
        self.recoveryAttempts = max(recoveryAttempts, 0)
    }

    public func recordingRecovery(_ message: String) -> AudioRouteState {
        var state = self
        state.recoveryMessage = message.isEmpty ? nil : message
        state.recoveryAttempts += 1
        return state
    }

    public func recordingDegradedRecovery(_ message: String) -> AudioRouteState {
        var state = recordingRecovery(message)
        state.installHealth = .degraded
        return state
    }

    public func needsBridgeRestart(after previous: AudioRouteState, bridgeWasRunning: Bool) -> Bool {
        guard bridgeWasRunning, isProcessingAvailable else { return false }
        return previous.installHealth == .degraded ||
            bridgeInputDeviceID != previous.bridgeInputDeviceID ||
            selectedPhysicalOutputID != previous.selectedPhysicalOutputID ||
            abs(sampleRate - previous.sampleRate) > 0.001 ||
            channels != previous.channels
    }

    private enum CodingKeys: String, CodingKey {
        case virtualDeviceName, bridgeInputDeviceID, bridgeInputDeviceName, selectedPhysicalOutputID, selectedPhysicalOutputName, sampleRate, channels, bufferSize, installHealth, statusMessage, recoveryMessage, recoveryAttempts
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            virtualDeviceName: try values.decode(String.self, forKey: .virtualDeviceName),
            bridgeInputDeviceID: try values.decodeIfPresent(UInt32.self, forKey: .bridgeInputDeviceID),
            bridgeInputDeviceName: try values.decodeIfPresent(String.self, forKey: .bridgeInputDeviceName),
            selectedPhysicalOutputID: try values.decodeIfPresent(UInt32.self, forKey: .selectedPhysicalOutputID),
            selectedPhysicalOutputName: try values.decodeIfPresent(String.self, forKey: .selectedPhysicalOutputName),
            sampleRate: try values.decode(Double.self, forKey: .sampleRate),
            channels: try values.decode(Int.self, forKey: .channels),
            bufferSize: try values.decode(Int.self, forKey: .bufferSize),
            installHealth: try values.decode(AudioInstallHealth.self, forKey: .installHealth),
            statusMessage: try values.decode(String.self, forKey: .statusMessage),
            recoveryMessage: try values.decodeIfPresent(String.self, forKey: .recoveryMessage),
            recoveryAttempts: try values.decodeIfPresent(Int.self, forKey: .recoveryAttempts) ?? 0
        )
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
    func uninstallVirtualOutputDevice() throws
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

    public func uninstallVirtualOutputDevice() throws {
        try SonicBloomHALInstaller.uninstall()
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

    static func uninstallScript() -> String {
        """
        /bin/rm -rf \(targetPath)
        /usr/bin/killall coreaudiod || true
        """
    }

    public static func install(driverURL: URL) throws {
        try runPrivileged(script: installScript(driverURL: driverURL), failureMessage: "SonicBloom Output installation was canceled or failed.")
    }

    public static func uninstall() throws {
        try runPrivileged(script: uninstallScript(), failureMessage: "SonicBloom Output uninstall was canceled or failed.")
    }

    private static func runPrivileged(script: String, failureMessage: String) throws {
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
            throw AudioRouteError.installerFailed(message?.isEmpty == false ? message! : failureMessage)
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

public final class CoreAudioProcessInventory {
    public init() {}

    public func processes() -> [AudioProcessSnapshot] {
        processObjectIDs().compactMap(processSnapshot)
    }

    private func processObjectIDs() -> [AudioObjectID] {
        var address = propertyAddress(selector: kAudioHardwarePropertyProcessObjectList)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr, size > 0 else {
            return []
        }

        let count = Int(size) / MemoryLayout<AudioObjectID>.size
        var processIDs = Array(repeating: AudioObjectID(0), count: count)
        let status = processIDs.withUnsafeMutableBufferPointer { pointer in
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
        return processIDs.filter { $0 != kAudioObjectUnknown }
    }

    private func processSnapshot(processObjectID: AudioObjectID) -> AudioProcessSnapshot? {
        guard let processID = readPID(processObjectID) else { return nil }
        return AudioProcessSnapshot(
            processID: processID,
            bundleIdentifier: readBundleIdentifier(processObjectID),
            isRunningOutput: readBool(processObjectID, selector: kAudioProcessPropertyIsRunningOutput, defaultValue: false),
            isAudible: readBool(processObjectID, selector: kAudioHardwarePropertyProcessIsAudible, defaultValue: true),
            audioObjectID: UInt32(processObjectID)
        )
    }

    private func readPID(_ objectID: AudioObjectID) -> Int32? {
        var pid = pid_t(0)
        var size = UInt32(MemoryLayout<pid_t>.size)
        var address = propertyAddress(selector: kAudioProcessPropertyPID)
        let status = AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, &pid)
        return status == noErr && pid > 0 ? Int32(pid) : nil
    }

    private func readBundleIdentifier(_ objectID: AudioObjectID) -> String? {
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        var address = propertyAddress(selector: kAudioProcessPropertyBundleID)
        let status = AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, &value)
        guard status == noErr, let value else { return nil }
        let bundleIdentifier = value.takeRetainedValue() as String
        return bundleIdentifier.isEmpty ? nil : bundleIdentifier
    }

    private func readBool(_ objectID: AudioObjectID, selector: AudioObjectPropertySelector, defaultValue: Bool) -> Bool {
        var value: UInt32 = defaultValue ? 1 : 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        var address = propertyAddress(selector: selector)
        let status = AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, &value)
        return status == noErr ? value != 0 : defaultValue
    }

    private func propertyAddress(selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
    }
}

public struct CoreAudioProcessTap: Equatable, Sendable {
    public var id: UInt32
    public var processObjectIDs: [UInt32]

    public init(id: UInt32, processObjectIDs: [UInt32]) {
        self.id = id
        self.processObjectIDs = processObjectIDs
    }
}

public struct CoreAudioTapAggregateDescription: Equatable, Sendable {
    public var uid: String
    public var name: String
    public var tapUID: String
    public var isPrivate: Bool
    public var tapAutoStart: Bool

    public init(uid: String, name: String, tapUID: String, isPrivate: Bool = true, tapAutoStart: Bool = true) {
        self.uid = uid
        self.name = name
        self.tapUID = tapUID
        self.isPrivate = isPrivate
        self.tapAutoStart = tapAutoStart
    }

    var coreAudioDictionary: [String: Any] {
        [
            kAudioAggregateDeviceUIDKey: uid,
            kAudioAggregateDeviceNameKey: name,
            kAudioAggregateDeviceIsPrivateKey: isPrivate ? 1 : 0,
            kAudioAggregateDeviceTapAutoStartKey: tapAutoStart ? 1 : 0,
            kAudioAggregateDeviceTapListKey: [
                [
                    kAudioSubTapUIDKey: tapUID,
                    kAudioSubTapDriftCompensationKey: 0
                ]
            ]
        ]
    }
}

public struct CoreAudioProcessTapRoute: Equatable, Sendable {
    public var tap: CoreAudioProcessTap
    public var aggregateDeviceID: UInt32
    public var aggregateUID: String

    public init(tap: CoreAudioProcessTap, aggregateDeviceID: UInt32, aggregateUID: String) {
        self.tap = tap
        self.aggregateDeviceID = aggregateDeviceID
        self.aggregateUID = aggregateUID
    }
}

public final class CoreAudioProcessTapManager: @unchecked Sendable {
    private let createTap: ([UInt32]) throws -> UInt32
    private let tapUID: (UInt32) throws -> String
    private let createAggregateDevice: (CoreAudioTapAggregateDescription) throws -> UInt32
    private let destroyAggregateDevice: (UInt32) -> OSStatus
    private let destroyTap: (UInt32) -> OSStatus
    private let lock = NSLock()
    private var activeAggregateDeviceIDs: [UInt32] = []
    private var activeTapIDs: [UInt32] = []

    public convenience init() {
        self.init(createTap: Self.systemCreateTap, destroyTap: Self.systemDestroyTap)
    }

    init(
        createTap: @escaping ([UInt32]) throws -> UInt32,
        tapUID: @escaping (UInt32) throws -> String = CoreAudioProcessTapManager.systemTapUID,
        createAggregateDevice: @escaping (CoreAudioTapAggregateDescription) throws -> UInt32 = CoreAudioProcessTapManager.systemCreateAggregateDevice,
        destroyAggregateDevice: @escaping (UInt32) -> OSStatus = CoreAudioProcessTapManager.systemDestroyAggregateDevice,
        destroyTap: @escaping (UInt32) -> OSStatus
    ) {
        self.createTap = createTap
        self.tapUID = tapUID
        self.createAggregateDevice = createAggregateDevice
        self.destroyAggregateDevice = destroyAggregateDevice
        self.destroyTap = destroyTap
    }

    deinit {
        destroyAll()
    }

    public func createTap(for item: AppMixerItem) throws -> CoreAudioProcessTap {
        guard item.isTapEligible, let processObjectID = item.processObjectID else {
            throw AudioRouteError.bridgeUnavailable("This app is not ready for per-app audio capture yet.")
        }
        let tapID = try createTap([processObjectID])
        lock.lock()
        activeTapIDs.append(tapID)
        lock.unlock()
        return CoreAudioProcessTap(id: tapID, processObjectIDs: [processObjectID])
    }

    public func createReadableTapDevice(for item: AppMixerItem) throws -> CoreAudioProcessTapRoute {
        let tap = try createTap(for: item)
        do {
            let uid = try tapUID(tap.id)
            let aggregateUID = "com.chrisdimarco.sonicbloom.tap.\(tap.id)"
            let description = CoreAudioTapAggregateDescription(
                uid: aggregateUID,
                name: "SonicBloom \(item.rule.displayName) Tap",
                tapUID: uid
            )
            let aggregateDeviceID = try createAggregateDevice(description)
            lock.lock()
            activeAggregateDeviceIDs.append(aggregateDeviceID)
            lock.unlock()
            return CoreAudioProcessTapRoute(tap: tap, aggregateDeviceID: aggregateDeviceID, aggregateUID: aggregateUID)
        } catch {
            destroyTrackedTap(tap.id)
            throw error
        }
    }

    public func destroyAll() {
        lock.lock()
        let aggregateDeviceIDs = activeAggregateDeviceIDs
        let tapIDs = activeTapIDs
        activeAggregateDeviceIDs.removeAll()
        activeTapIDs.removeAll()
        lock.unlock()

        for aggregateDeviceID in aggregateDeviceIDs {
            _ = destroyAggregateDevice(aggregateDeviceID)
        }
        for tapID in tapIDs {
            _ = destroyTap(tapID)
        }
    }

    private func destroyTrackedTap(_ tapID: UInt32) {
        lock.lock()
        activeTapIDs.removeAll { $0 == tapID }
        lock.unlock()
        _ = destroyTap(tapID)
    }

    private static func systemCreateTap(processObjectIDs: [UInt32]) throws -> UInt32 {
        guard #available(macOS 14.2, *) else {
            throw AudioRouteError.bridgeUnavailable("Per-app audio capture requires macOS 14.2 or newer.")
        }
        let description = CATapDescription(stereoMixdownOfProcesses: processObjectIDs.map { AudioObjectID($0) })
        description.name = "SonicBloom App Tap"
        description.isPrivate = true
        description.muteBehavior = CATapMuteBehavior.muted

        var tapID = AudioObjectID(kAudioObjectUnknown)
        let status = AudioHardwareCreateProcessTap(description, &tapID)
        guard status == noErr, tapID != kAudioObjectUnknown else {
            throw AudioRouteError.coreAudioFailed("Unable to create per-app audio tap.", status)
        }
        return UInt32(tapID)
    }

    private static func systemTapUID(_ tapID: UInt32) throws -> String {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = AudioObjectGetPropertyData(AudioObjectID(tapID), &address, 0, nil, &size, &value)
        guard status == noErr, let value else {
            throw AudioRouteError.coreAudioFailed("Unable to read per-app tap UID.", status)
        }
        return value.takeRetainedValue() as String
    }

    private static func systemCreateAggregateDevice(_ description: CoreAudioTapAggregateDescription) throws -> UInt32 {
        var aggregateDeviceID = AudioObjectID(kAudioObjectUnknown)
        let status = AudioHardwareCreateAggregateDevice(description.coreAudioDictionary as CFDictionary, &aggregateDeviceID)
        guard status == noErr, aggregateDeviceID != kAudioObjectUnknown else {
            throw AudioRouteError.coreAudioFailed("Unable to create readable per-app tap device.", status)
        }
        return UInt32(aggregateDeviceID)
    }

    private static func systemDestroyAggregateDevice(_ deviceID: UInt32) -> OSStatus {
        AudioHardwareDestroyAggregateDevice(AudioObjectID(deviceID))
    }

    private static func systemDestroyTap(_ tapID: UInt32) -> OSStatus {
        guard #available(macOS 14.2, *) else { return noErr }
        return AudioHardwareDestroyProcessTap(AudioObjectID(tapID))
    }
}
