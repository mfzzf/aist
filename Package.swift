// swift-tools-version: 6.2
import PackageDescription

let swift5: [SwiftSetting] = [.swiftLanguageMode(.v5)]

let package = Package(
    name: "aist",
    defaultLocalization: "zh-Hans",
    platforms: [.macOS(.v15), .iOS(.v16)],
    products: [
        .library(name: "AistCore", targets: ["AistCore"]),
        .library(name: "AistAI", targets: ["AistAI"]),
        .library(name: "AistAgent", targets: ["AistAgent"]),
        .library(name: "AistAgentUI", targets: ["AistAgentUI"]),
        .executable(name: "AistMac", targets: ["AistMac"]),
        .executable(name: "aist-cli", targets: ["aist-cli"]),
    ],
    dependencies: [
        // IMAP/SMTP on Apple's swift-nio-imap (no native mail framework exists). Tracks main because
        // SwiftMail itself pins swift-nio-imap to a revision, which SwiftPM only allows via branch deps.
        .package(url: "https://github.com/Cocoanetics/SwiftMail", branch: "main"),
        // Telling voices apart on a recording (Apple has no API for it). Only its diarizer: without
        // the other traits it brings no binary framework and no resource bundle. Pinned exactly; it
        // releases often.
        .package(url: "https://github.com/FluidInference/FluidAudio", exact: "0.18.3", traits: ["Diarizer"]),
    ],
    targets: [
        // Provider-neutral LLM layer (pi-ai style): Api = wire protocol, Model = catalog entry, AI.stream().
        .target(name: "AistAI", swiftSettings: swift5),
        // Agent loop, tools (web search/fetch) and conversation storage (SQLite). Knows nothing of mail/to-dos.
        .target(name: "AistAgent", dependencies: ["AistAI"], swiftSettings: swift5),
        // Embeddable SwiftUI chat: full pane or a compact pop-up, same look everywhere.
        .target(name: "AistAgentUI", dependencies: ["AistAgent", "AistAI"], swiftSettings: swift5),
        // Shared by the Mac app, the future iOS app and the CLI.
        .target(name: "AistCore", dependencies: ["AistAI"], swiftSettings: swift5),
        // Menu-bar app: hotkey → screenshot → LLM → notch island.
        .executableTarget(
            name: "AistMac",
            dependencies: ["AistCore", "AistAI", "AistAgent", "AistAgentUI", "AistAudio", .product(name: "SwiftMail", package: "SwiftMail")],
            swiftSettings: swift5
        ),
        // What the Mac does with recorded audio beyond transcribing it: the energy of the two tracks,
        // for telling the user's voice from the other side heard through the speakers.
        .target(
            name: "AistAudio",
            dependencies: ["AistCore", .product(name: "FluidAudio", package: "FluidAudio", condition: .when(platforms: [.macOS]))],
            swiftSettings: swift5
        ),
        // Headless tool for testing extraction on an image file over SSH.
        .executableTarget(name: "aist-cli", dependencies: ["AistCore", "AistAI", "AistAgent", "AistAudio"], swiftSettings: swift5),
        .testTarget(name: "AistCoreTests", dependencies: ["AistCore"], swiftSettings: swift5),
        .testTarget(name: "AistAudioTests", dependencies: ["AistAudio", "AistCore"], swiftSettings: swift5),
        .testTarget(name: "AistAgentTests", dependencies: ["AistAI", "AistAgent"], swiftSettings: swift5),
    ]
)
