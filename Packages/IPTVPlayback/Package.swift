// swift-tools-version: 6.2
import PackageDescription

let swift6: [SwiftSetting] = [.swiftLanguageMode(.v6)]

let package = Package(
    name: "IPTVPlayback",
    platforms: [.iOS("27.0"), .tvOS("27.0")],
    products: [
        .library(name: "Playback", targets: ["Playback"]),
        .library(name: "PlaybackTestSupport", targets: ["PlaybackTestSupport"]),
    ],
    dependencies: [
        .package(path: "../IPTVKit"),
    ],
    targets: [
        .target(
            name: "Playback",
            dependencies: [
                .product(name: "Core", package: "IPTVKit"),
                .product(name: "PlaybackCore", package: "IPTVKit"),
            ],
            swiftSettings: swift6),
        .target(
            name: "PlaybackTestSupport",
            dependencies: [
                "Playback",
                .product(name: "PlaybackCore", package: "IPTVKit"),
            ],
            swiftSettings: swift6),
        .testTarget(
            name: "PlaybackTests",
            dependencies: [
                "Playback",
                "PlaybackTestSupport",
                .product(name: "PlaybackCore", package: "IPTVKit"),
            ],
            swiftSettings: swift6),
    ]
)
