import XCTest
@testable import WhisttCore

final class RealtimeProtocolTests: XCTestCase {

    // MARK: - SessionUpdate Codable shape

    func testSessionUpdateShape() throws {
        let json = try RealtimeMessage.sessionUpdate(model: "gpt-realtime-whisper")
        let decoded = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]
        XCTAssertEqual(decoded?["type"] as? String, "session.update")

        let sess = try XCTUnwrap(decoded?["session"] as? [String: Any])
        XCTAssertEqual(sess["type"] as? String, "transcription")
        // No output_modalities on a transcription session.
        XCTAssertNil(sess["output_modalities"])

        let audio = try XCTUnwrap(sess["audio"] as? [String: Any])
        let input = try XCTUnwrap(audio["input"] as? [String: Any])

        let format = try XCTUnwrap(input["format"] as? [String: Any])
        XCTAssertEqual(format["type"] as? String, "audio/pcm")
        XCTAssertEqual(format["rate"] as? Int, 24000)

        let trans = try XCTUnwrap(input["transcription"] as? [String: Any])
        XCTAssertEqual(trans["model"] as? String, "gpt-realtime-whisper")

        // The `turn_detection` field MUST be present as JSON null — not absent.
        // Disables server VAD so we can manually commit on hotkey release.
        XCTAssertTrue(input.keys.contains("turn_detection"))
        XCTAssertTrue(input["turn_detection"] is NSNull)
    }

    func testSessionUpdateUsesPassedModelName() throws {
        let json = try RealtimeMessage.sessionUpdate(model: "whisper-1")
        let decoded = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]
        let trans = ((decoded?["session"] as? [String: Any])?["audio"] as? [String: Any])?["input"] as? [String: Any]
        let model = (trans?["transcription"] as? [String: Any])?["model"] as? String
        XCTAssertEqual(model, "whisper-1")
    }

    // MARK: - Audio append hot-path

    func testAudioAppendShapeMatchesLegacyDict() throws {
        let pcm = Data(repeating: 0x42, count: 4800)
        let fastPath = RealtimeMessage.audioAppend(pcm)
        let slowPath = try JSONSerialization.data(withJSONObject: [
            "type": "input_audio_buffer.append",
            "audio": pcm.base64EncodedString()
        ])
        // Compare semantically (key order may differ across JSON producers).
        let a = try JSONSerialization.jsonObject(with: Data(fastPath.utf8)) as? [String: String]
        let b = try JSONSerialization.jsonObject(with: slowPath) as? [String: String]
        XCTAssertEqual(a, b)
    }

    func testAudioCommitIsLiteralConstant() {
        XCTAssertEqual(RealtimeMessage.audioCommit, "{\"type\":\"input_audio_buffer.commit\"}")
    }

    // MARK: - Event decoding

    func testDecodesSessionLifecycleEvents() {
        XCTAssertEqual(RealtimeEvent.decode(from: #"{"type":"session.created"}"#), .sessionCreated)
        XCTAssertEqual(RealtimeEvent.decode(from: #"{"type":"session.updated"}"#), .sessionUpdated)
        XCTAssertEqual(RealtimeEvent.decode(from: #"{"type":"input_audio_buffer.speech_started"}"#), .speechStarted)
        XCTAssertEqual(RealtimeEvent.decode(from: #"{"type":"input_audio_buffer.committed"}"#), .bufferCommitted)
    }

    func testDecodesDeltaVariants() {
        let cases = [
            "conversation.item.input_audio_transcription.delta",
            "response.audio_transcript.delta",
            "response.text.delta"
        ]
        for type in cases {
            let json = "{\"type\":\"\(type)\",\"delta\":\"hello\"}"
            XCTAssertEqual(RealtimeEvent.decode(from: json), .delta("hello"), "type=\(type)")
        }
    }

    func testEmptyDeltaIsDropped() {
        XCTAssertNil(RealtimeEvent.decode(from: #"{"type":"response.text.delta","delta":""}"#))
    }

    func testDeltaWithoutFieldIsDropped() {
        XCTAssertNil(RealtimeEvent.decode(from: #"{"type":"response.text.delta"}"#))
    }

    func testDecodesFinalTranscriptFromTranscriptField() {
        let e = RealtimeEvent.decode(from: #"{"type":"conversation.item.input_audio_transcription.completed","transcript":"hi"}"#)
        XCTAssertEqual(e, .finalTranscript("hi"))
    }

    func testDecodesFinalTranscriptFromTextField() {
        let e = RealtimeEvent.decode(from: #"{"type":"response.text.done","text":"hi"}"#)
        XCTAssertEqual(e, .finalTranscript("hi"))
    }

    func testDecodesConversationItemTranscripts() {
        let json = #"""
        {"type":"conversation.item.added","item":{"content":[
            {"transcript":"hello"},
            {"text":"world"},
            {"transcript":""},
            {}
        ]}}
        """#
        let event = RealtimeEvent.decode(from: json)
        XCTAssertEqual(event, .conversationItem(transcripts: ["hello", "world"]))
    }

    func testDecodesConversationItemWithNoContent() {
        let e = RealtimeEvent.decode(from: #"{"type":"conversation.item.done"}"#)
        XCTAssertEqual(e, .conversationItem(transcripts: []))
    }

    func testDecodesTranscriptionFailed() {
        let json = #"{"type":"conversation.item.input_audio_transcription.failed","error":{"code":"insufficient_audio","message":"too short"}}"#
        XCTAssertEqual(
            RealtimeEvent.decode(from: json),
            .transcriptionFailed(code: "insufficient_audio", message: "too short")
        )
    }

    func testDecodesTranscriptionFailedWithMissingFields() {
        let e = RealtimeEvent.decode(from: #"{"type":"conversation.item.input_audio_transcription.failed"}"#)
        XCTAssertEqual(e, .transcriptionFailed(code: "?", message: "unknown"))
    }

    func testDecodesErrorEvent() {
        let json = #"{"type":"error","error":{"message":"bad request"}}"#
        XCTAssertEqual(RealtimeEvent.decode(from: json), .error(message: "bad request"))
    }

    func testDecodesUnknownTypeAsUnknown() {
        XCTAssertEqual(
            RealtimeEvent.decode(from: #"{"type":"something.new"}"#),
            .unknown(type: "something.new")
        )
    }

    func testReturnsNilForMalformedJSON() {
        XCTAssertNil(RealtimeEvent.decode(from: "not json"))
        XCTAssertNil(RealtimeEvent.decode(from: #"{"no_type":1}"#))
    }
}
