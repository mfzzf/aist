// swift-tools-version: 6.0
import PackageDescription

let swift5: [SwiftSetting] = [.swiftLanguageMode(.v5)]

let package = Package(
    name: "aist",
    defaultLocalization: "zh-Hans",
    platforms: [.macOS(.v15), .iOS(.v18)],
    products: [
        .library(name: "AistCore", targets: ["AistCore"]),
        .executable(name: "AistMac", targets: ["AistMac"]),
        .executable(name: "aist-cli", targets: ["aist-cli"]),
    ],
    dependencies: [
        // IMAP/SMTP on Apple's swift-nio-imap (no native mail framework exists). Tracks main because
        // SwiftMail itself pins swift-nio-imap to a revision, which SwiftPM only allows via branch deps.
        .package(url: "https://github.com/Cocoanetics/SwiftMail", branch: "main"),
    ],
    targets: [
        // Shared by the Mac app, the future iOS app and the CLI.
        .target(name: "AistCore", swiftSettings: swift5),
        // Menu-bar app: hotkey → screenshot → LLM → notch island.
        .executableTarget(
            name: "AistMac",
            dependencies: ["AistCore", .product(name: "SwiftMail", package: "SwiftMail")],
            swiftSettings: swift5
        ),
        // Headless tool for testing extraction on an image file over SSH.
        .executableTarget(name: "aist-cli", dependencies: ["AistCore"], swiftSettings: swift5),
        .testTarget(name: "AistCoreTests", dependencies: ["AistCore"], swiftSettings: swift5),
    ]
)
