import Carbon.HIToolbox
import CoreGraphics

/// The key events of a synthetic Cmd-V. Marking only the V as Command-held leaves macOS
/// believing Command is still down after it, for seconds, so scrolling then zooms. Pressing
/// and releasing Command around the V ends the paste with nothing held.
enum PasteKeystrokes {
    struct Event: Equatable {
        let key: CGKeyCode
        let isDown: Bool
        let flags: CGEventFlags
    }

    static let commandKey = CGKeyCode(kVK_Command)
    static let vKey = CGKeyCode(kVK_ANSI_V)

    /// The events to post, given the modifiers the person is holding. A Command they're
    /// holding is left down, and other modifiers they're holding stay held afterward.
    static func events(physicallyHeld held: CGEventFlags) -> [Event] {
        let paste = [Event(key: vKey, isDown: true, flags: .maskCommand),
                     Event(key: vKey, isDown: false, flags: .maskCommand)]
        guard !held.contains(.maskCommand) else { return paste }
        return [Event(key: commandKey, isDown: true, flags: .maskCommand)] + paste
            + [Event(key: commandKey, isDown: false, flags: held.intersection([.maskShift, .maskAlternate, .maskControl]))]
    }
}
