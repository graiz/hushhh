import XCTest

final class TwoStepFinishTests: XCTestCase {
    func testReadFirstPartGetsTheRestPastedAfterIt() {
        XCTAssertEqual(TwoStepFinish.decide(firstPaste: " Some text,", rest: "And more.", firstWasRead: true),
                       .pasteRest(" and more."))
    }

    func testReadFirstPartWithNoRestRestoresTheClipboard() {
        XCTAssertEqual(TwoStepFinish.decide(firstPaste: " Some text.", rest: "  ", firstWasRead: true),
                       .restoreClipboard)
    }

    func testUnreadFirstPartCopiesTheWholeDictation() {
        XCTAssertEqual(TwoStepFinish.decide(firstPaste: " Some text,", rest: "And more.", firstWasRead: false),
                       .copy(" Some text, and more."))
    }

    func testUnreadFirstPartWithNoRestCopiesTheFirstPart() {
        XCTAssertEqual(TwoStepFinish.decide(firstPaste: " Some text.", rest: "", firstWasRead: false),
                       .copy(" Some text."))
    }
}
