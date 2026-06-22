import Foundation

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
}

private extension JSONEncoder {
    static var pretty: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}
