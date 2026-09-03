import Foundation

/// Byte layout of the PCM stream handed to `AudioStreamSender`.
///
/// The sender derives every size (frame bytes, pre-ready buffer limit) from
/// this format instead of hardcoding provider-specific byte counts.
public struct AudioStreamFormat {
    public let sampleRate: Double
    public let channelCount: Int
    public let bytesPerSample: Int

    public init(sampleRate: Double, channelCount: Int, bytesPerSample: Int) {
        self.sampleRate = sampleRate
        self.channelCount = channelCount
        self.bytesPerSample = bytesPerSample
    }

    public var bytesPerSecond: Int {
        Int((sampleRate * Double(channelCount * bytesPerSample)).rounded())
    }

    /// Fixed frame size in bytes for the given duration, computed as an exact
    /// integer sample count so rounding never becomes ambiguous.
    /// Meta (24 kHz PCM16 mono, 80 ms): 24_000 * 0.08 = 1_920 samples -> 3_840 bytes.
    public func frameByteCount(frameDuration: TimeInterval) -> Int {
        let samplesPerFrame = Int((sampleRate * frameDuration).rounded())
        return samplesPerFrame * channelCount * bytesPerSample
    }
}

public enum AudioPacing: Equatable {
    /// Send as soon as the previous send completed.
    case immediate
    /// Send at most one frame per `frameDuration`, aligned to an absolute
    /// schedule (not accumulated sleeps) so pacing does not drift.
    case realtime
}

public struct AudioStreamingPolicy {
    public let frameDuration: TimeInterval?
    public let pacing: AudioPacing
    public let preReadyBufferLimit: TimeInterval
    public let flushPartialFrameOnEnd: Bool

    public init(
        frameDuration: TimeInterval?,
        pacing: AudioPacing,
        preReadyBufferLimit: TimeInterval,
        flushPartialFrameOnEnd: Bool
    ) {
        self.frameDuration = frameDuration
        self.pacing = pacing
        self.preReadyBufferLimit = preReadyBufferLimit
        self.flushPartialFrameOnEnd = flushPartialFrameOnEnd
    }

    /// Passthrough: no reframing, sends as fast as the transport allows.
    public static func passthrough(preReadyBufferLimit: TimeInterval = 15) -> AudioStreamingPolicy {
        AudioStreamingPolicy(
            frameDuration: nil,
            pacing: .immediate,
            preReadyBufferLimit: preReadyBufferLimit,
            flushPartialFrameOnEnd: false
        )
    }

    /// Realtime-paced fixed-frame policy (e.g. Meta: 80 ms frames).
    public static func fixedFrame(
        frameDuration: TimeInterval,
        preReadyBufferLimit: TimeInterval = 15,
        flushPartialFrameOnEnd: Bool = true
    ) -> AudioStreamingPolicy {
        AudioStreamingPolicy(
            frameDuration: frameDuration,
            pacing: .realtime,
            preReadyBufferLimit: preReadyBufferLimit,
            flushPartialFrameOnEnd: flushPartialFrameOnEnd
        )
    }
}

/// Injectable scheduler so tests can drive pacing without real time waiting.
public protocol AudioSendScheduling: AnyObject {
    /// Invoke `block` on `queue` after `delay` seconds (measured by the
    /// sender's injected clock in tests).
    func schedule(after delay: TimeInterval, on queue: DispatchQueue, _ block: @escaping () -> Void)
    func cancelAll()
}

/// Production scheduler backed by `DispatchSourceTimer`s on the target queue.
public final class DispatchAudioSendScheduler: AudioSendScheduling {
    private let lock = NSLock()
    private var timers: [DispatchSourceTimer] = []

    public init() {}

