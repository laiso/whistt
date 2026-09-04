import Foundation

/// Client messages for the Azure Voice Live WebSocket
/// (`<endpoint>/voice-live/realtime?api-version=2026-04-10&model=<conversation-model>`).
///
/// The URL's `model` query selects the *conversational* model Voice Live hosts;
/// the transcription model (`mai-transcribe-2`) is set separately in
/// `session.input_audio_transcription.model`.
public enum AzureVoiceLiveMessage {
    /// The hosted conversation model the realtime endpoint is created with.
    public static let conversationModel = "gpt-4.1"
    public static let apiVersion = "2026-04-10"

    public static func sessionUpdate(model: String) throws -> String {
        let update: [String: Any] = [
            "type": "session.update",
            "session": [
                "input_audio_transcription": [
                    "model": model
                ],
                "turn_detection": [
                    // Server-side VAD ends the turn automatically so a manual
                    // commit is only needed when the hotkey is released mid-speech.
                    "type": "azure_semantic_vad_multilingual",
                    "create_response": false
                ]
            ]
        ]
        let data = try JSONSerialization.data(withJSONObject: update)
        return String(decoding: data, as: UTF8.self)
    }

    public static func audioAppend(_ data: Data) -> String {
        let append: [String: Any] = [
            "type": "input_audio_buffer.append",
            "audio": data.base64EncodedString()
        ]
        guard let payload = try? JSONSerialization.data(withJSONObject: append) else { return "" }
        return String(decoding: payload, as: UTF8.self)
    }

    public static let audioCommit = #"{"type":"input_audio_buffer.commit"}"#
}

public enum AzureVoiceLiveEvent: Equatable {
    case sessionUpdated
    case speechStarted
    case speechStopped
    case bufferCommitted
    /// Final transcript for the turn's input audio. Voice Live's
    /// mai-transcribe-2 does not emit interim results.
    case transcriptCompleted(text: String)
    case error(code: String?, message: String)
    case unknown(String)

    public static func decode(from string: String) -> AzureVoiceLiveEvent? {
        guard let json = try? JSONSerialization.jsonObject(with: Data(string.utf8)) as? [String: Any] else {
            return nil
        }
        guard let type = json["type"] as? String else {
            return .unknown("<missing type>")
        }
        switch type {
        case "session.updated":
            return .sessionUpdated
        case "input_audio_buffer.speech_started":
            return .speechStarted
        case "input_audio_buffer.speech_stopped":
            return .speechStopped
        case "input_audio_buffer.committed":
            return .bufferCommitted
        case "conversation.item.input_audio_transcription.completed":
            let text = (json["transcript"] as? String) ?? (json["text"] as? String) ?? ""
            return .transcriptCompleted(text: text)
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

public enum AzureVoiceLiveFormat {
    /// Voice Live accepts PCM16 mono at 24 kHz, matching the OpenAI transport.
    public static let sampleRate = 24_000.0

    /// WebSocket URL derived from an Azure Speech resource endpoint
    /// (`AZURE_SPEECH_ENDPOINT`). Returns nil when the endpoint is missing or
    /// malformed so the caller can surface a configuration error instead of
    /// dialing a garbage host.
    public static func streamURL(endpoint: String) -> URL? {
        let trimmed = endpoint.trimmingCharacters(in: CharacterSet(charactersIn: "/ \n\r\t"))
        guard !trimmed.isEmpty, trimmed.hasPrefix("http") else { return nil }
        let wss = trimmed.replacingOccurrences(of: "https://", with: "wss://")
            .replacingOccurrences(of: "http://", with: "ws://")
        return URL(string: "\(wss)/voice-live/realtime?api-version=\(AzureVoiceLiveMessage.apiVersion)&model=\(AzureVoiceLiveMessage.conversationModel)")
    }
}
