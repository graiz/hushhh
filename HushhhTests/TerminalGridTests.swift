import AppKit
import XCTest

/// Cases measured in Ghostty 1.4 (padding 4/4 from the person's config, scale 2) on a
/// 982 pt tall screen: the real cursor block was found in a screenshot. Frames and
/// expected tops are given in top-left screen points, as measured, and converted to Cocoa here.
final class TerminalGridTests: XCTestCase {
    private let screenHeight: CGFloat = 982
    private let padding = TerminalGrid.Padding(left: 4, right: 4, top: 4, bottom: 4)
    private let tolerance: CGFloat = 0.5

    /// The text area's frame from its top-left origin and size.
    private func frame(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> CGRect {
        CGRect(x: x, y: screenHeight - y - h, width: w, height: h)
    }

    private func assertCursor(_ frame: CGRect, cell: CGSize = CGSize(width: 8, height: 17), scale: CGFloat = 2,
                              padding customPadding: TerminalGrid.Padding? = nil, balanced: Bool = false,
                              lines: [Int], line: Int, column: Int, x: CGFloat, top: CGFloat,
                              file: StaticString = #filePath, line testLine: UInt = #line) {
        guard let cursor = TerminalGrid.cursor(frame: frame, padding: customPadding ?? padding, balanced: balanced, cell: cell,
                                               scale: scale, lineWidths: lines, cursorLine: line, cursorColumn: column)?.cell else {
            return XCTFail("no cursor", file: file, line: testLine)
        }
        XCTAssertEqual(cursor.minX, x, accuracy: tolerance, file: file, line: testLine)
        XCTAssertEqual(screenHeight - cursor.maxY, top, accuracy: tolerance, file: file, line: testLine)
        XCTAssertEqual(screenHeight - cursor.minY, top + cell.height, accuracy: tolerance, file: file, line: testLine)
    }

    /// A login banner, then a two-line prompt whose first row carries a right prompt.
    private func promptScreen(rightPromptRow: Int) -> [Int] {
        [42, 0, 14, 14, 14, 14, 16, 17] + Array(repeating: 62, count: 10) + [0, rightPromptRow, 3]
    }

    // MARK: Cell size

    func testCellSizeMatchesMeasuredBlock() {
        XCTAssertEqual(TerminalGrid.cellSize(fontSize: 13, scale: 2), CGSize(width: 8, height: 17))
    }

    // MARK: Measured: default font, size 13

    func testPromptAtNaturalSize() {
        assertCursor(frame(155, 136, 1222, 793), lines: promptScreen(rightPromptRow: 150), line: 20, column: 3, x: 183, top: 480)
    }

    // After a resize Ghostty reflows the full-width right-prompt row and reports the
    // soft-wrapped result as one row; it fills two or three grid rows.
    func testWrappedRowAt900() {
        assertCursor(frame(155, 136, 900, 568), lines: promptScreen(rightPromptRow: 221), line: 20, column: 3, x: 183, top: 497)
    }

    func testWrappedRowAt1285() {
        assertCursor(frame(155, 136, 1285, 846), lines: promptScreen(rightPromptRow: 317), line: 20, column: 3, x: 183, top: 497)
    }

    func testRowWrappedThreeTimesAt1003() {
        assertCursor(frame(155, 136, 1003, 579), lines: promptScreen(rightPromptRow: 371), line: 20, column: 3, x: 183, top: 514)
    }

    /// 34 printed lines, then a 50-column prompt: no row reaches the grid's width, and
    /// on short windows the top rows have scrolled out of view.
    private let scrolled = [0] + Array(repeating: 7, count: 34) + [50]

    func testScrolledAt1003x611() {
        assertCursor(frame(155, 136, 1003, 579), lines: scrolled, line: 35, column: 50, x: 559, top: 684)
    }

    func testScrolledAt900x600() {
        assertCursor(frame(155, 136, 900, 568), lines: scrolled, line: 35, column: 50, x: 559, top: 667)
    }

    func testNotScrolledAt1222x825() {
        assertCursor(frame(155, 136, 1222, 793), lines: scrolled, line: 35, column: 50, x: 559, top: 735)
    }

    func testScrolledAt1003x400() {
        assertCursor(frame(155, 136, 1003, 368), lines: scrolled, line: 35, column: 50, x: 559, top: 480)
    }

    // MARK: Measured: other font sizes (cursor drawn as a bar, 1 px left of the cell)

    func testFontSize12() {
        let cell = TerminalGrid.cellSize(fontSize: 12, scale: 2)
        XCTAssertEqual(cell, CGSize(width: 7, height: 16))   // 14.4 → 14 px, 31.68 → 32 px
        assertCursor(frame(155, 136, 1222, 793), cell: cell, lines: promptScreen(rightPromptRow: 172), line: 20, column: 3, x: 180, top: 460)
        assertCursor(frame(155, 136, 900, 568), cell: cell, lines: promptScreen(rightPromptRow: 172), line: 20, column: 3, x: 180, top: 476)
    }

    func testFontSize14() {
        let cell = TerminalGrid.cellSize(fontSize: 14, scale: 2)
        XCTAssertEqual(cell, CGSize(width: 8.5, height: 18.5))   // 16.8 → 17 px, 36.96 → 37 px
        assertCursor(frame(155, 136, 1222, 793), cell: cell, lines: promptScreen(rightPromptRow: 141), line: 20, column: 3, x: 184.5, top: 510)
        assertCursor(frame(155, 136, 900, 568), cell: cell, lines: promptScreen(rightPromptRow: 141), line: 20, column: 3, x: 184.5, top: 528.5)
    }

    // MARK: Measured: font-family = Menlo, size 13

    func testMenlo() throws {
        let font = try XCTUnwrap(NSFontManager.shared.font(withFamily: "Menlo", traits: [], weight: 5, size: 13))
        let cell = TerminalGrid.cellSize(advance: ("M" as NSString).size(withAttributes: [.font: font]).width,
                                         lineHeight: font.ascender - font.descender + font.leading, scale: 2)
        XCTAssertEqual(cell, CGSize(width: 8, height: 15))
        assertCursor(frame(155, 136, 1222, 793), cell: cell, lines: promptScreen(rightPromptRow: 150), line: 20, column: 3, x: 183, top: 440)
        assertCursor(frame(155, 136, 900, 568), cell: cell, lines: promptScreen(rightPromptRow: 150), line: 20, column: 3, x: 183, top: 455)
    }

    // MARK: Measured: window-padding-balance = true

    func testBalancedPadding() {
        // Spare width is split evenly; the top is capped at (4 + 4 + 8) / 2 = 8 pt.
        assertCursor(frame(155, 136, 1222, 793), balanced: true, lines: promptScreen(rightPromptRow: 150), line: 20, column: 3, x: 186, top: 481.5)
        assertCursor(frame(155, 136, 900, 568), balanced: true, lines: promptScreen(rightPromptRow: 150), line: 20, column: 3, x: 185, top: 501)
        assertCursor(frame(155, 136, 1003, 579), balanced: true, lines: promptScreen(rightPromptRow: 150), line: 20, column: 3, x: 184.5, top: 501)
    }

    // MARK: Grid arithmetic

    func testScaleOne() {
        // 13 pt at 1x: 7.8 → 8 px wide, 17.16 → 17 px tall.
        let cell = TerminalGrid.cellSize(fontSize: 13, scale: 1)
        XCTAssertEqual(cell, CGSize(width: 8, height: 17))
        assertCursor(frame(100, 100, 400, 300), cell: cell, scale: 1, lines: [10, 3], line: 1, column: 3, x: 128, top: 121)
    }

    func testRowsScrolledPastTheCursorGiveNoCursor() {
        // 8 visible rows; 20 rows below the cursor's line push it off the top.
        let lines = [5] + Array(repeating: 5, count: 20)
        XCTAssertNil(TerminalGrid.cursor(frame: frame(0, 0, 200, 17 * 8 + 8), padding: padding, cell: CGSize(width: 8, height: 17),
                                         scale: 2, lineWidths: lines, cursorLine: 0, cursorColumn: 5))
    }

    func testCursorAtTheLastColumnWaitsThere() {
        // 10 columns; after 10 characters the cursor stays on column 9 of the same row.
        let f = frame(0, 0, 8 * 10 + 8, 17 * 5 + 8)
        assertCursor(f, lines: [10], line: 0, column: 10, x: 4 + 9 * 8, top: 4)
        // After 12 it is on the next row.
        assertCursor(f, lines: [12], line: 0, column: 12, x: 4 + 2 * 8, top: 4 + 17)
    }

    func testNoCursorWhenTheGridHasNoRoom() {
        XCTAssertNil(TerminalGrid.cursor(frame: frame(0, 0, 6, 6), padding: padding, cell: CGSize(width: 8, height: 17), scale: 2,
                                         lineWidths: [3], cursorLine: 0, cursorColumn: 3))
    }

    func testUnevenPadding() {
        let uneven = TerminalGrid.Padding(left: 10, right: 30, top: 6, bottom: 2)
        assertCursor(frame(0, 0, 400, 300), padding: uneven, lines: [3], line: 0, column: 3, x: 34, top: 6)
    }

    func testGridEdges() {
        let placement = TerminalGrid.cursor(frame: frame(0, 0, 1003, 579), padding: padding, cell: CGSize(width: 8, height: 17),
                                            scale: 2, lineWidths: [3], cursorLine: 0, cursorColumn: 3)
        XCTAssertEqual(placement?.gridMinX, 4)
        XCTAssertEqual(placement?.gridMaxX, 4 + 124 * 8)
    }

    func testGridRows() {
        XCTAssertEqual(TerminalGrid.gridRows(width: 0, columns: 111), 1)
        XCTAssertEqual(TerminalGrid.gridRows(width: 111, columns: 111), 1)
        XCTAssertEqual(TerminalGrid.gridRows(width: 112, columns: 111), 2)
        XCTAssertEqual(TerminalGrid.gridRows(width: 371, columns: 124), 3)
    }

    // MARK: Settings

    func testPaddingParsing() {
        XCTAssertEqual(TerminalGrid.padding(x: nil, y: nil), .ghosttyDefault)
        XCTAssertEqual(TerminalGrid.padding(x: "4", y: "4"), TerminalGrid.Padding(left: 4, right: 4, top: 4, bottom: 4))
        XCTAssertEqual(TerminalGrid.padding(x: "4,8", y: " 1 , 3 "), TerminalGrid.Padding(left: 4, right: 8, top: 1, bottom: 3))
        XCTAssertEqual(TerminalGrid.padding(x: "wide", y: "1,2,3"), .ghosttyDefault)
        XCTAssertEqual(TerminalGrid.padding(x: "-1", y: "2.5"), TerminalGrid.Padding(left: 2, right: 2, top: 2.5, bottom: 2.5))
    }

    func testFlag() {
        XCTAssertTrue(TerminalGrid.flag("true"))
        XCTAssertTrue(TerminalGrid.flag(" TRUE "))
        XCTAssertFalse(TerminalGrid.flag("false"))
        XCTAssertFalse(TerminalGrid.flag(nil))
    }

    func testTrimmingTrailingSpaces() {
        XCTAssertEqual(TerminalGrid.trimmingTrailingSpaces("╰─ "), "╰─")
        XCTAssertEqual(TerminalGrid.trimmingTrailingSpaces("a b \t  "), "a b")
        XCTAssertEqual(TerminalGrid.trimmingTrailingSpaces("    "), "")
        XCTAssertEqual(TerminalGrid.trimmingTrailingSpaces("x"), "x")
    }
}
