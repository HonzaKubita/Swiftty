import AppKit
import RexKit

/// Converts AppKit key events into Rex key events (W3C codes in snake_case).
public enum KeyMapping {
    /// macOS virtual key code → W3C KeyboardEvent.code in snake_case.
    static let codes: [UInt16: String] = [
        0x00: "key_a", 0x0B: "key_b", 0x08: "key_c", 0x02: "key_d", 0x0E: "key_e", 0x03: "key_f",
        0x05: "key_g", 0x04: "key_h", 0x22: "key_i", 0x26: "key_j", 0x28: "key_k", 0x25: "key_l",
        0x2E: "key_m", 0x2D: "key_n", 0x1F: "key_o", 0x23: "key_p", 0x0C: "key_q", 0x0F: "key_r",
        0x01: "key_s", 0x11: "key_t", 0x20: "key_u", 0x09: "key_v", 0x0D: "key_w", 0x07: "key_x",
        0x10: "key_y", 0x06: "key_z",
        0x1D: "digit_0", 0x12: "digit_1", 0x13: "digit_2", 0x14: "digit_3", 0x15: "digit_4",
        0x17: "digit_5", 0x16: "digit_6", 0x1A: "digit_7", 0x1C: "digit_8", 0x19: "digit_9",
        0x32: "backquote", 0x2A: "backslash", 0x21: "bracket_left", 0x1E: "bracket_right",
        0x2B: "comma", 0x18: "equal", 0x0A: "intl_backslash", 0x5E: "intl_ro", 0x5D: "intl_yen",
        0x1B: "minus", 0x2F: "period", 0x27: "quote", 0x29: "semicolon", 0x2C: "slash",
        0x3A: "alt_left", 0x3D: "alt_right", 0x33: "backspace", 0x39: "caps_lock",
        0x6E: "context_menu", 0x3B: "control_left", 0x3E: "control_right", 0x24: "enter",
        0x37: "meta_left", 0x36: "meta_right", 0x38: "shift_left", 0x3C: "shift_right",
        0x31: "space", 0x30: "tab", 0x75: "delete", 0x77: "end", 0x72: "help", 0x73: "home",
        0x79: "page_down", 0x74: "page_up", 0x7D: "arrow_down", 0x7B: "arrow_left",
        0x7C: "arrow_right", 0x7E: "arrow_up", 0x47: "num_lock",
        0x52: "numpad_0", 0x53: "numpad_1", 0x54: "numpad_2", 0x55: "numpad_3", 0x56: "numpad_4",
        0x57: "numpad_5", 0x58: "numpad_6", 0x59: "numpad_7", 0x5B: "numpad_8", 0x5C: "numpad_9",
        0x45: "numpad_add", 0x5F: "numpad_comma", 0x41: "numpad_decimal", 0x4B: "numpad_divide",
        0x4C: "numpad_enter", 0x51: "numpad_equal", 0x43: "numpad_multiply", 0x4E: "numpad_subtract",
        0x35: "escape",
        0x7A: "f1", 0x78: "f2", 0x63: "f3", 0x76: "f4", 0x60: "f5", 0x61: "f6", 0x62: "f7",
        0x64: "f8", 0x65: "f9", 0x6D: "f10", 0x67: "f11", 0x6F: "f12", 0x69: "f13", 0x6B: "f14",
        0x71: "f15", 0x6A: "f16", 0x40: "f17", 0x4F: "f18", 0x50: "f19", 0x5A: "f20",
        0x3F: "fn",
    ]

    static func mods(_ flags: NSEvent.ModifierFlags) -> String {
        var parts: [String] = []
        if flags.contains(.shift) { parts.append("shift") }
        if flags.contains(.control) { parts.append("ctrl") }
        if flags.contains(.option) { parts.append("alt") }
        if flags.contains(.command) { parts.append("super") }
        if flags.contains(.capsLock) { parts.append("caps_lock") }
        return parts.joined(separator: "+")
    }

    static func event(_ e: NSEvent, action: String) -> RexKeyEvent {
        let key = codes[e.keyCode] ?? "unidentified"
        let flags = e.modifierFlags.intersection(.deviceIndependentFlagsMask)
        var text = ""
        var consumed: NSEvent.ModifierFlags = []
        if e.type == .keyDown {
            // Text typed, ignoring control (the terminal encodes ctrl itself).
            let typed = e.characters(byApplyingModifiers: flags.subtracting([.control, .command])) ?? ""
            if let scalar = typed.unicodeScalars.first, scalar.value >= 0x20, !(0xF700...0xF8FF).contains(scalar.value) {
                text = typed
                let plain = e.characters(byApplyingModifiers: []) ?? ""
                if typed != plain { consumed = flags.intersection([.shift, .option]) }
            }
            // Option as Meta: when option produces a special character, send alt + the plain key instead.
            if flags.contains(.option) && !optionComposes {
                text = (e.characters(byApplyingModifiers: flags.subtracting([.control, .command, .option])) ?? "")
                consumed = flags.intersection(.shift)
            }
        }
        let unshifted = (e.characters(byApplyingModifiers: []) ?? "").unicodeScalars.first.map { Int($0.value) } ?? 0
        return RexKeyEvent(
            key: key, mods: mods(flags), consumedMods: mods(consumed), text: text,
            unshiftedCodepoint: (0xF700...0xF8FF).contains(unshifted) ? 0 : unshifted,
            composing: false, action: action)
    }

    /// When false, Option acts as Meta (alt) like most terminals.
    nonisolated(unsafe) public static var optionComposes = false
}
