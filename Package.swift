// swift-tools-version: 6.0
import Foundation
import PackageDescription

let packageDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
let rustLibDir = packageDir.appendingPathComponent("Frameworks/lib").path
let rustLibPath = packageDir.appendingPathComponent("Frameworks/lib/libspotlight_core.a").path
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
            name: "CSpotlightCore",
            path: "Frameworks/include"
        )
    )
    coreDependencies.append("CSpotlightCore")
    coreSwiftSettings.append(.define("USE_RUST_SPOTLIGHT_CORE"))
    coreLinkerSettings.append(.unsafeFlags(["-L\(rustLibDir)", "-lspotlight_core"]))
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
            exclude: ["App/UpkeepApp.swift"],
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
