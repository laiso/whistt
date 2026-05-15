import AppKit
import CoreGraphics

enum TypingEmulator {
    static func type(_ text: String) {
        guard !text.isEmpty else { return }
        let source = CGEventSource(stateID: .hidSystemState)
        let utf16 = Array(text.utf16)
        utf16.withUnsafeBufferPointer { ptr in
            guard let base = ptr.baseAddress else { return }
            let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true)
            let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false)
            keyDown?.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: base)
            keyUp?.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: base)
            keyDown?.post(tap: .cghidEventTap)
            keyUp?.post(tap: .cghidEventTap)
        }
    }
}

enum ClipboardOutput {
    static func set(_ text: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
    }
}
