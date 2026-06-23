// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "SonicBloom",
    defaultLocalization: "en",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .library(name: "SonicBloomCore", targets: ["SonicBloomCore"]),
        .executable(name: "SonicBloom", targets: ["SonicBloomMain"]),
        .executable(name: "SonicBloomRecovery", targets: ["SonicBloomRecovery"]),
        .executable(name: "SonicBloomManifestSigner", targets: ["SonicBloomManifestSigner"])
    ],
    targets: [
        .target(
            name: "SonicBloomDSP",
            publicHeadersPath: "include",
            cxxSettings: [
                .unsafeFlags(["-std=c++17"])
            ]
        ),
        .target(
            name: "SonicBloomCore",
            dependencies: ["SonicBloomDSP"],
            linkerSettings: [
                .linkedFramework("AudioToolbox"),
                .linkedFramework("CoreAudio")
            ]
        ),
        .target(
            name: "SonicBloomApp",
            dependencies: ["SonicBloomCore", "SonicBloomDSP"],
            resources: [
                .process("Resources")
            ],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("AVFAudio"),
                .linkedFramework("CoreAudio"),
                .linkedFramework("MetalKit")
            ]
        ),
        .executableTarget(
            name: "SonicBloomMain",
            dependencies: ["SonicBloomApp"],
            path: "Sources/SonicBloomMain",
            linkerSettings: [
                .linkedFramework("AppKit")
            ]
        ),
        .executableTarget(
            name: "SonicBloomRecovery",
            dependencies: ["SonicBloomCore"],
            linkerSettings: [
                .linkedFramework("CoreAudio")
            ]
        ),
        .executableTarget(
            name: "SonicBloomManifestSigner",
            dependencies: ["SonicBloomCore"],
            path: "Sources/SonicBloomManifestSigner"
        ),
        .testTarget(
            name: "SonicBloomCoreTests",
            dependencies: ["SonicBloomCore", "SonicBloomDSP"]
        ),
        .testTarget(
            name: "SonicBloomAppTests",
            dependencies: ["SonicBloomApp"]
        )
    ]
)
