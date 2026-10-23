import XCTest

final class HiddenInputTests: XCTestCase {
    func testTinyInputIsHidden() {
        XCTAssertTrue(HiddenInput.isHidden(CGRect(x: 100, y: 200, width: 1, height: 18)))
        XCTAssertTrue(HiddenInput.isHidden(CGRect(x: 100, y: 200, width: 300, height: 1)))
        XCTAssertTrue(HiddenInput.isHidden(CGRect(x: 289, y: 777, width: 0, height: 18)))
    }
    func testRealFieldIsNotHidden() {
        XCTAssertFalse(HiddenInput.isHidden(CGRect(x: 100, y: 200, width: 300, height: 18)))
    }
    func testInputWithoutPositionIsNotHidden() {
        XCTAssertFalse(HiddenInput.isHidden(CGRect(x: 0, y: 0, width: 1, height: 1)))
    }
    func testCaretUsesTheLineDrawnThere() {
        XCTAssertEqual(HiddenInput.caret(input: CGRect(x: 100, y: 200, width: 1, height: 1),
                                         line: CGRect(x: 60, y: 196, width: 400, height: 20)),
                       CGRect(x: 100, y: 196, width: 1, height: 20))
    }
    func testCaretFallsBackToTheInputsOwnHeight() {
        XCTAssertEqual(HiddenInput.caret(input: CGRect(x: 100, y: 200, width: 1, height: 18), line: nil),
                       CGRect(x: 100, y: 200, width: 1, height: 18))
    }
    func testLineElsewhereIsIgnored() {
        XCTAssertNil(HiddenInput.caret(input: CGRect(x: 100, y: 200, width: 1, height: 1),
                                       line: CGRect(x: 60, y: 400, width: 400, height: 20)))
    }
    func testTallLineBoxFallsBackToTheInput() {
        // Measured in VS Code: the "line" is the whole editor.
        XCTAssertEqual(HiddenInput.caret(input: CGRect(x: 289, y: 777, width: 0, height: 18),
                                         line: CGRect(x: 289, y: 219, width: 1324, height: 828)),
                       CGRect(x: 289, y: 777, width: 1, height: 18))
    }
    func testLineClasses() {
        XCTAssertTrue(HiddenInput.isLineClass(["view-line"]))
        XCTAssertTrue(HiddenInput.isLineClass(["CodeMirror-line", "other"]))
        XCTAssertTrue(HiddenInput.isLineClass(["ace_line"]))
        XCTAssertFalse(HiddenInput.isLineClass(["cm-line"]))
        XCTAssertFalse(HiddenInput.isLineClass(["view-lines"]))
        XCTAssertFalse(HiddenInput.isLineClass([]))
    }
}
