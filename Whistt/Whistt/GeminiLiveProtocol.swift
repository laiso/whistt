import Foundation

public enum GeminiLiveMessage {
    public static func setup(
        model: String,
        languageCodes: [String] = ["ja-JP"]
    ) throws -> String {
        let object: [String: Any] = [
            "setup": [
                "model": model.hasPrefix("models/") ? model : "models/\(model)",
                "generationConfig": ["responseModalities": ["TEXT"]],
                "realtimeInputConfig": [
                    "automaticActivityDetection": ["disabled": true]
                ],
                "inputAudioTranscription": ["languageCodes": languageCodes]
            ]
        ]
        return try encode(object)
    }

    public static let activityStart = #"{"realtimeInput":{"activityStart":{}}}"#
    public static let activityEnd = #"{"realtimeInput":{"activityEnd":{}}}"#

    public static func audio(_ data: Data, sampleRate: Int = 16_000) -> String {
        #"{"realtimeInput":{"audio":{"data":"\#(data.base64EncodedString())","mimeType":"audio/pcm;rate=\#(sampleRate)"}}}"#
    }

    private static func encode(_ object: [String: Any]) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: object)
        return String(decoding: data, as: UTF8.self)
    }
}

public enum GeminiLiveEvent: Equatable {
    case setupComplete
    case interimTranscript(String)
    case finalTranscript(String)
    case turnComplete
    case error(String)
    case unknown

    public static func decode(from string: String) -> GeminiLiveEvent? {
        guard let json = try? JSONSerialization.jsonObject(with: Data(string.utf8)) as? [String: Any] else {
            return nil
        }
        if json["setupComplete"] != nil { return .setupComplete }
        if let error = json["error"] as? [String: Any] {
            return .error(error["message"] as? String ?? "unknown")
        }
        guard let content = json["serverContent"] as? [String: Any] else { return .unknown }
        if let interim = content["interimInputTranscription"] as? [String: Any],
           let text = interim["text"] as? String, !text.isEmpty {
            return .interimTranscript(text)
        }
        if let final = content["inputTranscription"] as? [String: Any],
           let text = final["text"] as? String, !text.isEmpty {
            return .finalTranscript(text)
        }
        if content["turnComplete"] as? Bool == true { return .turnComplete }
        return .unknown
    }
}
