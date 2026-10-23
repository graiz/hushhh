import CoreGraphics
import Foundation

/// Where the caret is in a code editor that reports its line and column in the status
/// bar but doesn't expose its rendered text (VS Code without screen-reader mode).
enum CodeEditorPosition {
    /// "Ln 32, Col 33" (optionally followed by a selection count).
    static func lineAndColumn(fromStatus status: String) -> (line: Int, column: Int)? {
        guard let match = status.range(of: #"Ln (\d+), Col (\d+)"#, options: .regularExpression) else { return nil }
        let numbers = status[match].split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }
        guard numbers.count == 2 else { return nil }
        return (numbers[0], numbers[1])
    }

    /// Code is monospaced, so column n starts n − 1 cells after the line's start.
    static func caretX(lineStartX: CGFloat, column: Int, cellWidth: CGFloat) -> CGFloat {
        lineStartX + CGFloat(max(column - 1, 0)) * cellWidth
    }
}
