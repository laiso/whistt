import XCTest
@testable import WhisttCore

final class ElevenLabsScribeProtocolTests: XCTestCase {
    func testStreamURLUsesManualCommitAndPCM16k() throws {
        let url = ElevenLabsScribeMessage.streamURL(model: "scribe_v2_realtime")
        XCTAssertEqual(url.scheme, "wss")
        XCTAssertEqual(url.host, "api.elevenlabs.io")
        XCTAssertEqual(url.path, "/v1/speech-to-text/realtime")
        let items = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        XCTAssertTrue(items.contains(URLQueryItem(name: "model_id", value: "scribe_v2_realtime")))
        XCTAssertTrue(items.contains(URLQueryItem(name: "audio_format", value: "pcm_16000")))
        XCTAssertTrue(items.contains(URLQueryItem(name: "commit_strategy", value: "manual")))
    }

    func testAudioChunkBase64EncodesPayload() throws {
        let payload = Data([0x01, 0x02, 0x03, 0x04])
        let message = ElevenLabsScribeMessage.audioChunk(payload)
        let json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(message.utf8)) as? [String: Any]
        )
        XCTAssertEqual(json["message_type"] as? String, "input_audio_chunk")
        XCTAssertEqual(json["commit"] as? Bool, false)
        XCTAssertEqual(json["sample_rate"] as? Int, 16_000)
        let audio = try XCTUnwrap(json["audio_base_64"] as? String)
        XCTAssertEqual(Data(base64Encoded: audio), payload)
    }

    func testCommitMessageUsesEmptyAudioAndCommitFlag() throws {
        let message = ElevenLabsScribeMessage.commit()
        let json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(message.utf8)) as? [String: Any]
        )
        XCTAssertEqual(json["message_type"] as? String, "input_audio_chunk")
        XCTAssertEqual(json["commit"] as? Bool, true)
        XCTAssertEqual(json["audio_base_64"] as? String, "")
        XCTAssertEqual(json["sample_rate"] as? Int, 16_000)
    }

    func testDecodeSessionStarted() {
        XCTAssertEqual(
            ElevenLabsScribeEvent.decode(
                from: #"{"message_type":"session_started","session_id":"sess-1","config":{}}"#
            ),
            .sessionStarted(sessionId: "sess-1")
        )
    }

    func testDecodePartialAndCommittedTranscripts() {
        XCTAssertEqual(
            ElevenLabsScribeEvent.decode(
                from: #"{"message_type":"partial_transcript","text":"こん"}"#
            ),
            .partialTranscript(text: "こん")
        )
        XCTAssertEqual(
            ElevenLabsScribeEvent.decode(
                from: #"{"message_type":"committed_transcript","text":"こんにちは"}"#
            ),
            .committedTranscript(text: "こんにちは")
        )
        XCTAssertEqual(
            ElevenLabsScribeEvent.decode(
                from: #"{"message_type":"committed_transcript_with_timestamps","text":"hello","words":[]}"#
            ),
            .committedTranscript(text: "hello")
        )
    }

    func testDecodeTypedErrorsPreserveCode() {
        XCTAssertEqual(
            ElevenLabsScribeEvent.decode(
                from: #"{"message_type":"auth_error","error":"bad key"}"#
            ),
            .error(code: "auth_error", message: "bad key")
        )
        XCTAssertEqual(
            ElevenLabsScribeEvent.decode(
                from: #"{"message_type":"error","error":"generic failure"}"#
            ),
            .error(code: nil, message: "generic failure")
        )
    }

    func testDecodeUnknownEventIsPreserved() {
        XCTAssertEqual(
            ElevenLabsScribeEvent.decode(from: #"{"message_type":"future_event"}"#),
            .unknown("future_event")
        )
    }
}
