// swift-tools-version: 6.2
import PackageDescription

let swift6: [SwiftSetting] = [.swiftLanguageMode(.v6)]

let package = Package(
    name: "IPTVKit",
    platforms: [.iOS("27.0"), .tvOS("27.0"), .macOS("15.0")],
    products: [
        .library(name: "Core", targets: ["Core"]),
        .library(name: "Providers", targets: ["Providers"]),
        .executable(name: "iptv-anonymize", targets: ["AnonymizeCLI"]),
    ],
    targets: [
        .target(name: "Core", swiftSettings: swift6),
        .target(name: "Providers", dependencies: ["Core"], swiftSettings: swift6),
        .executableTarget(name: "AnonymizeCLI", dependencies: ["Providers"], swiftSettings: swift6),
        .testTarget(name: "CoreTests", dependencies: ["Core"], swiftSettings: swift6),
        .testTarget(name: "ProvidersTests", dependencies: ["Providers"], resources: [.copy("Fixtures")], swiftSettings: swift6),
    ]
)
