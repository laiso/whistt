import XCTest
@testable import WhisttCore

final class MetaTranscriptionProtocolTests: XCTestCase {
    func testHandshakeUsesInBandAuthenticationAndNativeAudioFormat() throws {
        let string = try MetaTranscriptionMessage.handshake(
            apiKey: "meta-secret",
            model: "muse-voice-transcribe-1.0"
        )
        let json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(string.utf8)) as? [String: Any]
        )
        let authorization = try XCTUnwrap(json["authorization"] as? [String: Any])
        XCTAssertEqual(authorization["accessToken"] as? String, "Bearer meta-secret")
        XCTAssertEqual(json["model"] as? String, "muse-voice-transcribe-1.0")
        XCTAssertEqual(json["audioEncoding"] as? String, "PCM_24KHZ")
        XCTAssertEqual(json["mode"] as? String, "PUSH_TO_TALK")
        XCTAssertEqual(json["partialMode"] as? String, "CUMULATIVE")
        XCTAssertEqual(json["languageBias"] as? [String], ["Japanese"])
    }

    func testEndStreamIsExactControlMessage() {
        XCTAssertEqual(MetaTranscriptionMessage.endStream, #"{"type":"endStream"}"#)
    }

    func testDecodesHandshakeAcknowledgementWithoutType() {
        XCTAssertEqual(
            MetaTranscriptionEvent.decode(from: #"{"sessionId":"session-1"}"#),
            .handshakeAcknowledged(sessionId: "session-1")
        )
    }

    func testDecodesCumulativePartialAndFinal() {
        XCTAssertEqual(
            MetaTranscriptionEvent.decode(from: #"{"type":"transcript","transcript":"こん","final":false}"#),
            .transcript(text: "こん", final: false)
        )
        XCTAssertEqual(
            MetaTranscriptionEvent.decode(from: #"{"type":"transcript","transcript":"こんにちは。","final":true}"#),
            .transcript(text: "こんにちは。", final: true)
        )
    }

    func testDecodesSpeechCompleteByTurnID() {
        XCTAssertEqual(
            MetaTranscriptionEvent.decode(from: #"{"type":"speechComplete","turnId":"turn-2","transcript":"完了"}"#),
            .speechComplete(text: "完了", turnId: "turn-2")
        )
    }

    func testUnknownEventsRemainForwardCompatible() {
        XCTAssertEqual(
            MetaTranscriptionEvent.decode(from: #"{"type":"futureEvent"}"#),
            .unknown("futureEvent")
        )
    }
}
