import XCTest
@testable import WhisttCore

final class TranscriptionModelCatalogTests: XCTestCase {
    func testSupportedModelsAndOrderMatchSpecification() {
        XCTAssertEqual(TranscriptionModelCatalog.models, [
            "gpt-transcribe",
            "gpt-live-transcribe",
            "gemini-3.5-transcribe-live",
            "muse-voice-transcribe-1.0",
            "xai-streaming-stt",
            "mai-transcribe-2",
        ])
        XCTAssertFalse(TranscriptionModelCatalog.models.contains("gpt-realtime-whisper"))
    }

    func testDefaultModelIsGPTTranscribe() {
        XCTAssertEqual(TranscriptionModelCatalog.defaultModel, "gpt-transcribe")
    }

    func testOpenAIModelsAreGroupedUnderOneVendor() {
        XCTAssertEqual(
            TranscriptionModelCatalog.models(for: .openAI),
            ["gpt-transcribe", "gpt-live-transcribe"]
        )
        XCTAssertEqual(
            TranscriptionModelCatalog.group(containing: "gpt-live-transcribe")?.vendor,
            "OpenAI"
        )
    }

    func testEverySupportedModelHasAReferencePrice() {
        XCTAssertEqual(
            Set(TranscriptionModelCatalog.referencePricePerHour.keys),
            Set(TranscriptionModelCatalog.models)
        )
    }

    func testDisplayNameIncludesVendorModelAndPrice() {
        XCTAssertEqual(
            TranscriptionModelCatalog.displayName(for: "gpt-live-transcribe", vendor: "OpenAI"),
            "OpenAI · gpt-live-transcribe · $1.02/hour"
        )
    }

    func testDisplayNameOmitsPriceWhenModelIsUnknown() {
        XCTAssertEqual(
            TranscriptionModelCatalog.displayName(for: "future-model", vendor: "Vendor"),
            "Vendor · future-model"
        )
    }

    func testResolveKeepsSupportedPreference() {
        XCTAssertEqual(
            TranscriptionModelCatalog.resolve(preferred: "gpt-live-transcribe"),
            "gpt-live-transcribe"
        )
    }

    func testResolveFallsBackForMissingOrStalePreference() {
        XCTAssertEqual(TranscriptionModelCatalog.resolve(preferred: nil), "gpt-transcribe")
        XCTAssertEqual(
            TranscriptionModelCatalog.resolve(preferred: "gpt-realtime-whisper"),
            "gpt-transcribe"
        )
    }
}
