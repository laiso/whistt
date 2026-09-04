import CoreGraphics
import Foundation

/// A push-to-talk binding. A `chord` is a key plus modifier flags (the classic
/// behavior); a `modifierOnly` binding triggers on holding a single modifier key
/// for the hold threshold. The exact modifier key code is preserved so that
/// left/right variants stay distinct when the event stream distinguishes them.
public enum ShortcutBinding: Hashable {
    case chord(keyCode: Int64, modifiers: UInt64)
    case modifierOnly(keyCode: Int64, modifier: UInt64)
}

extension ShortcutBinding: Codable {
    private enum CodingKeys: String, CodingKey {
        case kind, keyCode, modifiers
    }

    private enum Kind: String, Codable {
        case chord, modifierOnly
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(Kind.self, forKey: .kind)
        let keyCode = try container.decode(Int64.self, forKey: .keyCode)
        let modifiers = try container.decode(UInt64.self, forKey: .modifiers)
        switch kind {
        case .chord: self = .chord(keyCode: keyCode, modifiers: modifiers)
        case .modifierOnly: self = .modifierOnly(keyCode: keyCode, modifier: modifiers)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .chord(let keyCode, let modifiers):
            try container.encode(Kind.chord, forKey: .kind)
            try container.encode(keyCode, forKey: .keyCode)
            try container.encode(modifiers, forKey: .modifiers)
        case .modifierOnly(let keyCode, let modifier):
            try container.encode(Kind.modifierOnly, forKey: .kind)
            try container.encode(keyCode, forKey: .keyCode)
            try container.encode(modifier, forKey: .modifiers)
        }
    }
}

extension ShortcutBinding {
    /// The small set shown as first-class choices in the UI. Keep this list
    /// focused; arbitrary bindings remain available through Customize.
    public static let recommended: [ShortcutBinding] = [
        .modifierOnly(keyCode: 61, modifier: CGEventFlags.maskAlternate.rawValue),
        .modifierOnly(keyCode: 62, modifier: CGEventFlags.maskControl.rawValue),
        .modifierOnly(keyCode: 54, modifier: CGEventFlags.maskCommand.rawValue),
    ]

    public static let defaultBinding = recommended[0]

    /// Supported modifier flags for any binding kind.
    public static let supportedModifierMask: UInt64 =
        CGEventFlags.maskControl.rawValue |
        CGEventFlags.maskAlternate.rawValue |
        CGEventFlags.maskShift.rawValue |
        CGEventFlags.maskCommand.rawValue

    /// A binding is valid when it uses only supported modifiers and carries
    /// the identity needed to match events.
    public var isValid: Bool {
        switch self {
        case .chord(let keyCode, let modifiers):
            return keyCode >= 0 && modifiers != 0
                && modifiers & Self.supportedModifierMask == modifiers
        case .modifierOnly(let keyCode, let modifier):
            return keyCode >= 0
                && modifier != 0 && modifier & Self.supportedModifierMask == modifier
                && modifier.nonzeroBitCount == 1
        }
    }

    public var keyCode: Int64 {
        switch self {
        case .chord(let keyCode, _): return keyCode
        case .modifierOnly(let keyCode, _): return keyCode
        }
    }

    public var modifierFlags: UInt64 {
        switch self {
        case .chord(_, let modifiers): return modifiers
        case .modifierOnly(_, let modifier): return modifier
        }
    }

    public var isModifierOnly: Bool {
        if case .modifierOnly = self { return true }
        return false
    }

    public var displayName: String {
        switch self {
        case .chord(let keyCode, let modifiers):
            let mods = Self.modifierSymbols(for: modifiers)
            let key = Self.keyName(for: keyCode)
            return mods.isEmpty ? key : "\(mods) + \(key)"
        case .modifierOnly(let keyCode, _):
            return Self.modifierKeyName(for: keyCode)
        }
    }

    /// Human-readable name for a modifier key event, distinguishing left and
    /// right variants when the event stream does.
    public static func modifierKeyName(for keyCode: Int64) -> String {
        switch keyCode {
        case 54: return "Right Command"
        case 55: return "Left Command"
        case 56: return "Left Shift"
        case 60: return "Right Shift"
        case 58: return "Left Option"
        case 61: return "Right Option"
        case 59: return "Left Control"
        case 62: return "Right Control"
        default: return "Modifier (key \(keyCode))"
        }
    }

    /// Modifier flag for a key code that fired a flagsChanged event.
    public static func modifierFlag(forKeyCode keyCode: Int64) -> UInt64? {
        switch keyCode {
        case 54, 55: return CGEventFlags.maskCommand.rawValue
        case 56, 60: return CGEventFlags.maskShift.rawValue
        case 58, 61: return CGEventFlags.maskAlternate.rawValue
        case 59, 62: return CGEventFlags.maskControl.rawValue
        default: return nil
        }
    }

