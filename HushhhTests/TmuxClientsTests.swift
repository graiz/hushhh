import XCTest

/// Fixtures are real tmux 3.6a output for a 120×40 window split into two side-by-side
/// panes (left 60 columns, right 59 at column 61), with a client attached at 120×41
/// (40 pane rows plus the status line). Each line ends with the client's pid and
/// `cursor_flag` (1 shown, 0 after the app sends `ESC [?25l`, as measured).
final class TmuxClientsTests: XCTestCase {
    private func line(_ fields: String...) -> String { (fields + ["4242", "1"]).joined(separator: "\t") }

    /// The right pane active, status at the bottom.
    private lazy var rightPane = line("/dev/ttys037", "120", "41", "1793331819", "xterm-256color",
                                      "61", "0", "59", "40", "3", "29", "0", "on", "bottom")

    func testParsesListClientsOutput() {
        let clients = TmuxClients.parse(rightPane + "\n")
        XCTAssertEqual(clients.count, 1)
        let client = clients[0]
        XCTAssertEqual(client.tty, "/dev/ttys037")
        XCTAssertEqual(client.width, 120)
        XCTAssertEqual(client.height, 41)
        XCTAssertEqual(client.activity, 1793331819)
        XCTAssertEqual(client.paneLeft, 61)
        XCTAssertEqual(client.cursorX, 3)
        XCTAssertEqual(client.cursorY, 29)
        XCTAssertFalse(client.inMode)
        XCTAssertEqual(client.statusLines, 1)
        XCTAssertFalse(client.statusAtTop)
        XCTAssertEqual(client.pid, 4242)
        XCTAssertFalse(client.cursorHidden)
    }

    func testSkipsMalformedLines() {
        XCTAssertTrue(TmuxClients.parse("").isEmpty)
        XCTAssertTrue(TmuxClients.parse("no server running on /tmp/tmux-501/default\n").isEmpty)
        // A detached session's display output has no client fields.
        XCTAssertTrue(TmuxClients.parse(line("", "", "", "", "", "61", "0", "59", "40", "3", "29", "0", "on", "bottom")).isEmpty)
    }

    func testOneClient() {
        let cell = TmuxClients.cursor(output: rightPane, columns: 120, rows: 41)
        XCTAssertEqual(cell?.row, 29)
        XCTAssertEqual(cell?.column, 64)
    }

    func testLeftPaneActive() {
        let left = line("/dev/ttys037", "120", "41", "1793331819", "xterm-256color",
                        "0", "0", "60", "40", "3", "19", "0", "on", "bottom")
        let cell = TmuxClients.cursor(output: left, columns: 120, rows: 41)
        XCTAssertEqual(cell?.row, 19)
        XCTAssertEqual(cell?.column, 3)
    }

    func testSplitPaneOffsetsColumn() {
        let cell = TmuxClients.cursor(output: rightPane, columns: 120, rows: 41)
        XCTAssertEqual(cell?.column, 61 + 3)
    }

    func testStatusAtTopMovesRowDown() {
        let top = line("/dev/ttys037", "120", "41", "1793331819", "xterm-256color",
                       "61", "0", "59", "40", "3", "29", "0", "on", "top")
        let cell = TmuxClients.cursor(output: top, columns: 120, rows: 41)
        XCTAssertEqual(cell?.row, 30)
        XCTAssertEqual(cell?.column, 64)
    }

    func testStatusOffAtTopKeepsRow() {
        let off = line("/dev/ttys037", "120", "40", "1793331819", "xterm-256color",
                       "0", "0", "120", "40", "5", "7", "0", "off", "top")
        XCTAssertEqual(TmuxClients.cursor(output: off, columns: 120, rows: 40)?.row, 7)
    }

    func testTwoClientsOfDifferentSizesPicksTheMatchingOne() {
        let small = line("/dev/ttys040", "80", "24", "1793331900", "xterm-ghostty",
                         "0", "0", "80", "23", "10", "4", "0", "on", "bottom")
        let output = [rightPane, small].joined(separator: "\n")
        XCTAssertEqual(TmuxClients.cursor(output: output, columns: 80, rows: 24)?.row, 4)
        XCTAssertEqual(TmuxClients.cursor(output: output, columns: 80, rows: 24)?.column, 10)
        XCTAssertEqual(TmuxClients.cursor(output: output, columns: 120, rows: 41)?.column, 64)
    }

