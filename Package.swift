// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "claude-status-bar-macos",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "ClaudeStatusBar", targets: ["ClaudeStatusBar"]),
        .executable(name: "claude-status-hook", targets: ["ClaudeStatusHook"]),
        .library(name: "StatusBarCore", targets: ["StatusBarCore"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-testing.git", exact: "0.12.0"),
    ],
    targets: [
        .target(
            name: "StatusBarCore",
            swiftSettings: [.swiftLanguageMode(.v5)]),
        .executableTarget(
            name: "ClaudeStatusBar",
            dependencies: ["StatusBarCore"],
            resources: [.copy("Resources/clawd")],
            swiftSettings: [.swiftLanguageMode(.v5)]),
        .executableTarget(
            name: "ClaudeStatusHook",
            dependencies: ["StatusBarCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]),
        .testTarget(
            name: "StatusBarCoreTests",
            dependencies: ["StatusBarCore", .product(name: "Testing", package: "swift-testing")],
            swiftSettings: [.swiftLanguageMode(.v5)]),
        .testTarget(
            name: "ClaudeStatusBarTests",
            dependencies: ["ClaudeStatusBar", "StatusBarCore", .product(name: "Testing", package: "swift-testing")],
            swiftSettings: [.swiftLanguageMode(.v5)]),
    ]
)
