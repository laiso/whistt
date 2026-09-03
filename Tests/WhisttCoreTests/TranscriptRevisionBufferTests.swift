import XCTest
@testable import WhisttCore

final class TranscriptRevisionBufferTests: XCTestCase {
    func testAppendSafeSuffixIsTypedDirectly() {
        let buffer = TranscriptRevisionBuffer()
        let ops = buffer.apply(TranscriptRevision(
            confirmedText: "Hello", interimText: "", appendSafeSuffix: "Hello"
        ))
        XCTAssertEqual(ops, [.type("Hello")])
        XCTAssertEqual(buffer.typedConfirmedCount, 5)
        XCTAssertEqual(buffer.typedInterim, "")
    }

    func testInterimSnapshotTypesAndErasesOnRevision() {
        let buffer = TranscriptRevisionBuffer()
        XCTAssertEqual(
            buffer.apply(TranscriptRevision(confirmedText: "", interimText: "こんにち")),
            [.type("こんにち")]
        )
        // Hypothesis revised itself: previous interim must be erased and retyped.
        XCTAssertEqual(
            buffer.apply(TranscriptRevision(confirmedText: "", interimText: "こんにちは")),
            [.erase(count: 4), .type("こんにちは")]
        )
        XCTAssertEqual(buffer.typedInterim, "こんにちは")
    }

    func testChunkFinalErasesInterimThenTypesConfirmedSuffix() {
        let buffer = TranscriptRevisionBuffer()
        _ = buffer.apply(TranscriptRevision(confirmedText: "", interimText: "おはようご"))
        // Chunk locked while an interim was still at the cursor.
        let ops = buffer.apply(TranscriptRevision(
            confirmedText: "おはようございます", interimText: "", appendSafeSuffix: "おはようございます"
        ))
        XCTAssertEqual(ops, [.erase(count: 5), .type("おはようございます")])
        XCTAssertEqual(buffer.typedConfirmedCount, 9)
        XCTAssertEqual(buffer.typedInterim, "")
    }

    func testConfirmedGrowthAfterInterimErasesInterimFirst() {
        let buffer = TranscriptRevisionBuffer()
        _ = buffer.apply(TranscriptRevision(confirmedText: "Hello", interimText: "wor"))
        // Confirmed text grows while an interim sits after it on the cursor.
        let ops = buffer.apply(TranscriptRevision(confirmedText: "Hello world,", interimText: "agai"))
        XCTAssertEqual(ops, [.erase(count: 3), .type(" world,"), .type("agai")])
    }

    func testFinalDropsTypedInterimAndTypesRemainder() {
        let buffer = TranscriptRevisionBuffer()
        _ = buffer.apply(TranscriptRevision(confirmedText: "Hello", interimText: "wo"))
        let ops = buffer.applyFinal("Hello world")
        XCTAssertEqual(ops, [.erase(count: 2), .type(" world")])
        XCTAssertEqual(buffer.typedConfirmedCount, 11)
    }

    func testFinalRetypesEverythingWhenItDeviatesFromConfirmedText() {
        let buffer = TranscriptRevisionBuffer()
        _ = buffer.apply(TranscriptRevision(confirmedText: "abc", interimText: "de"))
        let ops = buffer.applyFinal("xy")
        XCTAssertEqual(ops, [.erase(count: 2), .erase(count: 3), .type("xy")])
    }

    func testResetDropsTrackingState() {
        let buffer = TranscriptRevisionBuffer()
        _ = buffer.apply(TranscriptRevision(confirmedText: "", interimText: "仮"))
        buffer.reset()
        XCTAssertEqual(buffer.typedConfirmedCount, 0)
        XCTAssertEqual(buffer.typedInterim, "")
    }
}
