import AppKit
import CoreGraphics

struct HotKey: Equatable {
    let keyCode: Int64
    let modifiers: CGEventFlags

    static func == (lhs: HotKey, rhs: HotKey) -> Bool {
        lhs.keyCode == rhs.keyCode && lhs.modifiers.rawValue == rhs.modifiers.rawValue
    }

    var binding: ShortcutBinding {
        .chord(keyCode: keyCode, modifiers: modifiers.rawValue)
    }

    var displayName: String {
        binding.displayName
    }
}

/// Owns the global event tap and feeds raw events to a `ShortcutEngine`,
/// which owns all interpretation (see ShortcutEngine.swift). The manager only
/// translates CGEvents, applies the engine's swallow decisions, and re-enables
/// the tap when macOS disables it.
final class HotKeyManager {
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private let engine: ShortcutEngine

    var binding: ShortcutBinding { engine.binding }
    var isRunning: Bool { eventTap != nil }

    var onStart: (() -> Void)? {
        get { engine.onStart }
        set { engine.onStart = newValue }
    }
    var onStop: (() -> Void)? {
        get { engine.onStop }
        set { engine.onStop = newValue }
    }
    var onDiscard: (() -> Void)? {
        get { engine.onDiscard }
        set { engine.onDiscard = newValue }
    }
    var onDiagnostic: ((String) -> Void)? {
        get { engine.onDiagnostic }
        set { engine.onDiagnostic = newValue }
    }

    init(engine: ShortcutEngine = ShortcutEngine(binding: ShortcutBinding.chord(keyCode: 49, modifiers: CGEventFlags.maskAlternate.rawValue))) {
        self.engine = engine
    }

    func updateBinding(_ newBinding: ShortcutBinding) {
        engine.updateBinding(newBinding)
    }

    /// Cancel and discard an active gesture (used at application termination).
    func shutdown() {
        engine.shutdown()
    }

    func start() {
        guard eventTap == nil else { return }

        let mask: CGEventMask =
            (1 << CGEventType.keyDown.rawValue) |
            (1 << CGEventType.keyUp.rawValue) |
            (1 << CGEventType.flagsChanged.rawValue) |
            (1 << CGEventType.leftMouseDown.rawValue) |
            (1 << CGEventType.rightMouseDown.rawValue) |
            (1 << CGEventType.otherMouseDown.rawValue)

        let callback: CGEventTapCallBack = { _, type, event, refcon -> Unmanaged<CGEvent>? in
            guard let refcon = refcon else { return Unmanaged.passUnretained(event) }
            let mgr = Unmanaged<HotKeyManager>.fromOpaque(refcon).takeUnretainedValue()
            return mgr.handle(type: type, event: event)
        }

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: callback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            NSLog("[Whistt] failed to create event tap — grant Accessibility permission and relaunch")
            return
        }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        eventTap = tap
        runLoopSource = source
    }

    func stop() {
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
        }
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(), source, .commonModes)
        }
        eventTap = nil
        runLoopSource = nil
    }

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            engine.tapDisabled()
            if let tap = eventTap {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
            return Unmanaged.passUnretained(event)

        case .flagsChanged:
            let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
            _ = engine.modifierChanged(keyCode: keyCode, flags: event.flags.rawValue)
            return Unmanaged.passUnretained(event)

        case .keyDown:
            let kc = event.getIntegerValueField(.keyboardEventKeycode)
            return engine.keyDown(keyCode: kc, flags: event.flags.rawValue)
                ? nil : Unmanaged.passUnretained(event)

        case .keyUp:
            let kc = event.getIntegerValueField(.keyboardEventKeycode)
            return engine.keyUp(keyCode: kc, flags: event.flags.rawValue)
                ? nil : Unmanaged.passUnretained(event)

        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
            engine.mouseDown()
            return Unmanaged.passUnretained(event)

        default:
            return Unmanaged.passUnretained(event)
        }
    }
}
