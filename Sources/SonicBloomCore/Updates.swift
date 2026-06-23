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
    case unsupported(SonicBloomUpdateManifest)
    case insecurePackageURL(SonicBloomUpdateManifest)
    case invalidPackageURL(SonicBloomUpdateManifest)
    case missingChecksum(SonicBloomUpdateManifest)
    case invalidChecksum(SonicBloomUpdateManifest)
    case upToDate
}

public enum SonicBloomUpdater {
    public static func decision(currentVersion: String, manifest: SonicBloomUpdateManifest) -> SonicBloomUpdateDecision {
        decision(currentVersion: currentVersion, currentSystemVersion: currentSystemVersion, manifest: manifest)
    }

    public static func decision(
        currentVersion: String,
        currentSystemVersion: String,
        manifest: SonicBloomUpdateManifest
    ) -> SonicBloomUpdateDecision {
        guard ReleaseVersion(manifest.version) > ReleaseVersion(currentVersion) else {
            return .upToDate
        }
        guard ReleaseVersion(currentSystemVersion) >= ReleaseVersion(manifest.minimumSystemVersion) else {
            return .unsupported(manifest)
        }
        guard manifest.packageURL.scheme?.lowercased() == "https" else {
            return .insecurePackageURL(manifest)
        }
        guard manifest.packageURL.pathExtension.lowercased() == "pkg" else {
            return .invalidPackageURL(manifest)
        }
        guard manifest.packageSHA256?.isEmpty == false else {
            return .missingChecksum(manifest)
        }
        guard SonicBloomUpdatePackageVerifier.isValidSHA256Hex(manifest.packageSHA256) else {
            return .invalidChecksum(manifest)
        }
        return .updateAvailable(manifest)
    }

    private static var currentSystemVersion: String {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        return "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
    }
}

public enum SonicBloomUpdatePackageVerifier {
    public static func sha256Hex(for data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    public static func safePackageFilename(version: String) -> String {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")
        let sanitized = String(version.unicodeScalars.map { allowed.contains($0) ? Character($0) : "-" })
            .trimmingCharacters(in: CharacterSet(charactersIn: ".-_"))
        return "SonicBloom-\(sanitized.isEmpty ? "update" : sanitized).pkg"
    }

    public static func verify(_ data: Data, expectedSHA256: String?) -> Bool {
        guard let expectedSHA256, isValidSHA256Hex(expectedSHA256) else { return false }
        return sha256Hex(for: data).caseInsensitiveCompare(expectedSHA256) == .orderedSame
    }

    public static func isValidSHA256Hex(_ value: String?) -> Bool {
        guard let value, value.count == 64 else { return false }
        return value.allSatisfy(\.isHexDigit)
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
