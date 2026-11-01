import AppKit

/// Checks on the character boxes apps report, and the measurement Hushhh falls back
/// to when a box can't be trusted.
enum CaretMath {
    /// A box an app reported for one character could really be one character. Some
    /// apps report the whole field for every character (Excel cells), a collapsed box,
    /// or nothing at all.
    static func isPlausibleCharacterBox(_ box: CGRect, fontSize: CGFloat) -> Bool {
        box.height > 1 && box.origin != .zero && box.width >= 0.5 && box.width <= fontSize * 2.5
    }

    /// Where the caret sits on a line that starts at `lineStartX`, given the text from
    /// the line start to the caret, measured in the field's font.
    static func caretX(lineStartX: CGFloat, prefix: String, font: NSFont, limit: CGFloat) -> CGFloat {
        min(lineStartX + (prefix as NSString).size(withAttributes: [.font: font]).width, limit)
    }

    /// The caret right after a line break, from its zero-length box and the line break's box
    /// (Accessibility coordinates). With no character after the caret, as at the end of a
    /// document, TextEdit reports the zero-length box on the line break's line; the caret
    /// can't be on that line, so it moves one line down.
    static func caretAfterLineBreak(zeroLength: CGRect, lineBreak: CGRect?) -> CGRect {
        guard let lineBreak, lineBreak.height > 1,
              abs(zeroLength.midY - lineBreak.midY) < lineBreak.height * 0.5 else { return zeroLength }
        return zeroLength.offsetBy(dx: 0, dy: lineBreak.maxY - zeroLength.minY)
    }
}
