import Foundation
import SonicBloomCore

let arguments = CommandLine.arguments
guard arguments.count == 7, arguments[1] == "sign" else {
    FileHandle.standardError.write(Data("usage: SonicBloomManifestSigner sign <version> <minimumSystemVersion> <packageURL> <packageSHA256> <notes>\n".utf8))
    exit(64)
}

guard let privateKeyHex = ProcessInfo.processInfo.environment["SONICBLOOM_UPDATE_MANIFEST_PRIVATE_KEY_HEX"], !privateKeyHex.isEmpty else {
    FileHandle.standardError.write(Data("SONICBLOOM_UPDATE_MANIFEST_PRIVATE_KEY_HEX is required\n".utf8))
    exit(65)
}

guard let packageURL = URL(string: arguments[4]) else {
    FileHandle.standardError.write(Data("packageURL is invalid\n".utf8))
    exit(65)
}

let manifest = SonicBloomUpdateManifest(
    version: arguments[2],
    minimumSystemVersion: arguments[3],
    packageURL: packageURL,
    packageSHA256: arguments[5],
    notes: arguments[6]
)

guard let signature = SonicBloomUpdateManifestSignatureVerifier.signatureHex(for: manifest, privateKeyHex: privateKeyHex) else {
    FileHandle.standardError.write(Data("SONICBLOOM_UPDATE_MANIFEST_PRIVATE_KEY_HEX is invalid\n".utf8))
    exit(65)
}

print(signature)
