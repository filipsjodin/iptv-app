// swift-tools-version: 6.2
import PackageDescription

let swift6: [SwiftSetting] = [.swiftLanguageMode(.v6)]

let package = Package(
    name: "IPTVPlatform",
    platforms: [.iOS("27.0"), .tvOS("27.0"), .macOS("15.0")],
    products: [
        .library(name: "Library", targets: ["Library"]),
        .library(name: "Secrets", targets: ["Secrets"]),
    ],
    dependencies: [
        .package(path: "../IPTVKit"),
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.0.0"),
    ],
    targets: [
        .target(
            name: "Secrets",
            dependencies: [.product(name: "Core", package: "IPTVKit")],
            swiftSettings: swift6),
        .testTarget(
            name: "SecretsTests",
            dependencies: ["Secrets", .product(name: "Core", package: "IPTVKit")],
            swiftSettings: swift6),
        .target(
            name: "Library",
            dependencies: [
                .product(name: "Core", package: "IPTVKit"),
                .product(name: "Providers", package: "IPTVKit"),
                .product(name: "GRDB", package: "GRDB.swift"),
            ],
            swiftSettings: swift6),
        .testTarget(
            name: "LibraryTests",
            dependencies: [
                "Library",
                .product(name: "ProvidersTestSupport", package: "IPTVKit"),
            ],
            swiftSettings: swift6),
        .testTarget(
            name: "LibraryPerformanceTests",
            dependencies: [
                "Library",
                .product(name: "ProvidersTestSupport", package: "IPTVKit"),
            ],
            swiftSettings: swift6),
    ]
)
