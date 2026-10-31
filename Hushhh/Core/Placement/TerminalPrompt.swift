import Foundation

/// Finds the cursor in terminal apps that draw their own prompt box (Claude Code, Codex),
/// including inside pane managers and split panes, from the terminal's screen text.
///
/// Such apps draw the input between two horizontal rules (or inside a bordered box),
/// with a prompt mark (`❯`, `>`, `›`) at the start of the input. The screen may also
/// hold a sidebar or other panes to the left and right, so everything is compared by
/// column range within the prompt's pane rather than by whole rows.
enum TerminalPrompt {
    static let marks: Set<Character> = ["❯", ">", "›"]
    /// Vertical lines that separate panes or form a box's sides.
    static let borders: Set<Character> = ["│", "┃", "║"]
    /// Characters a horizontal rule or a box's top and bottom are drawn with.
    static let ruleCharacters: Set<Character> = ["─", "━", "═", "╭", "╮", "╰", "╯", "┌", "┐", "└", "┘"]

    /// Blank cells: spaces, and the no-break space some apps put after the prompt mark.
    static func isBlank(_ character: Character) -> Bool { character == " " || character == "\u{00A0}" }

    /// How far above the prompt row the top rule may be.
    static let topRuleReach = 3

    /// Rows with text the pane may show below the box (the app's status lines). More than
    /// that means the box is left over from an app that has exited, with output and a
    /// shell prompt below it.
    static let rowsBelowLimit = 3

    /// Cells one character takes: emoji take two, everything else one.
    static func cellWidth(_ character: Character) -> Int {
        character.unicodeScalars.first?.properties.isEmojiPresentation == true ? 2 : 1
    }

    /// Cells a run of text takes.
    static func displayWidth<S: StringProtocol>(_ text: S) -> Int { text.reduce(0) { $0 + cellWidth($1) } }

    /// One character on the screen and the column it starts at.
    struct Cell { var character: Character; var column: Int; var width: Int }

    static func cells(_ row: String) -> [Cell] {
        var column = 0
        return row.map { character in
            let width = cellWidth(character)
            defer { column += width }
            return Cell(character: character, column: column, width: width)
        }
    }

    /// The cursor in a prompt box on screen.
    /// - Parameter rows: the screen text, one string per row.
    /// - Returns: the cursor's row (an index into `rows`), its column in cells, the
    ///   character before it, the column the input's lines start at, and the column of
    ///   the pane's right border if it has one; nil when no prompt bounded by rules is on screen.
    static func locate(rows: [String]) -> Found? {
        let grid = rows.map(cells)
        for row in grid.indices.reversed() {
            for markIndex in markCandidates(grid[row]) {
                if let found = bounded(grid: grid, row: row, markIndex: markIndex) { return found }
            }
        }
        return nil
    }

    /// Indexes of prompt marks that are the first non-space character after the row's
    /// start or a pane border, and are followed by a space or the end of the row.
    static func markCandidates(_ row: [Cell]) -> [Int] {
        var found: [Int] = []
        var atStart = true
        for (index, cell) in row.enumerated() {
            if isBlank(cell.character) { continue }
            if borders.contains(cell.character) { atStart = true; continue }
            if atStart, marks.contains(cell.character), index + 1 == row.count || isBlank(row[index + 1].character) {
                found.append(index)
            }
            atStart = false
        }
        return found
    }

    struct Found: Equatable {
        var row: Int
        var column: Int
        var preceding: Character?
        var textColumn: Int
        var paneEnd: Int?
    }

