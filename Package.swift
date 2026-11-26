// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Swiftty",
    platforms: [.macOS("27.0")],
    products: [
        .executable(name: "Swiftty", targets: ["Swiftty"]),
    ],
    dependencies: [
        // In-app updates from GitHub releases.
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.0"),
    ],
    targets: [
        // libghostty-vt, built by scripts/build-ghostty.sh.
        .binaryTarget(
            name: "GhosttyVt",
            path: "vendor/ghostty/zig-out/lib/ghostty-vt.xcframework"
        ),
        // The Rex wire protocol: control WebSocket, data streams, models.
        .target(name: "RexKit"),
        // Terminal state (libghostty-vt) and the Metal grid renderer.
        .target(
            name: "TerminalKit",
            dependencies: ["GhosttyVt", "RexKit"],
            linkerSettings: [.linkedLibrary("c++")]
        ),
        // The app.
        .executableTarget(
            name: "Swiftty",
            dependencies: ["RexKit", "TerminalKit", .product(name: "Sparkle", package: "Sparkle")],
            resources: [.copy("ShellIntegration")],
            // Sparkle.framework is embedded in Swiftty.app/Contents/Frameworks.
            linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]
        ),
        .testTarget(name: "RexKitTests", dependencies: ["RexKit"]),
        .testTarget(name: "TerminalKitTests", dependencies: ["TerminalKit"]),
    ]
)
