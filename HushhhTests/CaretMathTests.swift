import AppKit
import XCTest

final class CaretMathTests: XCTestCase {
    func testOrdinaryCharacterBoxIsPlausible() {
        XCTAssertTrue(CaretMath.isPlausibleCharacterBox(CGRect(x: 100, y: 200, width: 7, height: 16), fontSize: 13))
    }
    func testWholeFieldBoxIsNot() {
        XCTAssertFalse(CaretMath.isPlausibleCharacterBox(CGRect(x: 100, y: 200, width: 300, height: 16), fontSize: 13))
    }
    func testCollapsedBoxIsNot() {
        XCTAssertFalse(CaretMath.isPlausibleCharacterBox(CGRect(x: 100, y: 200, width: 0, height: 16), fontSize: 13))
    }
    func testMissingBoxIsNot() {
        XCTAssertFalse(CaretMath.isPlausibleCharacterBox(.zero, fontSize: 13))
        XCTAssertFalse(CaretMath.isPlausibleCharacterBox(CGRect(x: 100, y: 200, width: 7, height: 0.5), fontSize: 13))
    }
    func testCaretXAddsTheMeasuredPrefix() {
        let font = NSFont(name: "Helvetica", size: 13)!
        let expected = 50 + ("Total: 42" as NSString).size(withAttributes: [.font: font]).width
        XCTAssertEqual(CaretMath.caretX(lineStartX: 50, prefix: "Total: 42", font: font, limit: 1000), expected, accuracy: 0.001)
    }
    func testCaretXStopsAtTheLimit() {
        let font = NSFont(name: "Helvetica", size: 13)!
        XCTAssertEqual(CaretMath.caretX(lineStartX: 50, prefix: String(repeating: "W", count: 200), font: font, limit: 300), 300)
    }

    func testCaretOnAnEmptyLastLineIsMovedBelowTheLineBreak() {
        // TextEdit at the end of a document that ends in a line break: the zero-length box
        // has the right x but sits on the line of the line break before it (Accessibility
        // coordinates, y grows downward).
        let lineBreak = CGRect(x: 595, y: 352, width: 138, height: 29)
        let zero = CGRect(x: 157, y: 352, width: 0, height: 29)
        XCTAssertEqual(CaretMath.caretAfterLineBreak(zeroLength: zero, lineBreak: lineBreak),
                       CGRect(x: 157, y: 381, width: 0, height: 29))
    }
    func testCaretAlreadyBelowTheLineBreakIsKept() {
        let lineBreak = CGRect(x: 595, y: 352, width: 138, height: 29)
        let zero = CGRect(x: 157, y: 381, width: 0, height: 29)
        XCTAssertEqual(CaretMath.caretAfterLineBreak(zeroLength: zero, lineBreak: lineBreak), zero)
        XCTAssertEqual(CaretMath.caretAfterLineBreak(zeroLength: zero, lineBreak: nil), zero)
    }
}
