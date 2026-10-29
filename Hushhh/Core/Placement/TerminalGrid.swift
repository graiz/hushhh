import CoreGraphics
import Foundation

/// Where a terminal's cursor sits on its character grid (Ghostty), worked out from the
/// window, the padding and the font size rather than from the screen text's shape.
///
/// The screen text is not a picture of the grid: its rows aren't padded to the grid's
/// width, a soft-wrapped line comes back as one long row, and rows scrolled off the
/// top are still included. So the grid's size comes from the window and the cell, and
/// the text only says how many grid rows each line takes and where the cursor's line is.
enum TerminalGrid {
    /// One cell in points: 0.6 em wide and 1.32 em tall (JetBrains Mono), with the width
    /// rounded and the height rounded down to whole device pixels.
    static func cellSize(fontSize: CGFloat, scale: CGFloat) -> CGSize {
        CGSize(width: (fontSize * 0.6 * scale).rounded() / scale,
               height: (fontSize * 1.32 * scale).rounded(.down) / scale)
    }

    /// Whole cells that fit in `length` points after padding on both sides.
    static func cells(in length: CGFloat, padding: CGFloat, cell: CGFloat, scale: CGFloat) -> Int {
        let pixels = ((length - 2 * padding) * scale).rounded(.down)
        let cellPixels = (cell * scale).rounded()
        guard cellPixels > 0 else { return 0 }
        return Int((pixels / cellPixels).rounded(.down))
    }

    /// Grid rows a line of `width` columns takes: one, plus one for each soft wrap.
    static func gridRows(width: Int, columns: Int) -> Int {
        guard columns > 0, width > columns else { return 1 }
        return (width + columns - 1) / columns
    }

    /// The cursor's cell, in the same (Cocoa, y up) coordinates as `frame`.
    /// - Parameters:
    ///   - frame: the terminal view's frame.
    ///   - padding: the terminal's window padding in points (x, y).
    ///   - lineWidths: display width, in columns, of each line of the screen text, in order.
    ///   - cursorLine: index into `lineWidths` of the cursor's line.
    ///   - cursorColumn: the cursor's column within that line.
    /// - Returns: nil when the cursor would fall outside the visible grid.
    static func cursor(frame: CGRect, padding: CGSize, fontSize: CGFloat, scale: CGFloat,
                       lineWidths: [Int], cursorLine: Int, cursorColumn: Int) -> CGRect? {
        let cell = cellSize(fontSize: fontSize, scale: scale)
        let columns = cells(in: frame.width, padding: padding.width, cell: cell.width, scale: scale)
        let visibleRows = cells(in: frame.height, padding: padding.height, cell: cell.height, scale: scale)
        guard columns > 0, visibleRows > 0, lineWidths.indices.contains(cursorLine), cursorColumn >= 0 else { return nil }

        let rowsPerLine = lineWidths.map { gridRows(width: $0, columns: columns) }
        let cursorRow = rowsPerLine[..<cursorLine].reduce(0, +) + cursorColumn / columns
        // Rows past the bottom of the window have scrolled the top ones out of view.
        let scrolledOff = max(0, rowsPerLine.reduce(0, +) - visibleRows)
        let row = cursorRow - scrolledOff
        guard row >= 0, row < visibleRows else { return nil }

        let x = frame.minX + padding.width + CGFloat(cursorColumn % columns) * cell.width
        let top = frame.maxY - padding.height - CGFloat(row) * cell.height
        return CGRect(x: x, y: top - cell.height, width: cell.width, height: cell.height)
    }
}
