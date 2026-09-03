import Foundation

/// Schedules the modifier-only hold threshold. Abstractions exist so tests can
/// fire the timer deterministically without waiting for real time.
public protocol ShortcutTimerScheduling: AnyObject {
    func scheduleHoldTimer(after: TimeInterval, handler: @escaping () -> Void)
    func cancelHoldTimer()
}

/// Dispatch-based production scheduler. The engine is confined to one serial
/// queue; schedule hold timers on that same queue.
public final class DispatchShortcutTimerScheduler: ShortcutTimerScheduling {
    private let queue: DispatchQueue
    private var timer: DispatchSourceTimer?

    public init(queue: DispatchQueue = .main) {
        self.queue = queue
    }

    public func scheduleHoldTimer(after: TimeInterval, handler: @escaping () -> Void) {
        cancelHoldTimer()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + after)
        timer.setEventHandler(handler: handler)
        timer.resume()
        self.timer = timer
    }

    public func cancelHoldTimer() {
        timer?.cancel()
        timer = nil
    }
}

/// Interprets raw keyboard events against a `ShortcutBinding` and decides when
/// to start, stop, or cancel push-to-talk. All methods must be called on one
/// serial queue (the event tap's run loop queue in production).
///
/// For a `.chord` binding this preserves the classic press-to-start /
/// release-to-stop behavior, swallowing the matched key-down/key-up pair.
/// For a `.modifierOnly` binding a bare modifier held for the hold threshold
/// starts recording; any other key or mouse press while armed cancels the
/// gesture, and a press while recording cancels and discards the capture.
/// Modifier-only events are never swallowed.
public final class ShortcutEngine {
    public enum State: Equatable {
        case idle
        case armed
        case recording
    }

    public let holdThreshold: TimeInterval
    public var onStart: (() -> Void)?
    public var onStop: (() -> Void)?
    /// Cancel of an active (or armed) gesture: stop capture and discard any
    /// transcript belonging to it.
    public var onDiscard: (() -> Void)?
    public var onDiagnostic: ((String) -> Void)?
    public private(set) var state: State = .idle

    private let timers: ShortcutTimerScheduling
    public private(set) var binding: ShortcutBinding
    // Guards the hold timer: a stale fire must not start a later recording.
    private var attempt = 0
    // Chord bookkeeping: the key-down was swallowed and its key-up must remain
    // swallowed even when releasing a modifier already stopped recording.
    private var chordKeyUpPending = false
    // Modifier flags aggregate left and right variants. Track the configured
    // physical key's transitions separately so releasing Left Control while
    // Right Control remains held is still recognized as a release.
    private var boundModifierKeyDown = false

    public init(
        binding: ShortcutBinding,
        holdThreshold: TimeInterval = 0.2,
        timers: ShortcutTimerScheduling = DispatchShortcutTimerScheduler()
    ) {
        self.binding = binding
        self.holdThreshold = holdThreshold
        self.timers = timers
    }

    public func updateBinding(_ newBinding: ShortcutBinding) {
        guard newBinding != binding else { return }
        cancelGesture(reason: "binding change")
        chordKeyUpPending = false
        boundModifierKeyDown = false
        binding = newBinding
    }

