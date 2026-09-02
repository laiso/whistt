// swift-tools-version:5.9
import PackageDescription

// SwiftPM lives alongside the Xcode project (Whistt/Whistt.xcodeproj).
// It exposes a small library of pure-Foundation logic for testing via `swift test`,
// plus provider-specific probe CLIs for verifying live transcription protocols.
let package = Package(
    name: "Whistt",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "WhisttCore", targets: ["WhisttCore"]),
        .executable(name: "realtime-probe", targets: ["RealtimeProbe"]),
        .executable(name: "gemini-live-probe", targets: ["GeminiLiveProbe"]),
        .executable(name: "meta-live-probe", targets: ["MetaLiveProbe"])
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
                "WhisttLog.swift",
                "SoundFeedback.swift"
            ],
            sources: [
                "EnvLoader.swift",
                "KeychainStore.swift",
                "TranscriptionProvider.swift",
                "TranscriptionTransport.swift",
                "RealtimeProtocol.swift",
                "RealtimeWS.swift",
                "GeminiLiveProtocol.swift",
                "GeminiLiveWS.swift",
                "MetaTranscriptionProtocol.swift",
                "MetaTranscriptionWS.swift"
            ]
        ),
        .executableTarget(
            name: "RealtimeProbe",
            dependencies: ["WhisttCore"],
            path: "Tools/RealtimeProbe"
        ),
        .executableTarget(
            name: "GeminiLiveProbe",
            dependencies: ["WhisttCore"],
            path: "Tools/GeminiLiveProbe"
        ),
        .executableTarget(
            name: "MetaLiveProbe",
            dependencies: ["WhisttCore"],
            path: "Tools/MetaLiveProbe"
        ),
        .testTarget(
            name: "WhisttCoreTests",
            dependencies: ["WhisttCore"],
            path: "Tests/WhisttCoreTests"
        )
    ]
)
