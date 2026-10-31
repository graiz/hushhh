import Foundation

/// The key that starts and finishes dictation: Caps Lock (the default) or a key the
/// person recorded in Settings, optionally with modifiers.
struct DictationKey: Codable, Equatable {
    struct Modifiers: OptionSet, Codable, Hashable {
        let rawValue: UInt8
        static let control = Modifiers(rawValue: 1 << 0)
        static let option = Modifiers(rawValue: 1 << 1)
        static let shift = Modifiers(rawValue: 1 << 2)
        static let command = Modifiers(rawValue: 1 << 3)

        /// In the order macOS menus show them.
        var symbols: String {
            [(Modifiers.control, "⌃"), (.option, "⌥"), (.shift, "⇧"), (.command, "⌘")]
                .filter { contains($0.0) }.map(\.1).joined()
        }
    }

    /// A virtual key code (as in Carbon's `kVK_` constants).
    var keyCode: Int
    var modifiers: Modifiers
    /// The key's label as recorded, e.g. "F5" or "D".
    var name: String

    static let capsLockKeyCode = 57
    static let capsLock = DictationKey(keyCode: capsLockKeyCode, modifiers: [], name: "Caps Lock")

    var isCapsLock: Bool { keyCode == Self.capsLockKeyCode }

    /// Short form for key hints: "⇪", "F5", "⌥D".
    var symbol: String { isCapsLock ? "⇪" : modifiers.symbols + name }
    /// Long form for sentences and Settings: "⇪ Caps Lock", "F5", "⌥D".
    var title: String { isCapsLock ? "⇪ Caps Lock" : symbol }
    /// For sentences: "Caps Lock", "F5", "⌥D".
    var spoken: String { isCapsLock ? "Caps Lock" : symbol }

    /// Whether a key press is this key: the same key with exactly the same modifiers.
    func matches(keyCode: Int, modifiers: Modifiers) -> Bool {
        keyCode == self.keyCode && modifiers == self.modifiers
    }

    static let escapeKeyCode = 53
    static let tabKeyCode = 48

    /// Why a key can't be the dictation key, or nil if it can. Esc and Tab are taken
    /// while dictating; any other key needs ⌘, ⌥ or ⌃ unless it's a function key, so
    /// typing still works.
    static func rejection(keyCode: Int, modifiers: Modifiers) -> String? {
        let typed = modifiers.subtracting(.shift).isEmpty
        if typed, keyCode == escapeKeyCode || keyCode == tabKeyCode {
            return "Esc cancels and Tab polishes while dictating. Choose another key."
        }
        if typed, functionKeyNames[keyCode] == nil {
            return "Add ⌘, ⌥ or ⌃, or choose a function key, so the key still types."
        }
        return nil
    }

    /// The label for a key: a function or special key's name, else the character it types.
    static func name(keyCode: Int, characters: String?) -> String {
        if let name = functionKeyNames[keyCode] ?? specialKeyNames[keyCode] { return name }
        let typed = (characters ?? "").trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        return typed.isEmpty ? "Key \(keyCode)" : typed
    }

    static let functionKeyNames: [Int: String] = [
        122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6", 98: "F7", 100: "F8",
        101: "F9", 109: "F10", 103: "F11", 111: "F12", 105: "F13", 107: "F14", 113: "F15",
        106: "F16", 64: "F17", 79: "F18", 80: "F19", 90: "F20",
    ]

    static let specialKeyNames: [Int: String] = [
        49: "Space", 36: "↩", 76: "⌤", 51: "⌫", 117: "⌦", 123: "←", 124: "→", 125: "↓", 126: "↑",
        115: "↖", 119: "↘", 116: "⇞", 121: "⇟", 114: "Help", 48: "⇥", 53: "⎋",
    ]
}
