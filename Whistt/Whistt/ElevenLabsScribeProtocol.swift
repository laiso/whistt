import Foundation

/// Client messages for the ElevenLabs Scribe v2 Realtime WebSocket
/// (`wss://api.elevenlabs.io/v1/speech-to-text/realtime`).
public enum ElevenLabsScribeMessage {
    public static let defaultModel = "scribe_v2_realtime"
    public static let sampleRate = 16_000

    /// Manual commit keeps turn boundaries under Whistt's push-to-talk control
    /// (same rationale as Azure Voice Live disabling automatic VAD).
    public static func streamURL(model: String = defaultModel) -> URL {
        var components = URLComponents(string: "wss://api.elevenlabs.io/v1/speech-to-text/realtime")!
        components.queryItems = [
            URLQueryItem(name: "model_id", value: model),
            URLQueryItem(name: "audio_format", value: "pcm_16000"),
            URLQueryItem(name: "commit_strategy", value: "manual"),
        ]
        return components.url!
    }

    public static func audioChunk(_ data: Data, sampleRate: Int = sampleRate, commit: Bool = false) -> String {
        let object: [String: Any] = [
            "message_type": "input_audio_chunk",
            "audio_base_64": data.base64EncodedString(),
            "commit": commit,
            "sample_rate": sampleRate,
        ]
        guard let payload = try? JSONSerialization.data(withJSONObject: object) else { return "" }
        return String(decoding: payload, as: UTF8.self)
    }

    /// Finalize the current segment after push-to-talk ends.
    public static func commit(sampleRate: Int = sampleRate) -> String {
        audioChunk(Data(), sampleRate: sampleRate, commit: true)
    }
}

public enum ElevenLabsScribeEvent: Equatable {
    case sessionStarted(sessionId: String?)
    /// Interim text for the *current* uncommitted segment (may change).
    case partialTranscript(text: String)
    /// Stable text for one committed segment (not necessarily the whole turn).
    case committedTranscript(text: String)
    case error(code: String?, message: String)
    case unknown(String)

    public static func decode(from string: String) -> ElevenLabsScribeEvent? {
        guard let json = try? JSONSerialization.jsonObject(with: Data(string.utf8)) as? [String: Any] else {
            return nil
        }
        guard let type = json["message_type"] as? String else {
            return .unknown("<missing message_type>")
        }
        switch type {
        case "session_started":
            return .sessionStarted(sessionId: json["session_id"] as? String)
        case "partial_transcript":
            return .partialTranscript(text: (json["text"] as? String) ?? "")
        case "committed_transcript", "committed_transcript_with_timestamps":
            return .committedTranscript(text: (json["text"] as? String) ?? "")
        case "committed_transcript_entities", "warning":
            return .unknown(type)
        case "error",
             "auth_error",
             "quota_exceeded",
             "transcriber_error",
             "input_error",
             "invalid_request",
             "commit_throttled",
             "unaccepted_terms",
             "rate_limited",
             "queue_overflow",
             "resource_exhausted",
             "session_time_limit_exceeded",
             "chunk_size_exceeded",
             "insufficient_audio_activity":
            let message = (json["error"] as? String)
                ?? (json["message"] as? String)
                ?? type
            return .error(code: type == "error" ? nil : type, message: message)
        default:
            return .unknown(type)
        }
    }
}

public enum ElevenLabsScribeFormat {
    public static let sampleRate = Double(ElevenLabsScribeMessage.sampleRate)
}
