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
        // Oförändrad VLCKit 4.0.0-a25 (LGPL-2.1) från download.videolan.org, se VLCKIT.md.
        .binaryTarget(
            name: "VLCKit",
            url: "https://github.com/filipsjodin/iptv-app/releases/download/vlckit-4.0.0-a25/VLCKit-4.0-20260929-1631.zip",
            checksum: "f37c8dbdd4427d1a3f5d75dc4b8bd1ae863cef4426f9a405a2fd1c5c9012f1fb"),
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
                .product(name: "Core", package: "IPTVKit"),
                .product(name: "PlaybackCore", package: "IPTVKit"),
            ],
            swiftSettings: swift6),
        .target(
            name: "VLCEngine",
            dependencies: [
                "Playback",
                "VLCKit",
                .product(name: "PlaybackCore", package: "IPTVKit"),
            ],
            swiftSettings: swift6),
        .testTarget(
            name: "VLCEngineTests",
            dependencies: [
                "VLCEngine",
                "Playback",
                "PlaybackTestSupport",
                .product(name: "PlaybackCore", package: "IPTVKit"),
            ],
            swiftSettings: swift6),
    ]
)
