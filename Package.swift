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
        .executable(name: "meta-live-probe", targets: ["MetaLiveProbe"]),
        .executable(name: "azure-voice-live-probe", targets: ["AzureVoiceLiveProbe"]),
        .executable(name: "xai-live-probe", targets: ["XaiLiveProbe"])
    ],
    targets: [
        .target(
            name: "WhisttCore",
            path: "Whistt/Whistt",
            exclude: [
                "Assets.xcassets",
                "SettingsView.swift",
                "WhisttApp.swift",
                "AppDelegate.swift",
                "HotKeyManager.swift",
                "WhisperNativeAgent.swift",
                "TypingEmulator.swift",
                "WhisttLog.swift",
                "SoundFeedback.swift"
            ],
            sources: [
                "AppPreferences.swift",
                "EnvLoader.swift",
                "KeychainStore.swift",
                "ProviderConfigurationService.swift",
                "TranscriptionModelCatalog.swift",
                "TranscriptionProvider.swift",
                "TranscriptionTransport.swift",
                "FinalTranscriptOutputGate.swift",
                "PCM16AudioFixture.swift",
                "AudioStreamSender.swift",
                "ShortcutBinding.swift",
                "ShortcutEngine.swift",
                "RealtimeProtocol.swift",
                "RealtimeWS.swift",
                "GeminiLiveProtocol.swift",
                "GeminiLiveWS.swift",
                "MetaTranscriptionProtocol.swift",
                "MetaTranscriptionWS.swift",
                "TranscriptRevision.swift",
                "XaiTranscriptionProtocol.swift",
                "XaiTranscriptionWS.swift",
                "AzureVoiceLiveProtocol.swift",
                "AzureVoiceLiveSettings.swift",
                "AzureVoiceLiveWS.swift"
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
        .executableTarget(
            name: "AzureVoiceLiveProbe",
            dependencies: ["WhisttCore"],
            path: "Tools/AzureVoiceLiveProbe"
        ),
        .executableTarget(
            name: "XaiLiveProbe",
            dependencies: ["WhisttCore"],
            path: "Tools/XaiLiveProbe"
        ),
        .testTarget(
            name: "WhisttCoreTests",
            dependencies: ["WhisttCore"],
            path: "Tests/WhisttCoreTests"
        )
    ]
)
