// swift-tools-version: 6.0
import PackageDescription

// Dravion desktop (open-source shell). The core — scheduling, dispatch, employees, automation, knowledge base,
// connectors and their prompts — ships as the prebuilt binary `Binaries/RelayCore.xcframework` (see
// Binaries/LICENSE-RelayCore.md); everything else here is source under Apache-2.0.
let package = Package(
    name: "RelayNative",
    defaultLocalization: "en",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "Relay", targets: ["Relay"])],
    dependencies: [.package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.9.6")],
    targets: [
        .binaryTarget(name: "RelayCore", path: "Binaries/RelayCore.xcframework"),
        .target(name: "DravionKit", dependencies: ["RelayCore"], swiftSettings: [.swiftLanguageMode(.v5)]),
        .target(name: "RelayWidgetShared", path: "Widget/Shared", swiftSettings: [.swiftLanguageMode(.v5)]),
        .executableTarget(
            name: "Relay",
            dependencies: ["RelayCore", "DravionKit", "RelayWidgetShared", .product(name: "Sparkle", package: "Sparkle")],
            resources: [.process("APIUse/Resources"), .copy("Icons")],
            swiftSettings: [.swiftLanguageMode(.v5), .enableUpcomingFeature("BareSlashRegexLiterals"), .enableUpcomingFeature("IsolatedDefaultValues")],
            linkerSettings: [.unsafeFlags(["-Xlinker", "-platform_version", "-Xlinker", "macos", "-Xlinker", "14.0", "-Xlinker", "27.0",
                                           "-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]
        ),
        .testTarget(name: "RelaySessionTests", dependencies: ["Relay"], swiftSettings: [.swiftLanguageMode(.v5)])
    ]
)
