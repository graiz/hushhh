import XCTest

final class MicrophoneChoiceTests: XCTestCase {
    /// A meter that heard `seconds` of a steady signal at `level` RMS.
    private func meter(_ level: Float, seconds: Double = 1) -> MicrophoneChoice.Meter {
        var meter = MicrophoneChoice.Meter()
        meter.add([Float](repeating: level, count: Int(seconds * 16_000)))
        return meter
    }

    func testOneMicrophoneIsChosenAtOnce() {
        XCTAssertEqual(MicrophoneChoice.choose([MicrophoneChoice.Meter()]), .init(index: 0, isConfident: false))
    }

    func testWaitsUntilThereIsEnoughAudio() {
        // 0.3 s ignored plus 0.4 s compared: 0.6 s isn't enough.
        XCTAssertNil(MicrophoneChoice.choose([meter(0.1, seconds: 0.6), meter(0.3, seconds: 0.6)]))
        XCTAssertEqual(MicrophoneChoice.choose([meter(0.1, seconds: 0.7), meter(0.3, seconds: 0.7)])?.index, 1)
    }

    func testClearlyLouderMicrophoneWins() {
        XCTAssertEqual(MicrophoneChoice.choose([meter(0.02), meter(0.05), meter(0.03)]), .init(index: 1, isConfident: true))
    }

    func testDefaultWinsNearTies() {
        XCTAssertEqual(MicrophoneChoice.choose([meter(0.04), meter(0.05)])?.index, 0)
    }

    func testWaitsForSpeech() {
        XCTAssertNil(MicrophoneChoice.choose([meter(0.001), meter(0.0012)]))
    }

    func testSpeechAtTheFloorCounts() {
        XCTAssertEqual(MicrophoneChoice.choose([meter(0.0008), meter(0.004)]), .init(index: 1, isConfident: true))
    }

    /// Measured: a virtual input with nothing routed to it (0.00001) beside a built-in
    /// microphone hearing a quiet room (0.00075).
    func testSilentDefaultLosesToOneHearingTheRoom() {
        XCTAssertEqual(MicrophoneChoice.choose([meter(0.00001, seconds: 0.7), meter(0.00075, seconds: 0.7)]),
                       .init(index: 1, isConfident: true))
    }

    func testSilentDefaultIsKeptWhenEveryMicrophoneIsSilent() {
        XCTAssertNil(MicrophoneChoice.choose([meter(0.00001), meter(0.00002)]))
    }

    func testGivesUpOnTheDefaultWithoutSpeech() {
        XCTAssertEqual(MicrophoneChoice.choose([meter(0.001, seconds: 3), meter(0.0012, seconds: 3)]), .init(index: 0, isConfident: false))
    }

    func testKeyClickAtTheStartIsIgnored() {
        var clicked = MicrophoneChoice.Meter()
        clicked.add([Float](repeating: 0.9, count: 3_000))   // a loud click in the first 0.19 s
        clicked.add([Float](repeating: 0.02, count: 13_000))
        XCTAssertEqual(MicrophoneChoice.choose([meter(0.05), clicked])?.index, 0)
    }

    func testMicrophoneStillStartingIsIgnored() {
        XCTAssertEqual(MicrophoneChoice.choose([meter(0.05), MicrophoneChoice.Meter()])?.index, 0)
    }
}
