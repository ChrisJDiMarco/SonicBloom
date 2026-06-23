// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "SonicBloom",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .library(name: "SonicBloomCore", targets: ["SonicBloomCore"]),
        .executable(name: "SonicBloom", targets: ["SonicBloomApp"])
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
                .linkedFramework("CoreAudio")
            ]
        ),
        .executableTarget(
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
