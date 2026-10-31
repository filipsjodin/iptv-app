// swift-tools-version: 6.2
import PackageDescription

let swift6: [SwiftSetting] = [.swiftLanguageMode(.v6)]

let package = Package(
    name: "IPTVPlayback",
    platforms: [.iOS("27.0"), .tvOS("27.0")],
    products: [
        .library(name: "Playback", targets: ["Playback"]),
        .library(name: "PlaybackTestSupport", targets: ["PlaybackTestSupport"]),
        .library(name: "VLCEngine", targets: ["VLCEngine"]),
    ],
    dependencies: [
        .package(path: "../IPTVKit"),
    ],
    targets: [
        // VLCKit 4.0.0-a25 (LGPL-2.1): oförändrade binärer, ompackade med bara iOS/tvOS-skivor. Se VLCKIT.md.
        .binaryTarget(
            name: "VLCKit",
            url: "https://github.com/filipsjodin/iptv-app/releases/download/vlckit-4.0.0-a25-slim/VLCKit-4.0.0-a25-ios-tvos.zip",
            checksum: "22944338b469ce428c0394ceae21222ce9e12c6e7ea67f0acb51f12b5dff209c"),
        .target(
            name: "Playback",
            dependencies: [
                .product(name: "Core", package: "IPTVKit"),
                .product(name: "PlaybackCore", package: "IPTVKit"),
                .product(name: "Subtitles", package: "IPTVKit"),
            ],
            swiftSettings: swift6),
        .target(
            name: "PlaybackTestSupport",
            dependencies: [
                "Playback",
                .product(name: "PlaybackCore", package: "IPTVKit"),
                .product(name: "Subtitles", package: "IPTVKit"),
            ],
            swiftSettings: swift6),
        .testTarget(
            name: "PlaybackTests",
            dependencies: [
                "Playback",
                "PlaybackTestSupport",
                .product(name: "Core", package: "IPTVKit"),
                .product(name: "PlaybackCore", package: "IPTVKit"),
                .product(name: "Subtitles", package: "IPTVKit"),
            ],
            swiftSettings: swift6),
        .target(
            name: "VLCEngine",
            dependencies: [
                "Playback",
                "VLCKit",
                .product(name: "PlaybackCore", package: "IPTVKit"),
                .product(name: "Subtitles", package: "IPTVKit"),
            ],
            swiftSettings: swift6),
        .testTarget(
            name: "VLCEngineTests",
            dependencies: [
                "VLCEngine",
                "Playback",
                "PlaybackTestSupport",
                .product(name: "PlaybackCore", package: "IPTVKit"),
                .product(name: "Subtitles", package: "IPTVKit"),
            ],
            swiftSettings: swift6),
    ]
)
