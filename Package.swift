// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Swiftty",
    platforms: [.macOS("27.0")],
    products: [
        .executable(name: "Swiftty", targets: ["Swiftty"]),
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
            dependencies: ["RexKit", "TerminalKit"],
            resources: [.copy("ShellIntegration")]
        ),
        .testTarget(name: "RexKitTests", dependencies: ["RexKit"]),
        .testTarget(name: "TerminalKitTests", dependencies: ["TerminalKit"]),
    ]
)
