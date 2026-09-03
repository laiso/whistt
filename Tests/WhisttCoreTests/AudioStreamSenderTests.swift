import XCTest
@testable import WhisttCore

final class AudioStreamSenderTests: XCTestCase {
    /// Manual scheduler driven by the harness's virtual clock: no real-time waiting.
    private final class ManualScheduler: AudioSendScheduling {
        struct Entry {
            let fireTime: TimeInterval
            let block: () -> Void
        }

        var entries: [Entry] = []
        var clock: (() -> TimeInterval)!

        func schedule(after delay: TimeInterval, on queue: DispatchQueue, _ block: @escaping () -> Void) {
            entries.append(Entry(fireTime: clock() + delay, block: block))
        }

        func cancelAll() { entries.removeAll() }

        func fireDue() {
            while let index = entries.firstIndex(where: { $0.fireTime <= clock() }) {
                entries.remove(at: index).block()
            }
        }
    }

    /// Builds senders on a serial test queue with a virtual clock, records
    /// every send and the end-of-audio notification.
    private final class Harness {
        let queue = DispatchQueue(label: "test.audio.sender.q")
        private let manualScheduler = ManualScheduler()
        var time: TimeInterval = 0
        var scheduler: AudioSendScheduling { manualScheduler }

        private(set) var sent: [Data] = []
        private(set) var sendTimes: [TimeInterval] = []
        private(set) var events: [String] = []
        private(set) var endCount = 0
        private(set) var diagnostics: [String] = []

        var holdCompletion = false
        private var heldCompletions: [() -> Void] = []

        init() {
            manualScheduler.clock = { [weak self] in self?.time ?? 0 }
        }

        func makeSender(format: AudioStreamFormat, policy: AudioStreamingPolicy) -> AudioStreamSender {
            AudioStreamSender(
                queue: queue,
                format: format,
                policy: policy,
                now: { [weak self] in self?.time ?? 0 },
                scheduler: manualScheduler,
                send: { [weak self] data, completion in
                    guard let self else {
                        completion()
                        return
                    }
                    sent.append(data)
                    sendTimes.append(time)
                    events.append("audio\(sent.count - 1)")
                    if holdCompletion {
                        heldCompletions.append(completion)
                    } else {
                        completion()
                    }
                },
                onEndOfAudio: { [weak self] in
                    guard let self else { return }
                    endCount += 1
                    events.append("end")
                },
                onDiagnostic: { [weak self] message in
                    self?.diagnostics.append(message)
                }
            )
        }

        /// Drain the queue until quiescent: a send completion enqueued while a
        /// block runs can land after a single `sync{}` barrier would return.
        func flush() {
            while true {
                var sentCount = -1
                var ends = -1
                queue.sync {
                    sentCount = self.sent.count
                    ends = self.endCount
                }
                queue.sync {}
                if sentCount == sent.count && ends == endCount { break }
            }
        }

        func releaseHeldCompletion() {
            queue.sync {
                guard !heldCompletions.isEmpty else { return }
                heldCompletions.removeFirst()()
            }
            flush()
        }

        func advance(to newTime: TimeInterval) {
            time = newTime
            manualScheduler.fireDue()
            flush()
        }
    }

    private let metaFormat = AudioStreamFormat(sampleRate: 24_000, channelCount: 1, bytesPerSample: 2)
    private var metaFrameBytes: Int { metaFormat.frameByteCount(frameDuration: 0.08) }

    private func data(_ count: Int, seed: UInt8) -> Data {
        Data((0..<count).map { (seed &+ UInt8($0 % 251)) })
    }

    // 1. Irregular input sizes are re-framed into exact 3,840-byte frames.
    func testIrregularInputsReframedToMetaFrameSize() {
        let harness = Harness()
        let sender = harness.makeSender(
            format: metaFormat,
            policy: AudioStreamingPolicy(
                frameDuration: 0.08, pacing: .immediate,
                preReadyBufferLimit: 15, flushPartialFrameOnEnd: true
            )
        )
        sender.markReady()
        sender.enqueue(data(1000, seed: 1))
        sender.enqueue(data(5000, seed: 2))
        sender.enqueue(data(3839, seed: 3))
        sender.enqueue(data(8000, seed: 4))
        harness.flush()

        XCTAssertEqual(harness.sent.count, 4)
        XCTAssertTrue(harness.sent.allSatisfy { $0.count == metaFrameBytes })
        XCTAssertEqual(metaFrameBytes, 3840)

        sender.endInput()
        harness.flush()
        XCTAssertEqual(harness.sent.count, 5)
        XCTAssertEqual(harness.sent.last?.count, 17839 - 4 * 3840)
        XCTAssertEqual(harness.endCount, 1)
    }

