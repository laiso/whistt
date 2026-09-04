import XCTest
@testable import WhisttCore

final class ShortcutEngineTests: XCTestCase {
    // Deterministic timer: entries record their fire time; `fireDue` runs the
    // handlers whose deadline has passed on the virtual clock.
    private final class ManualScheduler: ShortcutTimerScheduling {
        struct Entry {
            let fireTime: TimeInterval
            let handler: () -> Void
        }

        private(set) var entries: [Entry] = []

        func scheduleHoldTimer(after: TimeInterval, handler: @escaping () -> Void) {
            entries.append(Entry(fireTime: after, handler: handler))
        }

        func cancelHoldTimer() {
            entries.removeAll()
        }

        func fireAfter(_ delay: TimeInterval) {
            let due = entries.filter { $0.fireTime <= delay }
            entries.removeAll { $0.fireTime <= delay }
            due.forEach { $0.handler() }
        }
    }

    private final class Harness {
        let engine: ShortcutEngine
        let scheduler: ManualScheduler
        var state: ShortcutEngine.State { engine.state }
        private(set) var starts = 0
        private(set) var stops = 0
        private(set) var discards = 0

        init(binding: ShortcutBinding) {
            scheduler = ManualScheduler()
            engine = ShortcutEngine(binding: binding, holdThreshold: 0.2, timers: scheduler)
            engine.onStart = { self.starts += 1 }
            engine.onStop = { self.stops += 1 }
            engine.onDiscard = { self.discards += 1 }
        }

        func modifierDown(_ binding: ShortcutBinding) {
            _ = engine.modifierChanged(keyCode: binding.keyCode, flags: binding.modifierFlags)
        }

        func modifierUp(_ binding: ShortcutBinding) {
            _ = engine.modifierChanged(keyCode: binding.keyCode, flags: 0)
        }
    }

    private let leftControl = ShortcutBinding.modifierOnly(keyCode: 59, modifier: CGEventFlags.maskControl.rawValue)
    private let rightControl = ShortcutBinding.modifierOnly(keyCode: 62, modifier: CGEventFlags.maskControl.rawValue)
    private let chord = ShortcutBinding.chord(keyCode: 8, modifiers: CGEventFlags.maskControl.rawValue)

    // MARK: - Modifier-only

    func testShortHoldDoesNotStartRecording() {
        let h = Harness(binding: leftControl)
        h.modifierDown(leftControl)
        _ = h.engine.keyDown(keyCode: 0, flags: 0) // other key under threshold
        h.modifierUp(leftControl)
        XCTAssertEqual(h.starts, 0)
        XCTAssertEqual(h.state, .idle)
    }

    func testHoldThresholdStartsOnceAndReleaseStopsOnce() {
        let h = Harness(binding: leftControl)
        h.modifierDown(leftControl)
        h.scheduler.fireAfter(0.2)
        XCTAssertEqual(h.starts, 1)
        h.scheduler.fireAfter(0.4) // stale/extra fires must not retrigger
        XCTAssertEqual(h.starts, 1)
        h.modifierUp(leftControl)
        XCTAssertEqual(h.stops, 1)
        h.modifierUp(leftControl)
        XCTAssertEqual(h.stops, 1)
        XCTAssertEqual(h.state, .idle)
    }

    func testOtherKeyWhileArmedCancelsAndPassesThrough() {
        let h = Harness(binding: leftControl)
        h.modifierDown(leftControl)
        let swallowed = h.engine.keyDown(keyCode: 8, flags: CGEventFlags.maskControl.rawValue)
        XCTAssertFalse(swallowed)
        h.modifierUp(leftControl)
        XCTAssertEqual(h.starts, 0)
        XCTAssertEqual(h.state, .idle)
        // The chord still reached the app: firing the stale timer must not start.
        h.scheduler.fireAfter(0.2)
        XCTAssertEqual(h.starts, 0)
    }

    func testOtherKeyWhileRecordingCancelsAndDiscards() {
        let h = Harness(binding: leftControl)
        h.modifierDown(leftControl)
        h.scheduler.fireAfter(0.2)
        _ = h.engine.keyDown(keyCode: 8, flags: CGEventFlags.maskControl.rawValue)
        XCTAssertEqual(h.discards, 1)
        XCTAssertEqual(h.state, .idle)
        h.modifierUp(leftControl)
        XCTAssertEqual(h.stops, 0) // already cancelled; stop not emitted again
        XCTAssertEqual(h.discards, 1)
    }

