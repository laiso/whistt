import XCTest
@testable import WhisttCore

final class FinalTranscriptOutputGateTests: XCTestCase {
    func testInterimAndLifecycleEventsNeverProduceOutput() {
        var gate = FinalTranscriptOutputGate()
        let events: [TranscriptionTransportEvent] = [
            .ready,
            .speechStarted,
            .partial(text: "partial", replacesPrevious: false),
            .partial(text: "replacement", replacesPrevious: true),
            .revision(TranscriptRevision(confirmedText: "confirmed", interimText: "interim")),
            .turnComplete,
            .unknown("diagnostic.event"),
        ]

        XCTAssertTrue(events.allSatisfy { gate.consume($0) == nil })
    }

    func testFinalProducesOutputExactlyOnce() {
        var gate = FinalTranscriptOutputGate()

        XCTAssertEqual(gate.consume(.final("hello")), "hello")
        XCTAssertNil(gate.consume(.final("hello")))
    }

    func testDeltaFollowedBySameFinalProducesOnlyFinalOutput() {
        var gate = FinalTranscriptOutputGate()

        XCTAssertNil(gate.consume(.partial(text: "hello", replacesPrevious: false)))
        XCTAssertEqual(gate.consume(.final("hello")), "hello")
        XCTAssertNil(gate.consume(.final("hello")))
    }

    func testDifferentFinalTranscriptsCanBeDelivered() {
        var gate = FinalTranscriptOutputGate()

        XCTAssertEqual(gate.consume(.final("first")), "first")
        XCTAssertEqual(gate.consume(.final("second")), "second")
    }

    func testResetAllowsSameTranscriptInNextCapture() {
        var gate = FinalTranscriptOutputGate()
        XCTAssertEqual(gate.consume(.final("same")), "same")

        gate.reset()

        XCTAssertEqual(gate.consume(.final("same")), "same")
    }
}