    public func schedule(after delay: TimeInterval, on queue: DispatchQueue, _ block: @escaping () -> Void) {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + delay)
        timer.setEventHandler { [weak self] in
            block()
            guard let self else { return }
            self.lock.lock()
            self.timers.removeAll { $0 === timer }
            self.lock.unlock()
        }
        timer.resume()
        lock.lock()
        timers.append(timer)
        lock.unlock()
    }

    public func cancelAll() {
        lock.lock()
        let all = timers
        timers.removeAll()
        lock.unlock()
        all.forEach { $0.cancel() }
    }
}

/// Shared PCM streaming control layer between audio conversion and the
/// provider-specific transports.
///
/// Responsibilities: accumulate arbitrarily sized PCM input, split it into
/// fixed frames derived from the audio format, preserve FIFO order, hold
/// audio until the connection is ready, pace sends, serialize sends (at most
/// one WebSocket send in flight), flush a trailing partial frame on end, and
/// notify once after the audio queue and in-flight send have drained.
///
/// All mutable state is confined to the queue passed at init; transports are
/// expected to pass their own dedicated serial queue so the send handler and
/// end-of-audio callback can safely touch transport state.
public final class AudioStreamSender {
    public typealias SendHandler = (Data, @escaping () -> Void) -> Void

    private let queue: DispatchQueue
    private let format: AudioStreamFormat
    private let policy: AudioStreamingPolicy
    private let now: () -> TimeInterval
    private let scheduler: AudioSendScheduling
    private let send: SendHandler
    private let onEndOfAudio: (() -> Void)?
    private let onDiagnostic: ((String) -> Void)?

    private let frameBytes: Int?
    private let preReadyLimitBytes: Int

    // Guarded by `queue`.
    private var ready = false
    private var ended = false
    private var closed = false
    private var pending: [Data] = []
    private var frameBuffer = Data()
    private var preReadyChunks: [Data] = []
    private var preReadyBufferedBytes = 0
    private var overflowReported = false
    private var sendInFlight = false
    private var endNotified = false
    private var pumpScheduled = false
    private var nextDue: TimeInterval?

    public init(
        queue: DispatchQueue,
        format: AudioStreamFormat,
        policy: AudioStreamingPolicy,
        now: @escaping () -> TimeInterval = { Date().timeIntervalSinceReferenceDate },
        scheduler: AudioSendScheduling = DispatchAudioSendScheduler(),
        send: @escaping SendHandler,
        onEndOfAudio: (() -> Void)? = nil,
        onDiagnostic: ((String) -> Void)? = nil
    ) {
        self.queue = queue
        self.format = format
        self.policy = policy
        self.now = now
        self.scheduler = scheduler
        self.send = send
        self.onEndOfAudio = onEndOfAudio
        self.onDiagnostic = onDiagnostic
        frameBytes = policy.frameDuration.map { format.frameByteCount(frameDuration: $0) }
        preReadyLimitBytes = max(1, Int((Double(format.bytesPerSecond) * policy.preReadyBufferLimit).rounded()))
    }

    /// Accept PCM audio from any thread. Audio arriving before `markReady()`
    /// is buffered (bounded by `preReadyBufferLimit`).
    public func enqueue(_ data: Data) {
        queue.async { [weak self] in self?._enqueue(data) }
    }

    /// Signal that the connection is ready to carry audio.
    public func markReady() {
        queue.async { [weak self] in self?._markReady() }
    }

    /// Signal that recording ended. Safe to call before `markReady()`;
    /// end-of-audio handling is deferred until the buffered audio drains.
    public func endInput() {
        queue.async { [weak self] in self?._endInput() }
    }

    /// Drop all state (close/error/new session). The sender is single-use
    /// after reset; transports create a fresh sender per session.
    public func reset() {
        queue.async { [weak self] in self?._reset() }
    }

    // MARK: - Private (all on `queue`)

    private func _enqueue(_ data: Data) {
        guard !closed, !data.isEmpty else { return }
        if !ready {
            appendPreReady(data)
            return
        }
        ingest(data)
        pump()
    }

