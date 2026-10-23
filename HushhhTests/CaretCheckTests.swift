import XCTest
import CoreGraphics

final class CaretCheckTests: XCTestCase {
    private let field = CGRect(x: 459, y: 300, width: 955, height: 38)

    func testNormalCaretInsideFieldIsPlausible() {
        XCTAssertTrue(CaretCheck.isPlausible(CGRect(x: 471, y: 310, width: 1, height: 18), in: field))
    }

    func testSlackEmptyBoxCaretIsRejected() {
        XCTAssertFalse(CaretCheck.isPlausible(CGRect(x: 471, y: 235, width: 1, height: 227), in: field))
    }

    func testTooShortOrTooTallCaretIsRejected() {
        XCTAssertFalse(CaretCheck.isPlausible(CGRect(x: 471, y: 310, width: 1, height: 2), in: field))
        XCTAssertFalse(CaretCheck.isPlausible(CGRect(x: 471, y: 310, width: 1, height: 90), in: nil))
    }

    func testNoFieldAcceptsLineHeightCaret() {
        XCTAssertTrue(CaretCheck.isPlausible(CGRect(x: 10, y: 10, width: 1, height: 18), in: nil))
    }

    func testSlackAroundFieldEdge() {
        // Field spans y 300...338; the caret's midpoint may sit 4 pt outside.
        XCTAssertTrue(CaretCheck.isPlausible(CGRect(x: 471, y: 288, width: 1, height: 18), in: field))
        XCTAssertFalse(CaretCheck.isPlausible(CGRect(x: 471, y: 281, width: 1, height: 18), in: field))
    }

    func testTallCaretCenteredOnTightFieldIsPlausible() {
        let tight = CGRect(x: 459, y: 300, width: 400, height: 18)
        XCTAssertTrue(CaretCheck.isPlausible(CGRect(x: 471, y: 295, width: 1, height: 28), in: tight))
    }
}
