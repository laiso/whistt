import Foundation

public enum MetaTranscriptionMessage {
    public static func handshake(
        apiKey: String,
        model: String,
        languageBias: [String] = ["Japanese"],
        keywords: [String] = []
    ) throws -> String {
        var object: [String: Any] = [
            "authorization": ["accessToken": "Bearer \(apiKey)"],
            "model": model,
            "audioEncoding": "PCM_24KHZ",
            "mode": "PUSH_TO_TALK",
            "partialMode": "CUMULATIVE",
            "emitAudioProgress": false
        ]
        if !languageBias.isEmpty { object["languageBias"] = languageBias }
        if !keywords.isEmpty { object["keywords"] = keywords }
        let data = try JSONSerialization.data(withJSONObject: object)
        return String(decoding: data, as: UTF8.self)
    }

    public static let endStream = #"{"type":"endStream"}"#
}

public enum MetaTranscriptionEvent: Equatable {
    case handshakeAcknowledged(sessionId: String?)
    case transcript(text: String, final: Bool)
    case speechStart(turnId: String?)
    case speechEnd(turnId: String?)
    case speechComplete(text: String, turnId: String?)
    case audioProgress(milliseconds: Int?)
    case error(code: String?, message: String)
    case unknown(String)

    public static func decode(from string: String) -> MetaTranscriptionEvent? {
        guard let json = try? JSONSerialization.jsonObject(with: Data(string.utf8)) as? [String: Any] else {
            return nil
        }
        guard let type = json["type"] as? String else {
            return .handshakeAcknowledged(sessionId: json["sessionId"] as? String)
        }
        switch type {
        case "transcript":
            let text = (json["transcript"] as? String) ?? (json["text"] as? String) ?? ""
            return .transcript(text: text, final: json["final"] as? Bool ?? false)
        case "speechStart":
            return .speechStart(turnId: json["turnId"] as? String)
        case "speechEnd":
            return .speechEnd(turnId: json["turnId"] as? String)
        case "speechComplete":
            let text = (json["transcript"] as? String) ?? (json["text"] as? String) ?? ""
            return .speechComplete(text: text, turnId: json["turnId"] as? String)
        case "audioProgress":
            let milliseconds = (json["processedMs"] as? NSNumber)?.intValue
                ?? (json["audioProcessedMs"] as? NSNumber)?.intValue
            return .audioProgress(milliseconds: milliseconds)
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
