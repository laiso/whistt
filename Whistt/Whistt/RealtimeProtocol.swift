import Foundation

/// String-keyed identifiers for messages we send to the OpenAI Realtime WS.
public enum RealtimeOutgoingType: String {
    case sessionUpdate = "session.update"
    case audioAppend = "input_audio_buffer.append"
    case audioCommit = "input_audio_buffer.commit"
}

/// String-keyed identifiers for messages we receive.
public enum RealtimeIncomingType: String {
    case sessionCreated = "session.created"
    case sessionUpdated = "session.updated"
    case speechStarted = "input_audio_buffer.speech_started"
    case bufferCommitted = "input_audio_buffer.committed"
    case transcriptionDelta = "conversation.item.input_audio_transcription.delta"
    case audioTranscriptDelta = "response.audio_transcript.delta"
    case textDelta = "response.text.delta"
    case transcriptionCompleted = "conversation.item.input_audio_transcription.completed"
    case audioTranscriptDone = "response.audio_transcript.done"
    case textDone = "response.text.done"
    case conversationItemAdded = "conversation.item.added"
    case conversationItemDone = "conversation.item.done"
    case transcriptionFailed = "conversation.item.input_audio_transcription.failed"
    case error
}

/// session.update payload for the transcription-only flow: dedicated transcription
/// session type, manual commit (turn_detection: null), pcm16/24kHz input.
/// Hand-rolled `encode(to:)` so `turn_detection` is emitted as JSON null (Codable would omit it).
public struct RealtimeSessionUpdate: Encodable {
    public let model: String
    public init(model: String) { self.model = model }

    public func encode(to encoder: Encoder) throws {
        var top = encoder.container(keyedBy: TopKey.self)
        try top.encode(RealtimeOutgoingType.sessionUpdate.rawValue, forKey: .type)
        var sess = top.nestedContainer(keyedBy: SessionKey.self, forKey: .session)
        try sess.encode("transcription", forKey: .type)
        var audio = sess.nestedContainer(keyedBy: AudioKey.self, forKey: .audio)
        var input = audio.nestedContainer(keyedBy: InputKey.self, forKey: .input)
        var format = input.nestedContainer(keyedBy: FormatKey.self, forKey: .format)
        try format.encode("audio/pcm", forKey: .type)
        try format.encode(24000, forKey: .rate)
        var trans = input.nestedContainer(keyedBy: TranscriptionKey.self, forKey: .transcription)
        try trans.encode(model, forKey: .model)
        try input.encodeNil(forKey: .turnDetection)
    }

    private enum TopKey: String, CodingKey { case type, session }
    private enum SessionKey: String, CodingKey { case type, audio }
    private enum AudioKey: String, CodingKey { case input }
    private enum InputKey: String, CodingKey {
        case format
        case transcription
        case turnDetection = "turn_detection"
    }
    private enum FormatKey: String, CodingKey { case type, rate }
    private enum TranscriptionKey: String, CodingKey { case model }
}

/// Encoded JSON-string forms of the outgoing messages. The audio-append builder
/// is on the hot path (called ~10-20×/s) — base64 alphabet is JSON-safe (`A-Za-z0-9+/=`),
/// so we skip the `JSONSerialization` round trip and interpolate directly.
public enum RealtimeMessage {
    public static func sessionUpdate(model: String) throws -> String {
        let data = try JSONEncoder().encode(RealtimeSessionUpdate(model: model))
        return String(decoding: data, as: UTF8.self)
    }

    public static func audioAppend(base64: String) -> String {
        "{\"type\":\"\(RealtimeOutgoingType.audioAppend.rawValue)\",\"audio\":\"\(base64)\"}"
    }

    public static func audioAppend(_ data: Data) -> String {
        audioAppend(base64: data.base64EncodedString())
    }

    public static let audioCommit = "{\"type\":\"\(RealtimeOutgoingType.audioCommit.rawValue)\"}"
}

/// Parsed form of a single incoming WS event.
public enum RealtimeEvent: Equatable {
    case sessionCreated
    case sessionUpdated
    case speechStarted
    case bufferCommitted
    case delta(String)
    case finalTranscript(String)
    /// Transcripts embedded in a conversation.item.added/done payload. May be empty.
    case conversationItem(transcripts: [String])
    case transcriptionFailed(code: String, message: String)
    case error(message: String)
    /// Type was recognized as a string but not one we model — kept so callers can log.
    case unknown(type: String)

    /// Returns nil for unparseable JSON or for empty-delta events (which would be noise).
    public static func decode(from data: Data) -> RealtimeEvent? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let typeStr = json["type"] as? String else { return nil }
        guard let type = RealtimeIncomingType(rawValue: typeStr) else {
            return .unknown(type: typeStr)
        }
        switch type {
        case .sessionCreated:
            return .sessionCreated
        case .sessionUpdated:
            return .sessionUpdated
        case .speechStarted:
            return .speechStarted
        case .bufferCommitted:
            return .bufferCommitted
        case .transcriptionDelta, .audioTranscriptDelta, .textDelta:
            guard let d = json["delta"] as? String, !d.isEmpty else { return nil }
            return .delta(d)
        case .transcriptionCompleted, .audioTranscriptDone, .textDone:
            guard let t = (json["transcript"] as? String) ?? (json["text"] as? String) else {
                return .unknown(type: typeStr)
            }
            return .finalTranscript(t)
        case .conversationItemAdded, .conversationItemDone:
            var transcripts: [String] = []
            if let item = json["item"] as? [String: Any],
               let content = item["content"] as? [[String: Any]] {
                for entry in content {
                    if let t = (entry["transcript"] as? String) ?? (entry["text"] as? String),
                       !t.isEmpty {
                        transcripts.append(t)
                    }
                }
            }
            return .conversationItem(transcripts: transcripts)
        case .transcriptionFailed:
            let err = json["error"] as? [String: Any]
            return .transcriptionFailed(
                code: err?["code"] as? String ?? "?",
                message: err?["message"] as? String ?? "unknown"
            )
        case .error:
            let err = json["error"] as? [String: Any]
            return .error(message: err?["message"] as? String ?? "unknown")
        }
    }
}

public extension RealtimeEvent {
    static func decode(from string: String) -> RealtimeEvent? {
        decode(from: Data(string.utf8))
    }
}
