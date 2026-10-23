import CoreGraphics

/// Sanity checks on carets that come from less reliable sources.
enum CaretCheck {
    /// A caret (Cocoa coordinates) is believable when it is about one line tall and
    /// its middle sits within the focused field, give or take a few points. Some editors
    /// report a box far taller than a line near the caret.
    static func isPlausible(_ caret: CGRect, in field: CGRect?) -> Bool {
        guard caret.height >= 4, caret.height <= 80 else { return false }
        guard let field else { return true }
        let slack: CGFloat = 4
        return caret.midY >= field.minY - slack && caret.midY <= field.maxY + slack
            && caret.minX >= field.minX - slack && caret.minX <= field.maxX + slack
    }
}
