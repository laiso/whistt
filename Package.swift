// swift-tools-version:5.9
import PackageDescription

// SwiftPM lives alongside the Xcode project (Whistt/Whistt.xcodeproj).
// It exposes a small library of pure-Foundation logic for testing via `swift test`,
// plus a `realtime-probe` CLI for verifying the OpenAI Realtime WS protocol
// without needing audio hardware.
let package = Package(
    name: "Whistt",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "WhisttCore", targets: ["WhisttCore"]),
        .executable(name: "realtime-probe", targets: ["RealtimeProbe"])
    ],
    targets: [
        .target(
            name: "WhisttCore",
            path: "Whistt/Whistt",
            exclude: [
                "Assets.xcassets",
                "WhisttApp.swift",
                "AppDelegate.swift",
                "HotKeyManager.swift",
                "WhisperNativeAgent.swift",
                "TypingEmulator.swift",
                "WhisttLog.swift"
            ],
            sources: ["EnvLoader.swift", "KeychainStore.swift", "RealtimeProtocol.swift", "RealtimeWS.swift"]
        ),
        .executableTarget(
            name: "RealtimeProbe",
            dependencies: ["WhisttCore"],
            path: "Tools/RealtimeProbe"
        ),
        .testTarget(
            name: "WhisttCoreTests",
            dependencies: ["WhisttCore"],
            path: "Tests/WhisttCoreTests"
        )
    ]
)
