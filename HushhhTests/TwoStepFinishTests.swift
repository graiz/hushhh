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

    // A full stop ending the first part is held back until the rest is known.

    func testHeldBackStopIsDroppedWhenTheRestCarriesOn() {
        XCTAssertEqual(TwoStepFinish.decide(firstPaste: " Hit escape", heldStop: ".", rest: "which clears it.",
                                            firstWasRead: true),
                       .pasteRest(" which clears it."))
        XCTAssertEqual(TwoStepFinish.decide(firstPaste: " Runs of", heldStop: ".", rest: "The app.", firstWasRead: true),
                       .pasteRest(" the app."))
    }

    func testHeldBackStopIsPastedBeforeANewSentence() {
        XCTAssertEqual(TwoStepFinish.decide(firstPaste: " Match the font", heldStop: ".", rest: "That helps.",
                                            firstWasRead: true),
                       .pasteRest(". That helps."))
    }

    func testHeldBackStopIsPastedWhenNothingFollows() {
        XCTAssertEqual(TwoStepFinish.decide(firstPaste: " Some text", heldStop: ".", rest: "", firstWasRead: true),
                       .pasteRest("."))
        XCTAssertEqual(TwoStepFinish.decide(firstPaste: " Some text", heldStop: ".", rest: "", firstWasRead: false),
                       .copy(" Some text."))
    }

    func testFirstPartsStopIsHeldBack() {
        for (text, kept, stop) in [("Match the font.", "Match the font", "."), ("It gives you a...", "It gives you a", "..."),
                                   ("Really?", "Really?", ""), ("Some text,", "Some text,", "")] {
            let held = SpeechSegmenter.holdingBackStop(text)
            XCTAssertEqual(held.text, kept, text)
            XCTAssertEqual(held.stop, stop, text)
        }
    }
}