    private static func bounded(grid: [[Cell]], row: Int, markIndex: Int) -> Found? {
        let prompt = grid[row]
        let markColumn = prompt[markIndex].column
        // The pane ends at a border to the mark's right, if the row has one, and starts
        // after a border to its left.
        let paneEnd = prompt[(markIndex + 1)...].first { borders.contains($0.character) }?.column
        let paneStart = prompt[..<markIndex].last { borders.contains($0.character) }.map { $0.column + $0.width } ?? 0

        // Top rule, within reach above.
        let above = max(0, row - topRuleReach)..<row
        guard above.contains(where: { isRule(grid[$0], from: markColumn, to: paneEnd) }) else { return nil }

        // Continuation rows: indented past the mark, with text, before the bottom rule.
        var last = row
        var next = row + 1
        while next < grid.count, !isRule(grid[next], from: markColumn, to: paneEnd),
              isContinuation(grid[next], markColumn: markColumn, paneEnd: paneEnd) {
            last = next
            next += 1
        }
        // Bottom rule, right below the input or one row further.
        guard let bottom = (last + 1...last + 2).first(where: { grid.indices.contains($0) && isRule(grid[$0], from: markColumn, to: paneEnd) })
        else { return nil }
        // Only a few status rows may follow it in the same pane.
        let rowsBelow = grid[(bottom + 1)...].filter { !text($0, from: paneStart, to: paneEnd).isEmpty }.count
        guard rowsBelow <= rowsBelowLimit else { return nil }

        let textStart = markColumn + 2
        func found(_ row: Int, _ column: Int, _ preceding: Character?) -> Found {
            Found(row: row, column: column, preceding: preceding, textColumn: textStart, paneEnd: paneEnd)
        }
        let promptText = text(prompt, from: textStart, to: paneEnd)
        if last == row {
            if promptText.isEmpty || isPlaceholder(promptText) { return found(row, textStart, " ") }
        }
        let lastText = last == row ? promptText : text(grid[last], from: textStart, to: paneEnd)
        guard let end = lastText.last else { return found(row, textStart, " ") }
        return found(last, end.column + end.width, end.character)
    }

    /// Whether the row's cells from `start` to `end` (or to the next border, or the row's
    /// end) are mostly a horizontal rule, starting right at `start`.
    static func isRule(_ row: [Cell], from start: Int, to end: Int?) -> Bool {
        var span: [Cell] = []
        for cell in row where cell.column >= start {
            if let end, cell.column >= end { break }
            if end == nil, borders.contains(cell.character) { break }
            span.append(cell)
        }
        guard let first = span.first, first.column == start, ruleCharacters.contains(first.character) else { return false }
        let drawn = span.filter { !isBlank($0.character) }
        let ruled = drawn.filter { ruleCharacters.contains($0.character) }.count
        return ruled * 10 >= drawn.count * 8
    }

    /// A row of wrapped input: blank where the mark and its space are, then text.
    static func isContinuation(_ row: [Cell], markColumn: Int, paneEnd: Int?) -> Bool {
        let lead = row.filter { $0.column >= markColumn && $0.column < markColumn + 2 }
        guard lead.allSatisfy({ isBlank($0.character) }), row.contains(where: { $0.column >= markColumn }) else { return false }
        return !text(row, from: markColumn + 2, to: paneEnd).isEmpty
    }

    /// The non-blank cells from `start` up to the pane's end, without trailing spaces or a
    /// right-hand border.
    static func text(_ row: [Cell], from start: Int, to end: Int?) -> [Cell] {
        var span: [Cell] = []
        for cell in row where cell.column >= start {
            if let end, cell.column >= end { break }
            span.append(cell)
        }
        while let last = span.last, isBlank(last.character) || borders.contains(last.character) { span.removeLast() }
        return span
    }

    /// The hint an empty prompt box shows (`Try "…"`, or `Message @name…` when the input
    /// goes to a named agent). The screen text has no colour, so typed input that has
    /// exactly a hint's shape is taken for a hint.
    static func isPlaceholder(_ text: [Cell]) -> Bool {
        let string = String(text.map(\.character))
        return (string.count > 6 && string.hasPrefix("Try \"") && string.hasSuffix("\""))
            || (string.hasPrefix("Message @") && string.hasSuffix("…"))
    }
}
