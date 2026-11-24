// swift-tools-version: 6.0
import Foundation
import PackageDescription

let packageDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
let rustLibDir = packageDir.appendingPathComponent("Frameworks/lib").path
let rustLibPath = packageDir.appendingPathComponent("Frameworks/lib/libupkeep_core.a").path
let hasRustCore = FileManager.default.fileExists(atPath: rustLibPath)

var coreDependencies: [Target.Dependency] = []
var coreSwiftSettings: [SwiftSetting] = []
var coreLinkerSettings: [LinkerSetting] = [
    .linkedFramework("IOKit"),
    .linkedFramework("ApplicationServices"),
    .linkedFramework("Carbon")
]
var extraTargets: [Target] = []

if hasRustCore {
    extraTargets.append(
        .systemLibrary(
            name: "CUpkeepCore",
            path: "Frameworks/include"
        )
    )
    coreDependencies.append("CUpkeepCore")
    coreSwiftSettings.append(.define("USE_RUST_UPKEEP_CORE"))
    coreLinkerSettings.append(.unsafeFlags(["-L\(rustLibDir)", "-lupkeep_core"]))
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
    targets: extraTargets + [
        .target(
            name: "UpkeepCore",
            dependencies: coreDependencies,
            path: "Sources/Upkeep",
            swiftSettings: coreSwiftSettings,
            linkerSettings: coreLinkerSettings
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
