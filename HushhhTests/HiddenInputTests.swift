import XCTest

final class HiddenInputTests: XCTestCase {
    func testTinyInputIsHidden() {
        XCTAssertTrue(HiddenInput.isHidden(CGRect(x: 100, y: 200, width: 1, height: 18)))
        XCTAssertTrue(HiddenInput.isHidden(CGRect(x: 100, y: 200, width: 300, height: 1)))
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
    func testSettledWhenTheInputStopsMoving() {
        XCTAssertTrue(HiddenInput.isSettled(CGRect(x: 100, y: 200, width: 1, height: 18), CGRect(x: 100.2, y: 200, width: 1, height: 18)))
        XCTAssertFalse(HiddenInput.isSettled(CGRect(x: 100, y: 200, width: 1, height: 18), CGRect(x: 108, y: 200, width: 1, height: 18)))
    }
    func testLineClasses() {
        XCTAssertTrue(HiddenInput.isLineClass(["view-line"]))
        XCTAssertTrue(HiddenInput.isLineClass(["CodeMirror-line", "other"]))
        XCTAssertTrue(HiddenInput.isLineClass(["ace_line"]))
        XCTAssertTrue(HiddenInput.isLineClass(["cm-line"]))
        XCTAssertFalse(HiddenInput.isLineClass(["view-lines"]))
        XCTAssertFalse(HiddenInput.isLineClass([]))
    }
}
