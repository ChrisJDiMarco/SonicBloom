import Foundation
import CryptoKit

public struct SonicBloomUpdateManifest: Codable, Equatable, Sendable {
    public var version: String
    public var minimumSystemVersion: String
    public var packageURL: URL
    public var packageSHA256: String?
    public var notes: String

    public init(version: String, minimumSystemVersion: String, packageURL: URL, packageSHA256: String? = nil, notes: String = "") {
        self.version = version
        self.minimumSystemVersion = minimumSystemVersion
        self.packageURL = packageURL
        self.packageSHA256 = packageSHA256?.isEmpty == false ? packageSHA256 : nil
        self.notes = notes
    }

    public init(version: String, minimumSystemVersion: String, packageURL: URL, notes: String = "") {
        self.init(version: version, minimumSystemVersion: minimumSystemVersion, packageURL: packageURL, packageSHA256: nil, notes: notes)
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

public enum SonicBloomUpdatePackageVerifier {
    public static func sha256Hex(for data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    public static func verify(_ data: Data, expectedSHA256: String?) -> Bool {
        guard let expectedSHA256, !expectedSHA256.isEmpty else { return true }
        return sha256Hex(for: data).caseInsensitiveCompare(expectedSHA256) == .orderedSame
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
