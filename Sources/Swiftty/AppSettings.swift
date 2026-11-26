import AppKit
import Carbon.HIToolbox
import Observation
import TerminalKit

/// A key combination for the global hotkey.
struct Hotkey: Codable, Equatable {
    var keyCode: UInt32
    var modifiers: NSEvent.ModifierFlags.RawValue

    static let `default` = Hotkey(keyCode: UInt32(kVK_ANSI_Grave), modifiers: NSEvent.ModifierFlags.control.rawValue)

    var flags: NSEvent.ModifierFlags { NSEvent.ModifierFlags(rawValue: modifiers) }

    /// Carbon modifier mask for RegisterEventHotKey.
    var carbonModifiers: UInt32 {
        var m: UInt32 = 0
        if flags.contains(.command) { m |= UInt32(cmdKey) }
        if flags.contains(.option) { m |= UInt32(optionKey) }
        if flags.contains(.control) { m |= UInt32(controlKey) }
        if flags.contains(.shift) { m |= UInt32(shiftKey) }
        return m
    }

    var display: String {
        var s = ""
        if flags.contains(.control) { s += "⌃" }
        if flags.contains(.option) { s += "⌥" }
        if flags.contains(.shift) { s += "⇧" }
        if flags.contains(.command) { s += "⌘" }
        return s + Self.keyName(keyCode)
    }

    static func keyName(_ code: UInt32) -> String {
        switch Int(code) {
        case kVK_Space: return "Space"
        case kVK_ANSI_Grave: return "`"
        case kVK_Return: return "↩"
        case kVK_Tab: return "⇥"
        case kVK_Escape: return "⎋"
        default:
            let source = TISCopyCurrentKeyboardLayoutInputSource().takeRetainedValue()
            guard let ptr = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return "#\(code)" }
            let data = Unmanaged<CFData>.fromOpaque(ptr).takeUnretainedValue() as Data
            var dead: UInt32 = 0
            var chars = [UniChar](repeating: 0, count: 4)
            var len = 0
            data.withUnsafeBytes { raw in
                let layout = raw.bindMemory(to: UCKeyboardLayout.self).baseAddress!
                UCKeyTranslate(layout, UInt16(code), UInt16(kUCKeyActionDisplay), 0, UInt32(LMGetKbdType()),
                               OptionBits(kUCKeyTranslateNoDeadKeysBit), &dead, 4, &len, &chars)
            }
            return String(utf16CodeUnits: chars, count: len).uppercased()
        }
    }
}

/// Swiftty's preferences, saved in UserDefaults.
@MainActor
@Observable
final class AppSettings {
    static let shared = AppSettings()
    private let defaults = UserDefaults.standard

    var optionIsMeta: Bool { didSet { defaults.set(optionIsMeta, forKey: "optionIsMeta"); KeyMapping.optionComposes = !optionIsMeta } }
    var confirmCloseSession: Bool { didSet { defaults.set(confirmCloseSession, forKey: "confirmCloseSession") } }
    var quickTerminalEnabled: Bool { didSet { defaults.set(quickTerminalEnabled, forKey: "quickTerminalEnabled"); onHotkeyChange?() } }
    var hotkey: Hotkey {
        didSet {
            if let data = try? JSONEncoder().encode(hotkey) { defaults.set(data, forKey: "hotkey") }
            onHotkeyChange?()
        }
    }
    /// With the quick terminal on: hide the Dock icon when no normal window is open.
    var hideDockWithoutWindows: Bool { didSet { defaults.set(hideDockWithoutWindows, forKey: "hideDockWithoutWindows"); onHotkeyChange?() } }

    /// The welcome sheet was finished.
    var onboardingDone: Bool { didSet { defaults.set(onboardingDone, forKey: "onboardingDone") } }

    @ObservationIgnored var onHotkeyChange: (() -> Void)?

    private init() {
        defaults.register(defaults: [
            "optionIsMeta": true, "confirmCloseSession": true,
            "quickTerminalEnabled": true, "hideDockWithoutWindows": true,
        ])
        optionIsMeta = defaults.bool(forKey: "optionIsMeta")
        confirmCloseSession = defaults.bool(forKey: "confirmCloseSession")
        quickTerminalEnabled = defaults.bool(forKey: "quickTerminalEnabled")
        hideDockWithoutWindows = defaults.bool(forKey: "hideDockWithoutWindows")
        onboardingDone = defaults.bool(forKey: "onboardingDone")
        hotkey = defaults.data(forKey: "hotkey").flatMap { try? JSONDecoder().decode(Hotkey.self, from: $0) } ?? .default
        KeyMapping.optionComposes = !optionIsMeta
    }
}
