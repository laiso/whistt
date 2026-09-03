import Foundation

/// Client messages for xAI's streaming STT WebSocket (`wss://api.x.ai/v1/stt`).
///
/// All session configuration is carried by connection query parameters; after
/// the handshake the client only sends binary audio frames plus these JSON
/// control messages.
public enum XaiTranscriptionMessage {
    /// Flush and finalize the current utterance; the session stays open.
    public static let finalize = #"{"type":"finalize"}"#

    /// End of stream: the server flushes remaining audio, emits final
    /// transcripts, sends `transcript.done`, and closes the connection.
    public static let audioDone = #"{"type":"audio.done"}"#
}

public enum XaiTranscriptionEvent: Equatable {
    /// First server message after the connection is established; audio may be
    /// sent only after this arrives.
    case created
    /// Partial transcript for a portion of the stream. `isFinal` distinguishes
    /// interim hypotheses from locked chunks; `speechFinal` marks the end of
    /// an utterance.
    case partial(text: String, isFinal: Bool, speechFinal: Bool)
    /// Final transcript emitted after `audio.done`; the server closes the
    /// connection afterwards.
    case done(text: String)
    case error(code: String?, message: String)
    case unknown(String)

    public static func decode(from string: String) -> XaiTranscriptionEvent? {
        guard let json = try? JSONSerialization.jsonObject(with: Data(string.utf8)) as? [String: Any] else {
            return nil
        }
        guard let type = json["type"] as? String else {
            return .unknown("<missing type>")
        }
        switch type {
        case "transcript.created":
            return .created
        case "transcript.partial":
            let text = (json["transcript"] as? String) ?? (json["text"] as? String) ?? ""
            let isFinal = json["is_final"] as? Bool ?? false
            let speechFinal = json["speech_final"] as? Bool ?? false
            return .partial(text: text, isFinal: isFinal, speechFinal: speechFinal)
        case "transcript.done":
            let text = (json["transcript"] as? String) ?? (json["text"] as? String) ?? ""
            return .done(text: text)
        case "error":
            let error = json["error"] as? [String: Any]
            let code = (error?["code"] as? String) ?? (json["code"] as? String)
            let message = (error?["message"] as? String) ?? (json["message"] as? String) ?? "unknown"
            return .error(code: code, message: message)
        default:
            return .unknown(type)
        }
    }
}

public enum XaiTranscriptionFormat {
    /// xAI streams PCM16 mono at 16 kHz for this integration.
    public static let sampleRate = 16_000.0

    /// Connection URL. `language` is intentionally unset so xAI auto-detects
    /// the spoken language; `interim_results=true` enables the revisable
    /// partials Whistt types while the user is speaking.
    public static func streamURL(interimResults: Bool = true) -> URL {
        var components = URLComponents(string: "wss://api.x.ai/v1/stt")!
        components.queryItems = [
            URLQueryItem(name: "encoding", value: "pcm"),
            URLQueryItem(name: "sample_rate", value: String(Int(sampleRate))),
            URLQueryItem(name: "interim_results", value: interimResults ? "true" : "false")
        ]
        return components.url!
    }
}
