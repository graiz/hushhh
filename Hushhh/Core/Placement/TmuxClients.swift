import Foundation

/// Where the cursor is in a terminal running tmux, from `tmux list-clients` output.
///
/// tmux owns the whole terminal screen, so the screen text can't say where its cursor
/// is: the last row is usually tmux's status line, and the active pane can be anywhere.
/// tmux itself reports each attached client's size and its active pane's position and
/// cursor, so the client whose size matches the terminal's grid gives the exact cell.
enum TmuxClients {
    /// The `list-clients` fields, in order. The pane fields are each client's active pane.
    static let fields = ["client_tty", "client_width", "client_height", "client_activity", "client_termname",
                         "pane_left", "pane_top", "pane_width", "pane_height", "cursor_x", "cursor_y",
                         "pane_in_mode", "status", "status-position", "client_pid", "cursor_flag"]

    /// The `-F` format: the fields separated by tabs, which none of the values contain.
    static var format: String { fields.map { "#{\($0)}" }.joined(separator: "\t") }

    struct Client: Equatable {
        var tty: String
        var width: Int, height: Int
        var activity: Int
        var paneLeft: Int, paneTop: Int, paneWidth: Int, paneHeight: Int
        var cursorX: Int, cursorY: Int
        /// The pane is in copy or another mode, so the cursor isn't where input goes.
        var inMode: Bool
        /// The app in the pane has hidden the cursor (a full-screen app that draws its own).
        var cursorHidden: Bool
        /// Rows the status line takes: `off` is none, `on` one, `2`…`5` that many.
        var statusLines: Int
        var statusAtTop: Bool
        /// The tmux client process, to tell which terminal app it runs in.
        var pid: Int32
    }

    /// One client per well-formed line; anything else (errors, a detached session's
    /// empty client fields) is skipped.
    static func parse(_ output: String) -> [Client] {
        output.split(whereSeparator: \.isNewline).compactMap { line in
            let parts = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard parts.count == fields.count else { return nil }
            let numbers = [1, 2, 3, 5, 6, 7, 8, 9, 10].map { Int(parts[$0]) }
            guard numbers.allSatisfy({ $0 != nil }), let pid = Int32(parts[14]) else { return nil }
            let n = numbers.map { $0! }
            let status: Int
            switch parts[12] {
            case "off": status = 0
            case "on": status = 1
            default: status = Int(parts[12]) ?? 1
            }
            return Client(tty: parts[0], width: n[0], height: n[1], activity: n[2],
                          paneLeft: n[3], paneTop: n[4], paneWidth: n[5], paneHeight: n[6],
                          cursorX: n[7], cursorY: n[8], inMode: parts[11] == "1", cursorHidden: parts[15] == "0",
                          statusLines: status, statusAtTop: parts[13] == "top", pid: pid)
        }
    }

    /// The client showing on a terminal grid of `columns` × `rows`: of those that size
    /// (and running in the terminal app, by `isInApp`), the one most recently used. Nil
    /// when no client is that size.
    static func choose(_ clients: [Client], columns: Int, rows: Int,
                       isInApp: (Int32) -> Bool = { _ in true }) -> Client? {
        clients.filter { $0.width == columns && $0.height == rows && isInApp($0.pid) }.max { $0.activity < $1.activity }
    }

    /// The cursor's screen row and column on the terminal grid, and its column within the
    /// pane; nil while the pane is in copy mode or the cursor is hidden (then the screen
    /// text says where input goes), or if the cell falls outside the client.
    static func cell(_ client: Client) -> (row: Int, column: Int, paneColumn: Int)? {
        guard !client.inMode, !client.cursorHidden else { return nil }
        let row = client.paneTop + client.cursorY + (client.statusAtTop ? client.statusLines : 0)
        let column = client.paneLeft + client.cursorX
        guard (0..<client.height).contains(row), (0..<client.width).contains(column) else { return nil }
        return (row, column, client.cursorX)
    }

    /// The cursor cell for a terminal grid of `columns` × `rows`, from `list-clients` output.
    static func cursor(output: String, columns: Int, rows: Int,
                       isInApp: (Int32) -> Bool = { _ in true }) -> (row: Int, column: Int, paneColumn: Int)? {
        choose(parse(output), columns: columns, rows: rows, isInApp: isInApp).flatMap(cell)
    }

    /// The character before the cursor on its screen row: a space at the pane's first
    /// column, after a pane border, or past the row's text.
    static func preceding(row: String, column: Int, paneColumn: Int) -> Character {
        guard paneColumn > 0, column > 0,
              let before = TerminalPrompt.cells(row).last(where: { $0.column < column }),
              before.column + before.width >= column,
              !TerminalPrompt.borders.contains(before.character) else { return " " }
        return before.character
    }

    /// The default server's socket: `$TMUX_TMPDIR` (or `/tmp`), then `tmux-<uid>/default`.
    static func socketPath(tmpdir: String?, uid: UInt32) -> String {
        var base = tmpdir.flatMap { $0.isEmpty ? nil : $0 } ?? "/tmp"
        while base.count > 1, base.hasSuffix("/") { base.removeLast() }
        return "\(base)/tmux-\(uid)/default"
    }

    /// Whether a screen row looks like tmux's default status line: `[session] 0:name*…`.
    static func looksLikeStatusLine(_ row: String) -> Bool {
        row.range(of: #"^\[[^\]\n]+\] +\d+:\S"#, options: .regularExpression) != nil
    }
}