    /// A flagsChanged event for a modifier key. `flags` is the full modifier
    /// state after the transition. Events pass through; the return value is
    /// always false.
    @discardableResult
    public func modifierChanged(keyCode: Int64, flags: UInt64) -> Bool {
        switch binding {
        case .chord(_, let required):
            // Preserve chord behavior: releasing the required modifiers while
            // the push-to-talk key is still down stops the recording.
            let nowHeld = flags & required == required
            if chordKeyUpPending && !nowHeld {
                if state == .recording {
                    state = .idle
                    onStop?()
                }
            }
        case .modifierOnly(let boundKeyCode, let boundModifier):
            guard keyCode == boundKeyCode,
                  let flag = ShortcutBinding.modifierFlag(forKeyCode: keyCode),
                  flag == boundModifier else { return false }
            // A flagsChanged event for the bound key is a transition of that
            // key. Do not infer release solely from the aggregate flag because
            // the opposite-side modifier may keep it set.
            let isDown: Bool
            if boundModifierKeyDown {
                isDown = false
                boundModifierKeyDown = false
            } else {
                // Ignore an unmatched up event (for example immediately after
                // changing bindings while the new key was already held).
                guard flags & boundModifier != 0 else { return false }
                isDown = true
                boundModifierKeyDown = true
            }
            if isDown {
                if state == .idle {
                    state = .armed
                    attempt += 1
                    let capturedAttempt = attempt
                    timers.scheduleHoldTimer(after: holdThreshold) { [weak self] in
                        self?.holdTimerFired(attempt: capturedAttempt)
                    }
                }
            } else {
                switch state {
                case .recording:
                    state = .idle
                    onStop?()
                case .armed:
                    cancelHoldTimer()
                    state = .idle
                case .idle:
                    break
                }
            }
        }
        return false
    }

    /// A keyboard key-down. Returns true when the event must be swallowed.
    public func keyDown(keyCode: Int64, flags: UInt64) -> Bool {
        switch binding {
        case .chord(let boundKeyCode, let required):
            guard keyCode == boundKeyCode,
                  required != 0,
                  flags & required == required else { return false }
            if !chordKeyUpPending {
                chordKeyUpPending = true
                state = .recording
                onStart?()
            }
            return true
        case .modifierOnly:
            switch state {
            case .armed:
                // Another key interrupts the hold: cancel and pass through so
                // chords like Control-C keep working.
                cancelGesture(reason: "key pressed while armed")
            case .recording:
                cancelGesture(reason: "key pressed while recording")
            case .idle:
                break
            }
            return false
        }
    }

    /// A keyboard key-up. Returns true when the event must be swallowed to
    /// match a previously swallowed key-down.
    public func keyUp(keyCode: Int64, flags: UInt64) -> Bool {
        switch binding {
        case .chord(let boundKeyCode, _):
            guard keyCode == boundKeyCode, chordKeyUpPending else { return false }
            chordKeyUpPending = false
            if state == .recording {
                state = .idle
                onStop?()
            }
            return true
        case .modifierOnly:
            return false
        }
    }

    /// Any mouse button down while a modifier-only gesture is armed or active.
    /// Movement and scrolling never reach this. Chord recordings are unaffected.
    public func mouseDown() {
        guard binding.isModifierOnly else { return }
        switch state {
        case .armed, .recording:
            cancelGesture(reason: "mouse pressed")
        case .idle:
            break
        }
    }

    /// The event tap was disabled (timeout or user input). Cancels any active
    /// modifier-only gesture exactly once; chord state is cleared too.
    public func tapDisabled() {
        cancelGesture(reason: "event tap disabled")
        chordKeyUpPending = false
        boundModifierKeyDown = false
    }

    /// Application shutdown.
    public func shutdown() {
        cancelGesture(reason: "app shutdown")
        chordKeyUpPending = false
        boundModifierKeyDown = false
    }

    private func holdTimerFired(attempt firedAttempt: Int) {
        guard state == .armed, firedAttempt == attempt else { return }
        state = .recording
        onStart?()
    }

    /// Cancels an armed or active gesture: discard the capture, emit at most
    /// once. A merely-armed hold never started recording, so nothing needs
    /// discarding — only the timer is cancelled.
    private func cancelGesture(reason: String) {
        cancelHoldTimer()
        let wasRecording = state == .recording
        state = .idle
        if wasRecording {
            onDiscard?()
            onDiagnostic?("shortcut gesture cancelled (\(reason)); capture discarded")
        }
    }

    private func cancelHoldTimer() {
        attempt += 1
        timers.cancelHoldTimer()
    }
}
