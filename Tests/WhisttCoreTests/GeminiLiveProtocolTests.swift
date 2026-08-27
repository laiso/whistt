import XCTest
@testable import WhisttCore

final class GeminiLiveProtocolTests: XCTestCase {
    func testSetupUsesManualVADAndJapanese() throws {
        let text = try GeminiLiveMessage.setup(model: "gemini-3.5-transcribe-live")
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        let setup = try XCTUnwrap(json["setup"] as? [String: Any])
        XCTAssertEqual(setup["model"] as? String, "models/gemini-3.5-transcribe-live")
        let generation = try XCTUnwrap(setup["generationConfig"] as? [String: Any])
        XCTAssertEqual(generation["responseModalities"] as? [String], ["TEXT"])
        let realtime = try XCTUnwrap(setup["realtimeInputConfig"] as? [String: Any])
        let vad = try XCTUnwrap(realtime["automaticActivityDetection"] as? [String: Any])
        XCTAssertEqual(vad["disabled"] as? Bool, true)
        let transcription = try XCTUnwrap(setup["inputAudioTranscription"] as? [String: Any])
        XCTAssertEqual(transcription["languageCodes"] as? [String], ["ja-JP"])
    }

    func testAudioShape() throws {
        let text = GeminiLiveMessage.audio(Data([1, 2, 3]))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        let realtime = try XCTUnwrap(json["realtimeInput"] as? [String: Any])
        let audio = try XCTUnwrap(realtime["audio"] as? [String: Any])
        XCTAssertEqual(audio["data"] as? String, "AQID")
        XCTAssertEqual(audio["mimeType"] as? String, "audio/pcm;rate=16000")
    }

    func testDecodesLifecycleAndTranscripts() {
        XCTAssertEqual(GeminiLiveEvent.decode(from: #"{"setupComplete":{}}"#), .setupComplete)
        XCTAssertEqual(GeminiLiveEvent.decode(from: #"{"serverContent":{"interimInputTranscription":{"text":"仮"}}}"#), .interimTranscript("仮"))
        XCTAssertEqual(GeminiLiveEvent.decode(from: #"{"serverContent":{"inputTranscription":{"text":"確定"}}}"#), .finalTranscript("確定"))
        XCTAssertEqual(GeminiLiveEvent.decode(from: #"{"serverContent":{"turnComplete":true}}"#), .turnComplete)
    }
}
