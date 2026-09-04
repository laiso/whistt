import Foundation

public enum OutputMode: String, CaseIterable, Identifiable {
    case typing
    case clipboard

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .typing: return "Type at cursor"
        case .clipboard: return "Clipboard"
        }
    }
}

public enum AppPreferences {
    public static let outputModeDefaultsKey = "WHISTT_OUTPUT_MODE"
    public static let recordingStartSoundDefaultsKey = "WHISTT_PLAY_RECORDING_STARTED_SOUND"

    public static func outputMode(defaults: UserDefaults = .standard) -> OutputMode {
        defaults.string(forKey: outputModeDefaultsKey)
            .flatMap(OutputMode.init(rawValue:)) ?? .typing
    }

    public static func setOutputMode(_ mode: OutputMode, defaults: UserDefaults = .standard) {
        defaults.set(mode.rawValue, forKey: outputModeDefaultsKey)
    }

    public static func playsRecordingStartSound(defaults: UserDefaults = .standard) -> Bool {
        guard defaults.object(forKey: recordingStartSoundDefaultsKey) != nil else { return true }
        return defaults.bool(forKey: recordingStartSoundDefaultsKey)
    }

    public static func setPlaysRecordingStartSound(_ enabled: Bool, defaults: UserDefaults = .standard) {
        defaults.set(enabled, forKey: recordingStartSoundDefaultsKey)
    }
}
