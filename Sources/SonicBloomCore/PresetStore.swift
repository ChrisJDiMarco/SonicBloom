import Foundation

public struct PresetShareDocument: Codable, Equatable, Sendable {
    public var app: String
    public var formatVersion: Int
    public var preset: DSPPreset

    public init(preset: DSPPreset, app: String = "SonicBloom", formatVersion: Int = 1) {
        self.app = app
        self.formatVersion = formatVersion
        self.preset = preset
    }
}

public final class PresetStore {
    private let directoryURL: URL
    private var fileURL: URL {
        directoryURL.appendingPathComponent("custom-presets.json")
    }

    public init(directoryURL: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("SonicBloom", isDirectory: true)) {
        self.directoryURL = directoryURL
    }

    public func loadCustomPresets() throws -> [DSPPreset] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return []
        }

        let data = try Data(contentsOf: fileURL)
        return try JSONDecoder().decode([DSPPreset].self, from: data)
    }

    public func saveCustomPreset(_ preset: DSPPreset) throws {
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        var presets = try loadCustomPresets()
        presets.removeAll { $0.name == preset.name }
        presets.append(preset)
        let data = try JSONEncoder.pretty.encode(presets)
        try data.write(to: fileURL, options: .atomic)
    }

    public func exportPreset(named name: String) throws -> Data? {
        guard let preset = try loadCustomPresets().first(where: { $0.name == name }) else {
            return nil
        }
        return try JSONEncoder.pretty.encode(PresetShareDocument(preset: preset))
    }

    @discardableResult
    public func importPreset(from data: Data) throws -> DSPPreset {
        let preset = try JSONDecoder().decode(PresetShareDocument.self, from: data).preset
        try saveCustomPreset(preset)
        return preset
    }
}

private extension JSONEncoder {
    static var pretty: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}
