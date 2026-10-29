import CoreGraphics
import XCTest

/// Cases measured in Ghostty 1.4 (padding 4/4, font size 13, scale 2) on a 982 pt tall
/// screen: the real cursor block was found in a screenshot. Frames and expected tops are
/// given in top-left screen points, as measured, and converted to Cocoa here.
final class TerminalGridTests: XCTestCase {
    private let screenHeight: CGFloat = 982
    private let padding = CGSize(width: 4, height: 4)

    /// The text area's frame from its top-left origin and size.
    private func frame(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> CGRect {
        CGRect(x: x, y: screenHeight - y - h, width: w, height: h)
    }

    private func assertCursor(_ frame: CGRect, lines: [Int], line: Int, column: Int,
                              x: CGFloat, top: CGFloat, file: StaticString = #filePath, line testLine: UInt = #line) {
        guard let cursor = TerminalGrid.cursor(frame: frame, padding: padding, fontSize: 13, scale: 2,
                                               lineWidths: lines, cursorLine: line, cursorColumn: column) else {
            return XCTFail("no cursor", file: file, line: testLine)
        }
        XCTAssertEqual(cursor.minX, x, accuracy: 1, file: file, line: testLine)
        XCTAssertEqual(screenHeight - cursor.maxY, top, accuracy: 1, file: file, line: testLine)
        XCTAssertEqual(screenHeight - cursor.minY, top + 17, accuracy: 1, file: file, line: testLine)
    }

    /// A login banner, then a two-line prompt whose first row carries a right prompt.
    private func promptScreen(rightPromptRow: Int) -> [Int] {
        [42, 0, 14, 14, 14, 14, 16, 17] + Array(repeating: 62, count: 10) + [0, rightPromptRow, 3]
    }

    func testCellSizeMatchesMeasuredBlock() {
        XCTAssertEqual(TerminalGrid.cellSize(fontSize: 13, scale: 2), CGSize(width: 8, height: 17))
    }

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

    func testGridRows() {
        XCTAssertEqual(TerminalGrid.gridRows(width: 0, columns: 111), 1)
        XCTAssertEqual(TerminalGrid.gridRows(width: 111, columns: 111), 1)
        XCTAssertEqual(TerminalGrid.gridRows(width: 112, columns: 111), 2)
        XCTAssertEqual(TerminalGrid.gridRows(width: 371, columns: 124), 3)
    }

    func testCursorPastTheLastColumnWrapsToTheNextRow() {
        let cursor = TerminalGrid.cursor(frame: frame(0, 0, 8 * 10 + 8, 17 * 5 + 8), padding: padding, fontSize: 13, scale: 2,
                                         lineWidths: [12], cursorLine: 0, cursorColumn: 12)
        XCTAssertEqual(cursor?.minX, 4 + 2 * 8)
        XCTAssertEqual(cursor.map { screenHeight - $0.maxY }, 4 + 17)
    }

    func testNoCursorWhenTheGridHasNoRoom() {
        XCTAssertNil(TerminalGrid.cursor(frame: frame(0, 0, 6, 6), padding: padding, fontSize: 13, scale: 2,
                                         lineWidths: [3], cursorLine: 0, cursorColumn: 3))
    }
}