    func testSameSizeClientsPickTheMostRecentlyActive() {
        let older = line("/dev/ttys041", "120", "41", "1793331000", "xterm-256color",
                         "0", "0", "60", "40", "1", "1", "0", "on", "bottom")
        let output = [older, rightPane].joined(separator: "\n")
        XCTAssertEqual(TmuxClients.cursor(output: output, columns: 120, rows: 41)?.column, 64)
    }

    func testClientInAnotherAppIsSkipped() {
        XCTAssertNil(TmuxClients.cursor(output: rightPane, columns: 120, rows: 41, isInApp: { $0 != 4242 }))
        XCTAssertNotNil(TmuxClients.cursor(output: rightPane, columns: 120, rows: 41, isInApp: { $0 == 4242 }))
    }

    func testCopyModeGivesNoCursor() {
        let copy = line("/dev/ttys037", "120", "41", "1793331819", "xterm-256color",
                        "61", "0", "59", "40", "3", "29", "1", "on", "top")
        XCTAssertNil(TmuxClients.cursor(output: copy, columns: 120, rows: 41))
    }

    func testHiddenCursorGivesNoCursor() {
        let hidden = rightPane.replacingOccurrences(of: "\t4242\t1", with: "\t4242\t0")
        XCTAssertTrue(TmuxClients.parse(hidden).first?.cursorHidden == true)
        XCTAssertNil(TmuxClients.cursor(output: hidden, columns: 120, rows: 41))
    }

    func testPrecedingCharacter() {
        let row = "left pane text│$ ls"
        // After "$ ls" in the right pane (pane starts at column 15).
        XCTAssertEqual(TmuxClients.preceding(row: row, column: 19, paneColumn: 4), "s")
        // Right after the border, at the pane's first column.
        XCTAssertEqual(TmuxClients.preceding(row: row, column: 15, paneColumn: 0), " ")
        // A border just before the cursor.
        XCTAssertEqual(TmuxClients.preceding(row: row, column: 15, paneColumn: 3), " ")
        // Past the row's text.
        XCTAssertEqual(TmuxClients.preceding(row: row, column: 25, paneColumn: 10), " ")
    }

    func testNoSizeMatchGivesNoCursor() {
        XCTAssertNil(TmuxClients.cursor(output: rightPane, columns: 119, rows: 41))
        XCTAssertNil(TmuxClients.cursor(output: rightPane, columns: 120, rows: 40))
        XCTAssertNil(TmuxClients.cursor(output: "", columns: 120, rows: 41))
    }

    func testFormatUsesTabs() {
        XCTAssertEqual(TmuxClients.format.split(separator: "\t").count, 16)
        XCTAssertTrue(TmuxClients.format.hasPrefix("#{client_tty}\t"))
    }

    func testSocketPath() {
        XCTAssertEqual(TmuxClients.socketPath(tmpdir: nil, uid: 501), "/tmp/tmux-501/default")
        XCTAssertEqual(TmuxClients.socketPath(tmpdir: "", uid: 501), "/tmp/tmux-501/default")
        XCTAssertEqual(TmuxClients.socketPath(tmpdir: "/var/run/", uid: 501), "/var/run/tmux-501/default")
    }

    func testRecognisesTheDefaultStatusLine() {
        XCTAssertTrue(TmuxClients.looksLikeStatusLine("[hushhh-test] 0:zsh*                                   \"host\" 23:43 29-Oct-26"))
        XCTAssertTrue(TmuxClients.looksLikeStatusLine("[0] 0:vim- 1:zsh*  "))
        XCTAssertFalse(TmuxClients.looksLikeStatusLine("user@host ~ % "))
        XCTAssertFalse(TmuxClients.looksLikeStatusLine("[main 7141bf5] Find the cursor"))
    }
}
