import CoreGraphics
import Foundation

/// Where a terminal's cursor sits on its character grid (Ghostty), worked out from the
/// window, the padding and the font rather than from the screen text's shape.
///
/// The screen text is not a picture of the grid: its rows aren't padded to the grid's
/// width, a soft-wrapped line comes back as one long row, and rows scrolled off the
/// top are still included. So the grid's size comes from the window and the cell, and
/// the text only says how many grid rows each line takes and where the cursor's line is.
/// All arithmetic is in device pixels, as the terminal does it, then converted to points.
enum TerminalGrid {
    /// Space between the window's edges and the grid, in points.
    struct Padding: Equatable {
        var left: CGFloat, right: CGFloat, top: CGFloat, bottom: CGFloat
        /// Ghostty's default: 2 pt on every side.
        static let ghosttyDefault = Padding(left: 2, right: 2, top: 2, bottom: 2)
    }

    /// Ghostty's padding settings: `window-padding-x`/`-y` take one value for both sides
    /// or two ("4,8" is left,right or top,bottom). A missing or unreadable value keeps the default.
    static func padding(x: String?, y: String?, default fallback: Padding = .ghosttyDefault) -> Padding {
        let horizontal = pair(x) ?? (fallback.left, fallback.right)
        let vertical = pair(y) ?? (fallback.top, fallback.bottom)
        return Padding(left: horizontal.0, right: horizontal.1, top: vertical.0, bottom: vertical.1)
    }

    /// "4" → (4, 4); "4,8" → (4, 8); anything else → nil.
    static func pair(_ text: String?) -> (CGFloat, CGFloat)? {
        guard let text else { return nil }
        let parts = text.split(separator: ",", omittingEmptySubsequences: false)
            .map { Double($0.trimmingCharacters(in: .whitespaces)) }
        guard (1...2).contains(parts.count), parts.allSatisfy({ ($0 ?? -1) >= 0 }) else { return nil }
        let first = CGFloat(parts[0]!)
        return (first, parts.count == 2 ? CGFloat(parts[1]!) : first)
    }

    /// A screen row without the spaces (and tabs) the terminal pads it with.
    static func trimmingTrailingSpaces(_ row: String) -> Substring {
        var end = row.endIndex
        while end > row.startIndex {
            let previous = row.index(before: end)
            guard row[previous] == " " || row[previous] == "\t" else { break }
            end = previous
        }
        return row[..<end]
    }

    /// Ghostty's boolean settings ("true"/"false").
    static func flag(_ text: String?) -> Bool { text?.trimmingCharacters(in: .whitespaces).lowercased() == "true" }

    /// One cell in points for a font whose "M" advance and line height (ascender −
    /// descender + leading) are given in points, rounded to whole device pixels.
    static func cellSize(advance: CGFloat, lineHeight: CGFloat, scale: CGFloat) -> CGSize {
        CGSize(width: (advance * scale).rounded() / scale, height: (lineHeight * scale).rounded() / scale)
    }

    /// One cell of Ghostty's built-in font (JetBrains Mono: 0.6 em wide, 1.32 em tall).
    static func cellSize(fontSize: CGFloat, scale: CGFloat) -> CGSize {
        cellSize(advance: fontSize * 0.6, lineHeight: fontSize * 1.32, scale: scale)
    }

    /// Grid rows a line of `width` columns takes: one, plus one for each soft wrap.
    static func gridRows(width: Int, columns: Int) -> Int {
        guard columns > 0, width > columns else { return 1 }
        return (width + columns - 1) / columns
    }

    /// The cursor's cell and the grid's left and right edges, in the same (Cocoa, y up)
    /// coordinates as the frame.
    struct Placement: Equatable {
        var cell: CGRect
        var gridMinX: CGFloat
        var gridMaxX: CGFloat
    }

