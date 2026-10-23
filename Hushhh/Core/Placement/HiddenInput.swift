import CoreGraphics

/// Code editors in web views (Monaco in VS Code, CodeMirror 5, Ace) keep keyboard
/// focus in a tiny textarea that they move to the caret, so its position is the
/// caret's. All rectangles are in Accessibility coordinates (top-left origin).
enum HiddenInput {
    /// DOM classes of the element that draws one line of code.
    static let lineClasses: Set<String> = ["view-line", "CodeMirror-line", "ace_line", "cm-line"]

    /// A focused input this small isn't where text is drawn.
    static func isHidden(_ frame: CGRect) -> Bool {
        frame.origin != .zero && (frame.width <= 4 || frame.height <= 4)
    }

    /// The caret, from the hidden input's frame and the line drawn where it sits.
    /// Nil when neither gives a height that looks like a line of text.
    static func caret(input: CGRect, line: CGRect?) -> CGRect? {
        if let line, (8...80).contains(line.height), line.minY <= input.minY + 1, line.maxY >= input.minY + 1 {
            return CGRect(x: input.minX, y: line.minY, width: 1, height: line.height)
        }
        if (8...80).contains(input.height) {
            return CGRect(x: input.minX, y: input.minY, width: 1, height: input.height)
        }
        return nil
    }

    /// Two readings of the input's frame agree, so the editor has finished moving it.
    static func isSettled(_ first: CGRect, _ second: CGRect) -> Bool {
        abs(first.minX - second.minX) < 0.5 && abs(first.minY - second.minY) < 0.5
    }

    static func isLineClass(_ classes: [String]) -> Bool {
        classes.contains(where: lineClasses.contains)
    }
}
