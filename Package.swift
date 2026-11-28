// swift-tools-version: 6.0
import Foundation
import PackageDescription

let packageDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
let rustLibDir = packageDir.appendingPathComponent("Frameworks/lib").path
if !FileManager.default.fileExists(atPath: "\(rustLibDir)/libupkeep_core.a") {
    FileHandle.standardError.write(Data("Upkeep requires its Rust core. Run ./Scripts/build-rust-cabi.sh before building with SwiftPM.\n".utf8))
    exit(EXIT_FAILURE)
}

let package = Package(
    name: "Upkeep",
    platforms: [
        .macOS(.v15)
    ],
    products: [
        .executable(name: "Upkeep", targets: ["Upkeep"]),
        .executable(name: "UpkeepSelfTest", targets: ["UpkeepSelfTest"])
    ],
    targets: [
        .systemLibrary(name: "CUpkeepCore", path: "Frameworks/include"),
        .target(
            name: "UpkeepCore",
            dependencies: ["CUpkeepCore"],
            path: "Sources/Upkeep",
            linkerSettings: [
                .linkedFramework("IOKit"),
                .linkedFramework("ApplicationServices"),
                .linkedFramework("Carbon"),
                .unsafeFlags(["-L\(rustLibDir)", "-lupkeep_core"])
            ]
        ),
        .executableTarget(
            name: "Upkeep",
            dependencies: ["UpkeepCore"],
            path: "Sources/UpkeepAppEntry"
        ),
        .executableTarget(
            name: "UpkeepSelfTest",
            dependencies: ["UpkeepCore"],
            path: "Sources/UpkeepSelfTest"
        )
    ]
)
