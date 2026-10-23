import CoreGraphics

/// Sanity checks on carets that come from less reliable sources.
enum CaretCheck {
    /// A caret (Cocoa coordinates) is believable when it is about one line tall and
    /// sits inside the focused field, give or take a few points. Some editors report
    /// a box spanning many lines or the whole page for an empty line.
    static func isPlausible(_ caret: CGRect, in field: CGRect?) -> Bool {
        guard caret.height >= 4, caret.height <= 80 else { return false }
        guard let field else { return true }
        let slack: CGFloat = 4
        return caret.minY >= field.minY - slack && caret.maxY <= field.maxY + slack
            && caret.minX >= field.minX - slack && caret.minX <= field.maxX + slack
    }
}