    /// Pre-ready audio keeps its chunk boundaries so passthrough transports
    /// replay exactly what was enqueued; memory is capped at
    /// `preReadyBufferLimit` by dropping the newest bytes first.
    private func appendPreReady(_ data: Data) {
        let room = preReadyLimitBytes - preReadyBufferedBytes
        if room <= 0 {
            if !overflowReported {
                overflowReported = true
                onDiagnostic?(
                    "pre-ready buffer limit exceeded (\(policy.preReadyBufferLimit)s); "
                        + "dropped \(data.count) bytes of newest audio"
                )
            }
            return
        }
        if data.count > room {
            preReadyChunks.append(data.prefix(room))
            preReadyBufferedBytes += room
            if !overflowReported {
                overflowReported = true
                onDiagnostic?(
                    "pre-ready buffer limit exceeded (\(policy.preReadyBufferLimit)s); "
                        + "dropped \(data.count - room) bytes of newest audio"
                )
            }
            return
        }
        preReadyChunks.append(data)
        preReadyBufferedBytes += data.count
    }

    private func _markReady() {
        guard !closed, !ready else { return }
        ready = true
        if policy.pacing == .realtime { nextDue = now() }
        if !preReadyChunks.isEmpty {
            let chunks = preReadyChunks
            preReadyChunks.removeAll(keepingCapacity: false)
            preReadyBufferedBytes = 0
            chunks.forEach { ingest($0) }
        }
        pump()
    }

    private func _endInput() {
        guard !closed else { return }
        ended = true
        pump()
    }

    private func _reset() {
        guard !closed else { return }
        closed = true
        scheduler.cancelAll()
        pending.removeAll(keepingCapacity: false)
        frameBuffer.removeAll(keepingCapacity: false)
        preReadyChunks.removeAll(keepingCapacity: false)
        preReadyBufferedBytes = 0
        sendInFlight = false
        nextDue = nil
    }

    /// Split input PCM into fixed frames, preserving byte order across
    /// arbitrary input boundaries.
    private func ingest(_ data: Data) {
        guard let frameBytes else {
            pending.append(data)
            return
        }
        frameBuffer.append(data)
        while frameBuffer.count >= frameBytes {
            pending.append(frameBuffer.prefix(frameBytes))
            frameBuffer.removeFirst(frameBytes)
        }
    }

    private func pump() {
        guard !closed, ready, !sendInFlight else { return }

        if !pending.isEmpty {
            if policy.pacing == .realtime, let due = nextDue {
                let current = now()
                if current + 1e-9 < due {
                    schedulePump(after: due - current)
                    return
                }
            }
            let chunk = pending.removeFirst()
            sendInFlight = true
            if policy.pacing == .realtime {
                // Base the next slot on the actual send time. If a timer or
                // completion arrives late, advancing from the old scheduled
                // time would leave `nextDue` in the past and burst queued
                // frames back-to-back while trying to catch up.
                nextDue = now() + (policy.frameDuration ?? 0)
            }
            send(chunk) { [weak self] in self?._onSendCompleted() }
            return
        }

        guard ended else { return }
        if policy.flushPartialFrameOnEnd, frameBytes != nil, !frameBuffer.isEmpty {
            let partial = frameBuffer
            frameBuffer.removeAll(keepingCapacity: false)
            sendInFlight = true
            send(partial) { [weak self] in self?._onSendCompleted() }
            return
        }
        if !endNotified {
            endNotified = true
            onEndOfAudio?()
        }
    }

    private func _onSendCompleted() {
        queue.async { [weak self] in
            guard let self, !self.closed else { return }
            self.sendInFlight = false
            self.pump()
        }
    }

    private func schedulePump(after delay: TimeInterval) {
        guard !pumpScheduled else { return }
        pumpScheduled = true
        scheduler.schedule(after: delay, on: queue) { [weak self] in
            guard let self else { return }
            self.queue.async {
                self.pumpScheduled = false
                self.pump()
            }
        }
    }
}
