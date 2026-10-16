// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "ClaudeBar",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .executable(name: "ClaudeBar", targets: ["ClaudeBar"]),
    ],
    targets: [
        .target(name: "ClaudeBarCore"),
        .executableTarget(
            name: "ClaudeBar",
            dependencies: ["ClaudeBarCore"]
        ),
        .testTarget(
            name: "ClaudeBarCoreTests",
            dependencies: ["ClaudeBarCore"]
        ),
    ],
    swiftLanguageModes: [.v6]
)