    func testLeftAndRightControlAreDistinct() {
        let h = Harness(binding: leftControl)
        h.modifierDown(rightControl)
        h.scheduler.fireAfter(0.2)
        XCTAssertEqual(h.starts, 0) // right Control must not trigger a left Control binding
        h.modifierUp(rightControl)
        XCTAssertEqual(h.discards, 0)
    }

    func testBoundControlReleaseStopsWhileOppositeControlRemainsHeld() {
        let h = Harness(binding: leftControl)
        h.modifierDown(leftControl)
        // Right Control changes the aggregate flags but is not the bound key.
        _ = h.engine.modifierChanged(
            keyCode: rightControl.keyCode,
            flags: CGEventFlags.maskControl.rawValue
        )
        h.scheduler.fireAfter(0.2)
        XCTAssertEqual(h.starts, 1)

        // Releasing Left Control still leaves maskControl set because Right
        // Control remains down. The physical key transition must win.
        _ = h.engine.modifierChanged(
            keyCode: leftControl.keyCode,
            flags: CGEventFlags.maskControl.rawValue
        )
        XCTAssertEqual(h.stops, 1)
        XCTAssertEqual(h.state, .idle)
    }

    func testBoundControlReleaseCancelsArmedHoldWhileOppositeRemainsHeld() {
        let h = Harness(binding: leftControl)
        h.modifierDown(leftControl)
        _ = h.engine.modifierChanged(
            keyCode: rightControl.keyCode,
            flags: CGEventFlags.maskControl.rawValue
        )
        _ = h.engine.modifierChanged(
            keyCode: leftControl.keyCode,
            flags: CGEventFlags.maskControl.rawValue
        )
        h.scheduler.fireAfter(0.2)
        XCTAssertEqual(h.starts, 0)
        XCTAssertEqual(h.state, .idle)
    }

    func testRemappedCapsLockArrivingAsControlMatches() {
        // Karabiner-style remap: the physical Caps Lock key (57) arrives as a
        // Control modifier event with Control's key code (59).
        let h = Harness(binding: leftControl)
        _ = h.engine.modifierChanged(keyCode: 59, flags: CGEventFlags.maskControl.rawValue)
        h.scheduler.fireAfter(0.2)
        XCTAssertEqual(h.starts, 1)
        _ = h.engine.modifierChanged(keyCode: 59, flags: 0)
        XCTAssertEqual(h.stops, 1)
    }

    func testTapDisabledCancelsActiveRecordingExactlyOnce() {
        let h = Harness(binding: leftControl)
        h.modifierDown(leftControl)
        h.scheduler.fireAfter(0.2)
        h.engine.tapDisabled()
        XCTAssertEqual(h.discards, 1)
        h.engine.tapDisabled()
        XCTAssertEqual(h.discards, 1)
        h.modifierUp(leftControl)
        XCTAssertEqual(h.stops, 0)
        XCTAssertEqual(h.starts, 1)
    }

    func testBindingChangeCancelsAndDiscardsActiveRecording() {
        let h = Harness(binding: leftControl)
        h.modifierDown(leftControl)
        h.scheduler.fireAfter(0.2)
        h.engine.updateBinding(rightControl)
        XCTAssertEqual(h.discards, 1)
        h.modifierUp(leftControl)
        XCTAssertEqual(h.stops, 0)
        // The new binding is live: right Control now arms the engine.
        h.modifierDown(rightControl)
        h.scheduler.fireAfter(0.2)
        XCTAssertEqual(h.starts, 2)
    }

    func testShutdownDiscardsActiveRecording() {
        let h = Harness(binding: leftControl)
        h.modifierDown(leftControl)
        h.scheduler.fireAfter(0.2)
        h.engine.shutdown()
        XCTAssertEqual(h.discards, 1)
    }

    func testMouseDownWhileRecordingDiscards() {
        let h = Harness(binding: leftControl)
        h.modifierDown(leftControl)
        h.scheduler.fireAfter(0.2)
        h.engine.mouseDown()
        XCTAssertEqual(h.discards, 1)
        XCTAssertEqual(h.state, .idle)
    }

    // MARK: - Chord (existing behavior preserved)

