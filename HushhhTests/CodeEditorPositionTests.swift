import XCTest

final class CodeEditorPositionTests: XCTestCase {
    func testParsesStatus() {
        XCTAssertEqual(CodeEditorPosition.lineAndColumn(fromStatus: "Ln 32, Col 33")?.column, 33)
        XCTAssertEqual(CodeEditorPosition.lineAndColumn(fromStatus: "Ln 32, Col 33")?.line, 32)
        XCTAssertEqual(CodeEditorPosition.lineAndColumn(fromStatus: "Ln 4, Col 1 (12 selected)")?.column, 1)
        XCTAssertNil(CodeEditorPosition.lineAndColumn(fromStatus: "Spaces: 4"))
    }
    func testCaretX() {
        XCTAssertEqual(CodeEditorPosition.caretX(lineStartX: 289, column: 1, cellWidth: 7.2), 289)
        XCTAssertEqual(CodeEditorPosition.caretX(lineStartX: 289, column: 33, cellWidth: 7.25), 289 + 32 * 7.25, accuracy: 0.001)
    }
}
