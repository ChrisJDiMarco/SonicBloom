import Foundation

public struct SonicBloomUpdateManifest: Codable, Equatable, Sendable {
    public var version: String
    public var minimumSystemVersion: String
    public var packageURL: URL
    public var notes: String

    public init(version: String, minimumSystemVersion: String, packageURL: URL, notes: String = "") {
        self.version = version
        self.minimumSystemVersion = minimumSystemVersion
        self.packageURL = packageURL
        self.notes = notes
    }
}

public enum SonicBloomUpdateDecision: Equatable, Sendable {
    case updateAvailable(SonicBloomUpdateManifest)
    case upToDate
}

public enum SonicBloomUpdater {
    public static func decision(currentVersion: String, manifest: SonicBloomUpdateManifest) -> SonicBloomUpdateDecision {
        ReleaseVersion(manifest.version) > ReleaseVersion(currentVersion) ? .updateAvailable(manifest) : .upToDate
    }
}

private struct ReleaseVersion: Comparable {
    private let parts: [Int]

    init(_ value: String) {
        parts = value.split(separator: ".").map { Int($0.prefix { $0.isNumber }) ?? 0 }
    }

    static func < (lhs: ReleaseVersion, rhs: ReleaseVersion) -> Bool {
        for index in 0..<max(lhs.parts.count, rhs.parts.count) {
            let left = index < lhs.parts.count ? lhs.parts[index] : 0
            let right = index < rhs.parts.count ? rhs.parts[index] : 0
            if left != right { return left < right }
        }
        return false
    }
}