    public static func modifierSymbols(for rawFlags: UInt64) -> String {
        let mods = CGEventFlags(rawValue: rawFlags)
        var parts: [String] = []
        if mods.contains(.maskControl) { parts.append("⌃") }
        if mods.contains(.maskAlternate) { parts.append("⌥") }
        if mods.contains(.maskShift) { parts.append("⇧") }
        if mods.contains(.maskCommand) { parts.append("⌘") }
        return parts.joined(separator: " + ")
    }

    public static func keyName(for keyCode: Int64) -> String {
        // Carbon HIToolbox virtual key codes.
        switch keyCode {
        case 0: return "A";  case 1: return "S";  case 2: return "D";  case 3: return "F"
        case 4: return "H";  case 5: return "G";  case 6: return "Z";  case 7: return "X"
        case 8: return "C";  case 9: return "V";  case 11: return "B"; case 12: return "Q"
        case 13: return "W"; case 14: return "E"; case 15: return "R"; case 16: return "Y"
        case 17: return "T"; case 31: return "O"; case 32: return "U"; case 34: return "I"
        case 35: return "P"; case 37: return "L"; case 38: return "J"; case 40: return "K"
        case 45: return "N"; case 46: return "M"
        case 18: return "1"; case 19: return "2"; case 20: return "3"; case 21: return "4"
        case 22: return "6"; case 23: return "5"; case 25: return "9"; case 26: return "7"
        case 28: return "8"; case 29: return "0"
        case 36: return "Return"; case 48: return "Tab"; case 49: return "Space"
        case 51: return "Delete"; case 53: return "Esc"; case 117: return "Fwd Delete"
        case 50: return "`"; case 27: return "-"; case 24: return "="
        case 33: return "["; case 30: return "]"; case 42: return "\\"
        case 41: return ";"; case 39: return "'"; case 43: return ","; case 47: return "."
        case 44: return "/"
        case 122: return "F1"; case 120: return "F2"; case 99: return "F3"
        case 118: return "F4"; case 96: return "F5"; case 97: return "F6"
        case 98: return "F7"; case 100: return "F8"; case 101: return "F9"
        case 109: return "F10"; case 103: return "F11"; case 111: return "F12"
        case 105: return "F13"; case 107: return "F14"; case 113: return "F15"
        case 106: return "F16"; case 64: return "F17"; case 79: return "F18"; case 80: return "F19"
        case 123: return "←"; case 124: return "→"; case 125: return "↓"; case 126: return "↑"
        default: return "Key \(keyCode)"
        }
    }
}

/// Versioned persistence for `ShortcutBinding`. Stores one JSON value in
/// UserDefaults and migrates the legacy key-code/modifiers pair on first load.
public enum ShortcutBindingStore {
    public static let bindingDefaultsKey = "WHISTT_SHORTCUT_BINDING_V1"
    public static let legacyKeyCodeDefaultsKey = "WHISTT_SHORTCUT_KEYCODE"
    public static let legacyModifiersDefaultsKey = "WHISTT_SHORTCUT_MODIFIERS"

    /// Loads the stored binding. Returns nil when nothing valid is stored;
    /// legacy values are migrated as a side effect.
    public static func load(defaults: UserDefaults) -> ShortcutBinding? {
        if let data = defaults.data(forKey: bindingDefaultsKey) {
            do {
                let binding = try JSONDecoder().decode(ShortcutBinding.self, from: data)
                guard binding.isValid else {
                    defaults.removeObject(forKey: bindingDefaultsKey)
                    return nil
                }
                return binding
            } catch {
                // Corrupt payload falls back to migration/default; callers log.
                defaults.removeObject(forKey: bindingDefaultsKey)
                return migrateLegacy(defaults: defaults)
            }
        }
        return migrateLegacy(defaults: defaults)
    }

    private static func migrateLegacy(defaults: UserDefaults) -> ShortcutBinding? {
        guard let kc = defaults.object(forKey: legacyKeyCodeDefaultsKey) as? NSNumber,
              let mods = defaults.object(forKey: legacyModifiersDefaultsKey) as? NSNumber else {
            return nil
        }
        let binding = ShortcutBinding.chord(
            keyCode: kc.int64Value,
            modifiers: mods.uint64Value
        )
        guard binding.isValid else { return nil }
        save(binding, defaults: defaults)
        return binding
    }

    public static func save(_ binding: ShortcutBinding, defaults: UserDefaults) {
        guard binding.isValid,
              let data = try? JSONEncoder().encode(binding) else { return }
        defaults.set(data, forKey: bindingDefaultsKey)
        defaults.removeObject(forKey: legacyKeyCodeDefaultsKey)
        defaults.removeObject(forKey: legacyModifiersDefaultsKey)
    }
}
