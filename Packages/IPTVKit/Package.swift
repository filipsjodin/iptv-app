// swift-tools-version: 6.2
import PackageDescription

let swift6: [SwiftSetting] = [.swiftLanguageMode(.v6)]

let package = Package(
    name: "IPTVKit",
    platforms: [.iOS("27.0"), .tvOS("27.0"), .macOS("15.0")],
    products: [
        .library(name: "Core", targets: ["Core"]),
        .library(name: "PlaybackCore", targets: ["PlaybackCore"]),
        .library(name: "Personal", targets: ["Personal"]),
        .library(name: "Providers", targets: ["Providers"]),
        .library(name: "Metadata", targets: ["Metadata"]),
        .library(name: "Discovery", targets: ["Discovery"]),
        .library(name: "ProvidersTestSupport", targets: ["ProvidersTestSupport"]),
        .library(name: "AnonymizeKit", targets: ["AnonymizeKit"]),
        .executable(name: "iptv-anonymize", targets: ["AnonymizeCLI"]),
    ],
    targets: [
        .target(name: "Core", swiftSettings: swift6),
        .target(name: "PlaybackCore", dependencies: ["Core"], swiftSettings: swift6),
        .target(name: "Personal", dependencies: ["Core", "PlaybackCore"], swiftSettings: swift6),
        .target(name: "Providers", dependencies: ["Core"], swiftSettings: swift6),
        .target(name: "Metadata", dependencies: ["Core", "Providers"], swiftSettings: swift6),
        .target(name: "Discovery", dependencies: ["Core", "Metadata", "Personal", "PlaybackCore"], swiftSettings: swift6),
        .target(name: "ProvidersTestSupport", dependencies: ["Providers"], resources: [.copy("Fixtures")], swiftSettings: swift6),
        .target(name: "AnonymizeKit", dependencies: ["Providers"], swiftSettings: swift6),
        .executableTarget(name: "AnonymizeCLI", dependencies: ["AnonymizeKit"], swiftSettings: swift6),
        .testTarget(name: "CoreTests", dependencies: ["Core"], swiftSettings: swift6),
        .testTarget(name: "PlaybackCoreTests", dependencies: ["PlaybackCore"], swiftSettings: swift6),
        .testTarget(name: "PersonalTests", dependencies: ["Personal", "PlaybackCore", "Core"], swiftSettings: swift6),
        .testTarget(name: "DiscoveryTests", dependencies: ["Discovery", "Personal", "Core"], swiftSettings: swift6),
        .testTarget(name: "AnonymizeKitTests", dependencies: ["AnonymizeKit"], swiftSettings: swift6),
        .testTarget(name: "ProvidersTests", dependencies: ["Providers", "ProvidersTestSupport"], resources: [.copy("Fixtures")], swiftSettings: swift6),
        .testTarget(name: "MetadataTests", dependencies: ["Metadata", "ProvidersTestSupport"], resources: [.copy("Fixtures")], swiftSettings: swift6),
    ]
)
