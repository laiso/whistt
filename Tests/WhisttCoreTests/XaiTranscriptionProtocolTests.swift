import XCTest
@testable import WhisttCore

final class XaiTranscriptionProtocolTests: XCTestCase {
    func testStreamURLUsesQueryParameterConfiguration() throws {
        let url = try XCTUnwrap(XaiTranscriptionFormat.streamURL())
        XCTAssertEqual(url.absoluteString, "wss://api.x.ai/v1/stt?encoding=pcm&sample_rate=16000&interim_results=true")
        XCTAssertEqual(XaiTranscriptionFormat.sampleRate, 16_000)
    }

    func testStreamURLOmitsInterimResultsWhenDisabled() {
        let url = XaiTranscriptionFormat.streamURL(interimResults: false)
        XCTAssertTrue(url.absoluteString.hasSuffix("interim_results=false"))
    }

    func testControlMessagesAreExactJSON() {
        XCTAssertEqual(XaiTranscriptionMessage.finalize, #"{"type":"finalize"}"#)
        XCTAssertEqual(XaiTranscriptionMessage.audioDone, #"{"type":"audio.done"}"#)
    }

    func testDecodesSetupEvent() {
        XCTAssertEqual(
            XaiTranscriptionEvent.decode(from: #"{"type":"transcript.created"}"#),
            .created
        )
    }

    func testDecodesInterimPartial() {
        XCTAssertEqual(
            XaiTranscriptionEvent.decode(
                from: #"{"type":"transcript.partial","transcript":"こんにち","is_final":false,"speech_final":false}"#
            ),
            .partial(text: "こんにち", isFinal: false, speechFinal: false)
        )
    }

    func testDecodesChunkFinalPartial() {
        XCTAssertEqual(
            XaiTranscriptionEvent.decode(
                from: #"{"type":"transcript.partial","transcript":"こんにちは","is_final":true,"speech_final":false}"#
            ),
            .partial(text: "こんにちは", isFinal: true, speechFinal: false)
        )
    }

    func testDecodesUtteranceFinalPartial() {
        XCTAssertEqual(
            XaiTranscriptionEvent.decode(
                from: #"{"type":"transcript.partial","transcript":"こんにちは。","is_final":true,"speech_final":true}"#
            ),
            .partial(text: "こんにちは。", isFinal: true, speechFinal: true)
        )
    }

    func testDecodesDoneEvent() {
        XCTAssertEqual(
            XaiTranscriptionEvent.decode(
                from: #"{"type":"transcript.done","transcript":"完了しました","duration":3.5}"#
            ),
            .done(text: "完了しました")
        )
    }

    func testDecodesErrorEvent() {
        XCTAssertEqual(
            XaiTranscriptionEvent.decode(
                from: #"{"type":"error","error":{"code":"rate_limited","message":"slow down"}}"#
            ),
            .error(code: "rate_limited", message: "slow down")
        )
        XCTAssertEqual(
            XaiTranscriptionEvent.decode(from: #"{"type":"error","message":"bad frame"}"#),
            .error(code: nil, message: "bad frame")
        )
    }

    func testUnknownEventsRemainForwardCompatible() {
        XCTAssertEqual(
            XaiTranscriptionEvent.decode(from: #"{"type":"futureEvent"}"#),
            .unknown("futureEvent")
        )
        XCTAssertNil(XaiTranscriptionEvent.decode(from: "not json"))
    }

    func testBufferCorrectsCursorWhenCumulativeSnapshotRepeatsText() {
        // Simulates xAI cumulative chunk finals: the second chunk final
        // contains the whole transcript, so re-appending would duplicate it.
        // The transport delivers prefix diffs; a replacement snapshot falls
        // back to the buffer's prefix-diff correction.
        let buffer = TranscriptRevisionBuffer()
        XCTAssertEqual(
            buffer.apply(TranscriptRevision(confirmedText: "こんにちは", interimText: "", appendSafeSuffix: "こんにちは")),
            [.type("こんにちは")]
        )
        // A snapshot that differs from what was typed gets corrected by
        // keeping only the shared prefix and typing the tail.
        let ops = buffer.apply(TranscriptRevision(confirmedText: "こんにちは。", interimText: ""))
        XCTAssertEqual(ops, [.type("。")])
    }
}
