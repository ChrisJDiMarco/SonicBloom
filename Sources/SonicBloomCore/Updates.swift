import Foundation
import CryptoKit

public struct SonicBloomUpdateManifest: Codable, Equatable, Sendable {
    public var version: String
    public var minimumSystemVersion: String
    public var packageURL: URL
    public var packageSHA256: String?
    public var notes: String
    public var manifestSignature: String?

    public init(version: String, minimumSystemVersion: String, packageURL: URL, packageSHA256: String? = nil, notes: String = "", manifestSignature: String? = nil) {
        self.version = version
        self.minimumSystemVersion = minimumSystemVersion
        self.packageURL = packageURL
        self.packageSHA256 = packageSHA256?.isEmpty == false ? packageSHA256 : nil
        self.notes = notes
        self.manifestSignature = manifestSignature?.isEmpty == false ? manifestSignature : nil
    }

    public init(version: String, minimumSystemVersion: String, packageURL: URL, notes: String = "") {
        self.init(version: version, minimumSystemVersion: minimumSystemVersion, packageURL: packageURL, packageSHA256: nil, notes: notes)
    }
}

public enum SonicBloomUpdateDecision: Equatable, Sendable {
    case updateAvailable(SonicBloomUpdateManifest)
    case invalidVersion(SonicBloomUpdateManifest)
    case unsupported(SonicBloomUpdateManifest)
    case insecurePackageURL(SonicBloomUpdateManifest)
    case invalidPackageURL(SonicBloomUpdateManifest)
    case missingChecksum(SonicBloomUpdateManifest)
    case invalidChecksum(SonicBloomUpdateManifest)
    case invalidManifestSignature(SonicBloomUpdateManifest)
    case upToDate
}

public enum SonicBloomUpdater {
    public static func decision(currentVersion: String, manifest: SonicBloomUpdateManifest) -> SonicBloomUpdateDecision {
        decision(currentVersion: currentVersion, currentSystemVersion: currentSystemVersion, manifest: manifest)
    }

    public static func decision(currentVersion: String, manifest: SonicBloomUpdateManifest, trustedManifestPublicKeyHex: String?) -> SonicBloomUpdateDecision {
        decision(currentVersion: currentVersion, currentSystemVersion: currentSystemVersion, manifest: manifest, trustedManifestPublicKeyHex: trustedManifestPublicKeyHex)
    }

    public static func decision(
        currentVersion: String,
        currentSystemVersion: String,
        manifest: SonicBloomUpdateManifest,
        trustedManifestPublicKeyHex: String? = nil
    ) -> SonicBloomUpdateDecision {
        guard ReleaseVersion.isValid(manifest.version) else {
            return .invalidVersion(manifest)
        }
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
        if let trustedManifestPublicKeyHex,
           !trustedManifestPublicKeyHex.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           !SonicBloomUpdateManifestSignatureVerifier.verify(manifest: manifest, trustedPublicKeyHex: trustedManifestPublicKeyHex) {
            return .invalidManifestSignature(manifest)
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

public enum SonicBloomUpdateManifestSignatureVerifier {
    public static func payload(for manifest: SonicBloomUpdateManifest) -> Data {
        Data([
            manifest.version,
            manifest.minimumSystemVersion,
            manifest.packageURL.absoluteString,
            manifest.packageSHA256 ?? "",
            manifest.notes
        ].joined(separator: "\n").utf8)
    }

    public static func verify(manifest: SonicBloomUpdateManifest, trustedPublicKeyHex: String) -> Bool {
        guard let signatureHex = manifest.manifestSignature,
              let publicKeyData = data(fromHex: trustedPublicKeyHex),
              let signatureData = data(fromHex: signatureHex),
              let publicKey = try? Curve25519.Signing.PublicKey(rawRepresentation: publicKeyData) else {
            return false
        }
        return publicKey.isValidSignature(signatureData, for: payload(for: manifest))
    }

    public static func hexString(for data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }

    private static func data(fromHex value: String) -> Data? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count.isMultiple(of: 2), trimmed.allSatisfy(\.isHexDigit) else { return nil }
        var data = Data()
        var index = trimmed.startIndex
        while index < trimmed.endIndex {
            let next = trimmed.index(index, offsetBy: 2)
            guard let byte = UInt8(String(trimmed[index..<next]), radix: 16) else { return nil }
            data.append(byte)
            index = next
        }
        return data
    }
}

private struct ReleaseVersion: Comparable {
    private let parts: [Int]

    init(_ value: String) {
        parts = value.split(separator: ".").map { Int($0.prefix { $0.isNumber }) ?? 0 }
    }

    static func isValid(_ value: String) -> Bool {
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...3).contains(parts.count) else { return false }
        return parts.allSatisfy { !$0.isEmpty && $0.allSatisfy(\.isNumber) }
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