    // 2. Byte order is preserved across input boundaries.
    func testByteOrderPreservedAcrossInputs() {
        let harness = Harness()
        let sender = harness.makeSender(
            format: metaFormat,
            policy: AudioStreamingPolicy(
                frameDuration: 0.08, pacing: .immediate,
                preReadyBufferLimit: 15, flushPartialFrameOnEnd: true
            )
        )
        sender.markReady()
        let inputs = [data(700, seed: 10), data(3840, seed: 40), data(3211, seed: 90)]
        inputs.forEach { sender.enqueue($0) }
        sender.endInput()
        harness.flush()

        let concatenated = Data(harness.sent.joined())
        XCTAssertEqual(concatenated, Data(inputs.joined()))
    }

    // 3. Nothing is sent before ready; FIFO order after ready.
    func testPreReadyBufferedThenSentFIFO() {
        let harness = Harness()
        let sender = harness.makeSender(format: metaFormat, policy: .passthrough())
        let chunks = [data(100, seed: 1), data(200, seed: 2), data(300, seed: 3)]
        chunks.forEach { sender.enqueue($0) }
        harness.flush()
        XCTAssertTrue(harness.sent.isEmpty)

        sender.markReady()
        harness.flush()
        XCTAssertEqual(harness.sent, chunks)
        XCTAssertEqual(harness.events, ["audio0", "audio1", "audio2"])
    }

    // 4. Meta realtime policy sends at 80 ms intervals on an absolute schedule.
    func testRealtimePacingSendsAt80msIntervals() {
        let harness = Harness()
        let sender = harness.makeSender(format: metaFormat, policy: .fixedFrame(frameDuration: 0.08))
        sender.enqueue(data(metaFrameBytes * 4, seed: 7))
        sender.markReady()
        harness.flush()

        XCTAssertEqual(harness.sendTimes, [0.0])

        harness.advance(to: 0.04)
        XCTAssertEqual(harness.sendTimes, [0.0])

        harness.advance(to: 0.08)
        XCTAssertEqual(harness.sendTimes, [0.0, 0.08])

        harness.advance(to: 0.16)
        XCTAssertEqual(harness.sendTimes, [0.0, 0.08, 0.16])

        harness.advance(to: 0.24)
        XCTAssertEqual(harness.sendTimes, [0.0, 0.08, 0.16, 0.24])
    }

    // A delayed timer must not make the sender burst missed slots back-to-back.
    func testRealtimePacingRebasesAfterDelay() {
        let harness = Harness()
        let sender = harness.makeSender(format: metaFormat, policy: .fixedFrame(frameDuration: 0.08))
        sender.enqueue(data(metaFrameBytes * 3, seed: 7))
        sender.markReady()
        harness.flush()

        XCTAssertEqual(harness.sendTimes, [0.0])

        // The 80 ms timer fires 120 ms late. Only one frame may be sent now;
        // the following frame gets a fresh 80 ms interval.
        harness.advance(to: 0.20)
        XCTAssertEqual(harness.sendTimes, [0.0, 0.20])

        harness.advance(to: 0.279)
        XCTAssertEqual(harness.sendTimes, [0.0, 0.20])

        harness.advance(to: 0.28)
        XCTAssertEqual(harness.sendTimes, [0.0, 0.20, 0.28])
    }

    // 5. No new send starts before the previous send completed.
    func testNextSendWaitsForCompletion() {
        let harness = Harness()
        harness.holdCompletion = true
        let sender = harness.makeSender(format: metaFormat, policy: .passthrough())
        sender.markReady()
        sender.enqueue(data(10, seed: 1))
        sender.enqueue(data(20, seed: 2))
        harness.flush()
        XCTAssertEqual(harness.sent.count, 1)

        harness.flush()
        XCTAssertEqual(harness.sent.count, 1, "second send must wait for completion")

        harness.releaseHeldCompletion()
        XCTAssertEqual(harness.sent.count, 2)
    }

    // 6. Trailing partial frame is flushed exactly once on end.
    func testPartialFlushedOnceOnEnd() {
        let harness = Harness()
        let sender = harness.makeSender(format: metaFormat, policy: .fixedFrame(frameDuration: 0.08))
        sender.markReady()
        sender.enqueue(data(metaFrameBytes + 1000, seed: 5))
        harness.flush()
        XCTAssertEqual(harness.sent.count, 1)

        sender.endInput()
        harness.flush()
        XCTAssertEqual(harness.sent.count, 2)
        XCTAssertEqual(harness.sent.last?.count, 1000)
        XCTAssertEqual(harness.endCount, 1)

        sender.endInput()
        harness.flush()
        XCTAssertEqual(harness.sent.count, 2, "partial must not be flushed twice")
        XCTAssertEqual(harness.endCount, 1)
    }

