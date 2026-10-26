import XCTest

final class RefineScheduleTests: XCTestCase {
    func testFirstSessionGetsEveryLook() {
        let looks = RefineSchedule.pending(after: 0)
        XCTAssertEqual(looks.map(\.delay), [0.8, 1.6, 2.5, 3.5])
        XCTAssertEqual(looks.map(\.wait), [0.8, 1.6, 2.5, 3.5])
    }

    func testLaterSessionGetsOnlyLooksStillAhead() {
        let looks = RefineSchedule.pending(after: 1.0)
        XCTAssertEqual(looks.map(\.delay), [1.6, 2.5, 3.5])
        XCTAssertEqual(looks.map(\.wait)[0], 0.6, accuracy: 1e-9)
        XCTAssertEqual(looks.map(\.wait)[2], 2.5, accuracy: 1e-9)
    }

    func testNothingLeftOnceTheLastLookHasPassed() {
        XCTAssertTrue(RefineSchedule.pending(after: 3.5).isEmpty)
        XCTAssertTrue(RefineSchedule.pending(after: 10).isEmpty)
    }
}
