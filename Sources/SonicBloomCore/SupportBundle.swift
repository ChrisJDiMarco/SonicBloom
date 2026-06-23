import Foundation

public enum SonicBloomSupportEventLogger {
    public static func defaultLogURL() -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SonicBloom", isDirectory: true)
            .appendingPathComponent("support-events.log")
    }

    public static func append(category: String, message: String, to url: URL = defaultLogURL(), now: Date = Date()) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let line = "\(timestamp(now)) \(clean(category)) \(clean(message))\n"
        if FileManager.default.fileExists(atPath: url.path) {
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: Data(line.utf8))
        } else {
            try line.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    public static func recentEvents(from url: URL = defaultLogURL(), maxLines: Int = 80) -> [String] {
        guard maxLines > 0,
              let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return Array(text.split(separator: "\n").suffix(maxLines).map(String.init))
    }

    private static func timestamp(_ date: Date) -> String {
        ISO8601DateFormatter().string(from: date)
    }

    private static func clean(_ value: String) -> String {
        value.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

public enum SonicBloomSupportBundle {
    public static func build(
        diagnosticsReport: String,
        recentEvents: [String],
        halLog: String?,
        recoveryLog: String?,
        recoveryErrorLog: String?
    ) -> String {
        [
            "SonicBloom Support Bundle",
            "Generated: \(ISO8601DateFormatter().string(from: Date()))",
            "",
            "Diagnostics",
            diagnosticsReport,
            "",
            "Recent Events",
            recentEvents.isEmpty ? "No recorded events." : recentEvents.joined(separator: "\n"),
            "",
            "HAL Log",
            nonEmpty(halLog),
            "",
            "Recovery Log",
            nonEmpty(recoveryLog),
            "",
            "Recovery Error Log",
            nonEmpty(recoveryErrorLog),
            "",
            "Known Issues Checklist",
            "- If audio is silent, choose a real Mac output in Control Center > Sound, then Refresh Route.",
            "- If microphone permission appears, macOS is asking for access to SonicBloom Output, not your physical mic.",
            "- If Bluetooth or AirPods switch devices, use Repair Audio or turn enhancement off/on.",
            "- If a third-party Audio Unit crackles, remove it from SonicBloom and retry."
        ].joined(separator: "\n")
    }

    private static func nonEmpty(_ text: String?) -> String {
        guard let text = text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else {
            return "No log found."
        }
        return String(text.suffix(12_000))
    }
}
