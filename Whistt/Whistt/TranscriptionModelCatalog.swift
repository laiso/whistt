import Foundation

public struct TranscriptionModelGroup: Identifiable, Equatable {
    public let vendor: String
    public let provider: TranscriptionProvider
    public let models: [String]

    public var id: String { "\(vendor):\(models.joined(separator: ","))" }
}

public enum TranscriptionModelCatalog {
    public static let groups: [TranscriptionModelGroup] = [
        TranscriptionModelGroup(vendor: "OpenAI", provider: .openAI, models: [
            "gpt-transcribe",
            "gpt-live-transcribe",
        ]),
        TranscriptionModelGroup(vendor: "Google", provider: .gemini, models: [
            "gemini-3.5-transcribe-live",
        ]),
        TranscriptionModelGroup(vendor: "Meta", provider: .meta, models: [
            "muse-voice-transcribe-1.0",
        ]),
        TranscriptionModelGroup(vendor: "xAI", provider: .xAI, models: [
            "xai-streaming-stt",
        ]),
        TranscriptionModelGroup(vendor: "Microsoft", provider: .azure, models: [
            "mai-transcribe-2",
        ]),
        TranscriptionModelGroup(vendor: "ElevenLabs", provider: .elevenLabs, models: [
            "scribe_v2_realtime",
        ]),
    ]

    public static let referencePricePerHour: [String: String] = [
        "mai-transcribe-2": "$0.10*",
        "muse-voice-transcribe-1.0": "$0.18",
        "xai-streaming-stt": "$0.20",
        "gpt-transcribe": "$0.27",
        "gemini-3.5-transcribe-live": "~$0.54",
        "gpt-live-transcribe": "$1.02",
        "scribe_v2_realtime": "$0.39",
    ]

    public static var models: [String] { groups.flatMap(\.models) }
    public static var defaultModel: String { groups[0].models[0] }

    public static func models(for provider: TranscriptionProvider) -> [String] {
        groups.filter { $0.provider == provider }.flatMap(\.models)
    }

    public static func group(containing model: String) -> TranscriptionModelGroup? {
        groups.first { $0.models.contains(model) }
    }

    public static func displayName(for model: String, vendor: String) -> String {
        guard let price = referencePricePerHour[model] else { return "\(vendor) · \(model)" }
        return "\(vendor) · \(model) · \(price)/hour"
    }

    public static func resolve(preferred model: String?) -> String {
        guard let model, models.contains(model) else { return defaultModel }
        return model
    }
}
