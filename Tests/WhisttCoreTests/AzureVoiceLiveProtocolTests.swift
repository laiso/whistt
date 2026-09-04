import XCTest
@testable import WhisttCore

final class AzureVoiceLiveProtocolTests: XCTestCase {
    func testSessionUpdateContainsTranscriptionModelAndDisablesAutomaticVAD() throws {
        let message = try AzureVoiceLiveMessage.sessionUpdate(model: "mai-transcribe-2")
        let json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(message.utf8)) as? [String: Any]
        )
        XCTAssertEqual(json["type"] as? String, "session.update")
        let session = try XCTUnwrap(json["session"] as? [String: Any])
        let transcription = try XCTUnwrap(
            session["input_audio_transcription"] as? [String: Any]
        )
        XCTAssertEqual(transcription["model"] as? String, "mai-transcribe-2")
        XCTAssertTrue(session["turn_detection"] is NSNull)
    }

    func testAudioAppendBase64EncodesPayload() throws {
        let payload = Data([0x01, 0x02, 0x03, 0x04])
        let message = AzureVoiceLiveMessage.audioAppend(payload)
        let json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(message.utf8)) as? [String: Any]
        )
        XCTAssertEqual(json["type"] as? String, "input_audio_buffer.append")
        let audio = try XCTUnwrap(json["audio"] as? String)
        XCTAssertEqual(Data(base64Encoded: audio), payload)
    }

    func testDecodeTranscriptCompleted() {
        let event = AzureVoiceLiveEvent.decode(
            from: #"{"type":"conversation.item.input_audio_transcription.completed","transcript":"こんにちは","language":"ja"}"#
        )
        XCTAssertEqual(event, .transcriptCompleted(text: "こんにちは"))
    }

    func testDecodeSessionUpdated() {
        XCTAssertEqual(
            AzureVoiceLiveEvent.decode(from: #"{"type":"session.updated"}"#),
            .sessionUpdated
        )
    }

    func testDecodeBufferCommittedAndSpeechEvents() {
        XCTAssertEqual(
            AzureVoiceLiveEvent.decode(from: #"{"type":"input_audio_buffer.committed"}"#),
            .bufferCommitted
        )
        XCTAssertEqual(
            AzureVoiceLiveEvent.decode(from: #"{"type":"input_audio_buffer.speech_started"}"#),
            .speechStarted
        )
        XCTAssertEqual(
            AzureVoiceLiveEvent.decode(from: #"{"type":"input_audio_buffer.speech_stopped"}"#),
            .speechStopped
        )
    }

    func testDecodeErrorIncludesCodeAndMessage() {
        let event = AzureVoiceLiveEvent.decode(
            from: #"{"type":"error","error":{"code":"invalid_api_key","message":"bad key"}}"#
        )
        XCTAssertEqual(event, .error(code: "invalid_api_key", message: "bad key"))
    }

    func testDecodeUnknownEventIsPreserved() {
        XCTAssertEqual(
            AzureVoiceLiveEvent.decode(from: #"{"type":"rate_limits.updated"}"#),
            .unknown("rate_limits.updated")
        )
    }

    func testStreamURLConvertsEndpointToWebSocket() throws {
        let url = try XCTUnwrap(
            AzureVoiceLiveFormat.streamURL(endpoint: "https://example.cognitiveservices.azure.com/")
        )
        XCTAssertEqual(url.scheme, "wss")
        XCTAssertEqual(url.host, "example.cognitiveservices.azure.com")
        XCTAssertEqual(url.path, "/voice-live/realtime")
        let items = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        XCTAssertTrue(items.contains(URLQueryItem(name: "api-version", value: AzureVoiceLiveMessage.apiVersion)))
        XCTAssertTrue(items.contains(URLQueryItem(name: "model", value: AzureVoiceLiveMessage.conversationModel)))
    }

    func testStreamURLRejectsInvalidEndpoints() {
        XCTAssertNil(AzureVoiceLiveFormat.streamURL(endpoint: ""))
        XCTAssertNil(AzureVoiceLiveFormat.streamURL(endpoint: "not a url"))
    }
}