    // 7. End notification fires once, after the last send completion.
    func testEndNotifiedOnceAfterLastCompletion() {
        let harness = Harness()
        harness.holdCompletion = true
        let sender = harness.makeSender(format: metaFormat, policy: .passthrough())
        sender.markReady()
        sender.enqueue(data(10, seed: 1))
        sender.endInput()
        harness.flush()
        XCTAssertEqual(harness.endCount, 0, "end must wait for the in-flight send")

        harness.releaseHeldCompletion()
        XCTAssertEqual(harness.events, ["audio0", "end"])
        XCTAssertEqual(harness.endCount, 1)

        sender.endInput()
        harness.flush()
        XCTAssertEqual(harness.endCount, 1)
    }

    // 8. End before ready still produces audio...audio -> end order after ready.
    func testEndBeforeReadyDefersEndMessage() {
        let harness = Harness()
        let sender = harness.makeSender(format: metaFormat, policy: .passthrough())
        sender.enqueue(data(10, seed: 1))
        sender.enqueue(data(20, seed: 2))
        sender.endInput()
        harness.flush()
        XCTAssertTrue(harness.sent.isEmpty)
        XCTAssertEqual(harness.endCount, 0)

        sender.markReady()
        harness.flush()
        XCTAssertEqual(harness.events, ["audio0", "audio1", "end"])
        XCTAssertEqual(harness.endCount, 1)
    }

    // 9. After reset, scheduled sends do not run.
    func testResetCancelsScheduledSends() {
        let harness = Harness()
        let sender = harness.makeSender(format: metaFormat, policy: .fixedFrame(frameDuration: 0.08))
        sender.enqueue(data(metaFrameBytes * 8, seed: 3))
        sender.markReady()
        harness.flush()
        harness.advance(to: 0.08)
        XCTAssertEqual(harness.sent.count, 2)

        sender.reset()
        harness.flush()
        harness.advance(to: 1.0)
        XCTAssertEqual(harness.sent.count, 2, "no sends after reset")
        XCTAssertEqual(harness.endCount, 0)
    }

    // 10. A fresh session sender carries no data from a reset sender.
    func testNewSessionSenderIsIsolated() {
        let harness = Harness()
        let first = harness.makeSender(format: metaFormat, policy: .passthrough())
        first.enqueue(data(100, seed: 1))
        first.reset()
        harness.flush()

        let second = harness.makeSender(format: metaFormat, policy: .passthrough())
        second.markReady()
        harness.flush()
        XCTAssertTrue(harness.sent.isEmpty, "reset sender's audio must not leak into a new session")

        second.enqueue(data(50, seed: 9))
        harness.flush()
        XCTAssertEqual(harness.sent, [data(50, seed: 9)])
    }

    // 11. Passthrough policy keeps current immediate, unreframed behavior.
    func testPassthroughPolicySendsImmediatelyUnreframed() {
        let harness = Harness()
        let sender = harness.makeSender(format: metaFormat, policy: .passthrough())
        sender.markReady()
        let first = data(1000, seed: 1)
        let second = data(50, seed: 2)
        sender.enqueue(first)
        harness.flush()
        XCTAssertEqual(harness.sendTimes, [0.0])
        sender.enqueue(second)
        harness.flush()
        XCTAssertEqual(harness.sendTimes, [0.0, 0.0])
        XCTAssertEqual(harness.sent, [first, second])
    }

    // 12. Pre-ready buffer is capped; memory does not grow past the limit.
    func testPreReadyBufferLimitEnforcedWithDiagnostic() {
        let harness = Harness()
        // 24 kHz * 2 bytes * 0.01 s = 480 bytes.
        let sender = harness.makeSender(format: metaFormat, policy: .passthrough(preReadyBufferLimit: 0.01))
        sender.enqueue(data(1000, seed: 1))
        harness.flush()
        sender.enqueue(data(1000, seed: 2))
        harness.flush()
        XCTAssertEqual(harness.diagnostics.count, 1, "overflow reported once")

        sender.markReady()
        harness.flush()
        XCTAssertEqual(harness.sent.count, 1)
        XCTAssertEqual(harness.sent.first?.count, 480)
    }

    // Frame size is derived from the audio format, not hardcoded.
    func testFrameByteCountDerivedFromFormat() {
        XCTAssertEqual(AudioStreamFormat(sampleRate: 24_000, channelCount: 1, bytesPerSample: 2)
            .frameByteCount(frameDuration: 0.08), 3840)
        XCTAssertEqual(AudioStreamFormat(sampleRate: 16_000, channelCount: 1, bytesPerSample: 2)
            .frameByteCount(frameDuration: 0.08), 2560)
        XCTAssertEqual(AudioStreamFormat(sampleRate: 24_000, channelCount: 1, bytesPerSample: 2)
            .bytesPerSecond, 48_000)
    }
}