    /// The grid's size in whole cells: columns and visible rows.
    static func size(frame: CGRect, padding: Padding, cell: CGSize, scale: CGFloat) -> (columns: Int, rows: Int)? {
        func px(_ points: CGFloat) -> CGFloat { (points * scale).rounded(.down) }
        let cellW = (cell.width * scale).rounded(), cellH = (cell.height * scale).rounded()
        guard cellW > 0, cellH > 0 else { return nil }
        let columns = Int(max(0, px(frame.width) - px(padding.left) - px(padding.right)) / cellW)
        let rows = Int(max(0, px(frame.height) - px(padding.top) - px(padding.bottom)) / cellH)
        guard columns > 0, rows > 0 else { return nil }
        return (columns, rows)
    }

    /// Where the cursor's cell is.
    /// - Parameters:
    ///   - frame: the terminal view's frame.
    ///   - padding: the configured window padding.
    ///   - balanced: `window-padding-balance`: the space left over after whole cells is
    ///     shared out around the grid instead of going to the right and bottom.
    ///   - cell: the cell size in points (see `cellSize`).
    ///   - lineWidths: display width, in columns, of each line of the screen text, in order.
    ///   - cursorLine: index into `lineWidths` of the cursor's line.
    ///   - cursorColumn: the cursor's column within that line.
    /// - Returns: nil when the cursor would fall outside the visible grid.
    static func cursor(frame: CGRect, padding: Padding, balanced: Bool = false, cell: CGSize, scale: CGFloat,
                       lineWidths: [Int], cursorLine: Int, cursorColumn: Int) -> Placement? {
        guard let grid = size(frame: frame, padding: padding, cell: cell, scale: scale),
              lineWidths.indices.contains(cursorLine), cursorColumn >= 0 else { return nil }
        let columns = grid.columns

        // A cursor just past the last column waits there (pending wrap) until the next
        // character arrives, so it stays on the last column of its row.
        var rowInLine = cursorColumn / columns
        var column = cursorColumn % columns
        if column == 0, rowInLine > 0 { rowInLine -= 1; column = columns - 1 }

        let rowsPerLine = lineWidths.map { gridRows(width: $0, columns: columns) }
        let cursorRow = rowsPerLine[..<cursorLine].reduce(0, +) + rowInLine
        // Rows past the bottom of the window have scrolled the top ones out of view.
        let scrolledOff = max(0, rowsPerLine.reduce(0, +) - grid.rows)
        return placement(frame: frame, padding: padding, balanced: balanced, cell: cell, scale: scale,
                         row: cursorRow - scrolledOff, column: column)
    }

    /// The cell at a screen `row` and `column` of the visible grid (as a full-screen app
    /// such as tmux reports them); nil outside the grid.
    static func placement(frame: CGRect, padding: Padding, balanced: Bool = false, cell: CGSize, scale: CGFloat,
                          row: Int, column: Int) -> Placement? {
        func px(_ points: CGFloat) -> CGFloat { (points * scale).rounded(.down) }
        guard let grid = size(frame: frame, padding: padding, cell: cell, scale: scale),
              (0..<grid.rows).contains(row), (0..<grid.columns).contains(column) else { return nil }
        let cellW = (cell.width * scale).rounded(), cellH = (cell.height * scale).rounded()
        let width = px(frame.width), height = px(frame.height)

        var left = px(padding.left), top = px(padding.top)
        if balanced {
            // Left and right get half the spare width each. The top gets half the spare
            // height, but at most the average side padding plus half a cell; the bottom
            // takes the rest.
            left = ((width - CGFloat(grid.columns) * cellW) / 2).rounded(.down)
            let topLimit = ((px(padding.left) + px(padding.right) + cellW) / 2).rounded(.down)
            top = min(topLimit, ((height - CGFloat(grid.rows) * cellH) / 2).rounded(.down))
        }

        let x = frame.minX + (left + CGFloat(column) * cellW) / scale
        let cellTop = frame.maxY - (top + CGFloat(row) * cellH) / scale
        return Placement(cell: CGRect(x: x, y: cellTop - cellH / scale, width: cellW / scale, height: cellH / scale),
                         gridMinX: frame.minX + left / scale,
                         gridMaxX: frame.minX + (left + CGFloat(grid.columns) * cellW) / scale)
    }
}
