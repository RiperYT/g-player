// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "GPlayer",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "GPlayerCore", targets: ["GPlayerCore"]),
        .executable(name: "GPlayer", targets: ["GPlayer"]),
    ],
    dependencies: [
        // In-app updates of G-Player itself (MIT). A binary framework: SwiftPM checks the checksum its Package.swift pins.
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.0"),
    ],
    targets: [
        // Everything that decides how a Windows program runs. No SwiftUI here.
        .target(
            name: "GPlayerCore",
            exclude: ["Resources"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // The macOS app (SwiftUI). Assembled into G-Player.app by scripts/build-app.sh.
        .executableTarget(
            name: "GPlayer",
            dependencies: ["GPlayerCore", .product(name: "Sparkle", package: "Sparkle")],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "GPlayerCoreTests",
            dependencies: ["GPlayerCore"],
            resources: [.copy("Fixtures")],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