    func testChordKeyDownStartsAndKeyUpStopsSwallowingPair() {
        let h = Harness(binding: chord)
        let downSwallowed = h.engine.keyDown(keyCode: 8, flags: CGEventFlags.maskControl.rawValue)
        XCTAssertTrue(downSwallowed)
        XCTAssertEqual(h.starts, 1)
        let upSwallowed = h.engine.keyUp(keyCode: 8, flags: 0)
        XCTAssertTrue(upSwallowed)
        XCTAssertEqual(h.stops, 1)
    }

    func testChordWithoutModifierPassesThrough() {
        let h = Harness(binding: chord)
        XCTAssertFalse(h.engine.keyDown(keyCode: 8, flags: 0))
        XCTAssertEqual(h.starts, 0)
    }

    func testChordModifierReleaseStopsRecording() {
        let h = Harness(binding: chord)
        _ = h.engine.keyDown(keyCode: 8, flags: CGEventFlags.maskControl.rawValue)
        _ = h.engine.modifierChanged(keyCode: 59, flags: 0) // Control released
        XCTAssertEqual(h.stops, 1)
    }

    func testChordModifierReleaseStillSwallowsMatchingKeyUp() {
        let h = Harness(binding: chord)
        XCTAssertTrue(h.engine.keyDown(
            keyCode: 8,
            flags: CGEventFlags.maskControl.rawValue
        ))
        _ = h.engine.modifierChanged(keyCode: 59, flags: 0)
        XCTAssertEqual(h.stops, 1)
        XCTAssertTrue(h.engine.keyUp(keyCode: 8, flags: 0))
        XCTAssertEqual(h.stops, 1)
    }

    // MARK: - Persistence

    func testDefaultAndRecommendedShortcutsStayFocused() {
        XCTAssertEqual(ShortcutBinding.defaultBinding,
                       .modifierOnly(keyCode: 61, modifier: CGEventFlags.maskAlternate.rawValue))
        XCTAssertEqual(ShortcutBinding.recommended.count, 3)
        XCTAssertEqual(ShortcutBinding.recommended.map(\.displayName), [
            "Right Option", "Right Control", "Right Command",
        ])
        XCTAssertTrue(ShortcutBinding.recommended.allSatisfy(\.isValid))
    }

    private func makeDefaults() -> UserDefaults {
        let suite = "ShortcutBindingStoreTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    func testLegacyDefaultsMigrateToChordBinding() {
        let defaults = makeDefaults()
        defaults.set(NSNumber(value: 49), forKey: ShortcutBindingStore.legacyKeyCodeDefaultsKey)
        defaults.set(NSNumber(value: CGEventFlags.maskAlternate.rawValue),
                     forKey: ShortcutBindingStore.legacyModifiersDefaultsKey)

        let binding = ShortcutBindingStore.load(defaults: defaults)
        XCTAssertEqual(binding, .chord(keyCode: 49, modifiers: CGEventFlags.maskAlternate.rawValue))
        // Migration persisted the versioned value and removed the legacy pair.
        XCTAssertNotNil(defaults.data(forKey: ShortcutBindingStore.bindingDefaultsKey))
        XCTAssertNil(defaults.object(forKey: ShortcutBindingStore.legacyKeyCodeDefaultsKey))
        XCTAssertNil(defaults.object(forKey: ShortcutBindingStore.legacyModifiersDefaultsKey))
    }

    func testInvalidPersistedDataFallsBackSafely() {
        let defaults = makeDefaults()
        defaults.set(Data("not json".utf8), forKey: ShortcutBindingStore.bindingDefaultsKey)
        XCTAssertNil(ShortcutBindingStore.load(defaults: defaults))

        let defaults2 = makeDefaults()
        let corrupt = try! JSONEncoder().encode(ShortcutBinding.modifierOnly(keyCode: 59, modifier: 12345))
        defaults2.set(corrupt, forKey: ShortcutBindingStore.bindingDefaultsKey)
        XCTAssertNil(ShortcutBindingStore.load(defaults: defaults2)) // invalid flags rejected
    }

    func testSaveAndLoadRoundTrip() {
        let defaults = makeDefaults()
        ShortcutBindingStore.save(leftControl, defaults: defaults)
        XCTAssertEqual(ShortcutBindingStore.load(defaults: defaults), leftControl)
    }
}
