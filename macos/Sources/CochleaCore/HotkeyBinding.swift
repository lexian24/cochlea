import Foundation

/// A global shortcut, stored so it survives a rebuild.
///
/// Carbon's `RegisterEventHotKey` takes a virtual key code and a modifier
/// mask, and both are integers with no meaning on their own. This carries them
/// together with the one thing a settings screen needs and Carbon does not
/// provide: how to write the shortcut down for a human.
///
/// Deliberately in `CochleaCore` rather than next to `HotkeyMonitor`, because
/// `Configuration` persists it and Core cannot depend on Input.
public struct HotkeyBinding: Codable, Sendable, Equatable, Hashable {

    /// Carbon virtual key code (`kVK_ANSI_D` and friends).
    public var keyCode: UInt32
    /// Carbon modifier mask (`controlKey | optionKey | cmdKey | shiftKey`).
    public var modifiers: UInt32

    public init(keyCode: UInt32, modifiers: UInt32) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }

    // Carbon's masks, restated so Core does not have to import Carbon. These
    // are stable ABI constants from HIToolbox.
    public static let control: UInt32 = 0x1000
    public static let option: UInt32  = 0x0800
    public static let shift: UInt32   = 0x0200
    public static let command: UInt32 = 0x0100

    /// Control-Option-D, which M0 hardcoded.
    ///
    /// Not a recommendation, just the previous behaviour preserved so an
    /// upgrade does not move someone's shortcut under them. The Fn key would be
    /// the natural choice for dictation and is not addressable through
    /// `RegisterEventHotKey`.
    public static let `default` = HotkeyBinding(keyCode: 0x02,               // kVK_ANSI_D
                                                modifiers: control | option)

    public var hasModifiers: Bool { modifiers != 0 }

    /// How the shortcut is written in the interface: ⌃⌥D.
    public var displayString: String {
        var text = ""
        if modifiers & Self.control != 0 { text += "⌃" }
        if modifiers & Self.option  != 0 { text += "⌥" }
        if modifiers & Self.shift   != 0 { text += "⇧" }
        if modifiers & Self.command != 0 { text += "⌘" }
        return text + (Self.keyName(for: keyCode) ?? "?")
    }

    /// A shortcut with no modifiers would swallow an ordinary keystroke
    /// everywhere on the system, so the recorder refuses one.
    public var isUsable: Bool { hasModifiers && Self.keyName(for: keyCode) != nil }

    /// Virtual key codes are a fixed hardware-independent table, so this is a
    /// lookup rather than anything locale-aware. It covers what a person is
    /// plausibly going to bind; anything unmapped is rejected by `isUsable`
    /// rather than displayed as a number nobody can act on.
    public static func keyName(for keyCode: UInt32) -> String? { names[keyCode] }

    private static let names: [UInt32: String] = [
        0x00: "A", 0x0B: "B", 0x08: "C", 0x02: "D", 0x0E: "E", 0x03: "F",
        0x05: "G", 0x04: "H", 0x22: "I", 0x26: "J", 0x28: "K", 0x25: "L",
        0x2E: "M", 0x2D: "N", 0x1F: "O", 0x23: "P", 0x0C: "Q", 0x0F: "R",
        0x01: "S", 0x11: "T", 0x20: "U", 0x09: "V", 0x0D: "W", 0x07: "X",
        0x10: "Y", 0x06: "Z",
        0x12: "1", 0x13: "2", 0x14: "3", 0x15: "4", 0x17: "5",
        0x16: "6", 0x1A: "7", 0x1C: "8", 0x19: "9", 0x1D: "0",
        0x31: "Space", 0x24: "Return", 0x30: "Tab", 0x35: "Escape",
        0x27: "'", 0x2A: "\\", 0x2B: ",", 0x1B: "-", 0x18: "=",
        0x21: "[", 0x1E: "]", 0x29: ";", 0x2C: "/", 0x2F: ".", 0x32: "`",
        0x7A: "F1", 0x78: "F2", 0x63: "F3", 0x76: "F4", 0x60: "F5",
        0x61: "F6", 0x62: "F7", 0x64: "F8", 0x65: "F9", 0x6D: "F10",
        0x67: "F11", 0x6F: "F12",
        0x7B: "←", 0x7C: "→", 0x7D: "↓", 0x7E: "↑",
    ]
}
