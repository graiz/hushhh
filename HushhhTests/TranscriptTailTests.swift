import XCTest

final class TranscriptTailTests: XCTestCase {
    private let rate = 16_000

    private func tone(_ seconds: Double, _ amplitude: Float) -> [Float] {
        // Alternating sign, so the RMS of any window is exactly `amplitude`.
        (0..<Int(seconds * Double(rate))).map { $0 % 2 == 0 ? amplitude : -amplitude }
    }

    private func decide(speech: [Float], tail: [Float], peak: Float = 0) -> Bool {
        TranscriptTail.partialIsFinal(recording: (speech + tail)[...], coveredSamples: speech.count,
                                      sampleRate: rate)
    }

    func testSoftWordInsideASilentTailIsNotFinal() {
        let tail = tone(0.5, 0) + tone(0.25, 0.015) + tone(0.45, 0)
        XCTAssertFalse(decide(speech: tone(1, 0.08), tail: tail, peak: 0.08))
    }
    func testShortLoudTailIsNotFinal() {
        XCTAssertFalse(decide(speech: tone(2, 0.1), tail: tone(0.2, 0.1), peak: 0.1))
    }
    func testStillTalkingAtTheKeypressIsNotFinalEvenWhenCovered() {
        // The partial covers everything, but the last 100 ms is speech.
        XCTAssertFalse(decide(speech: tone(1, 0) + tone(0.08, 0.1), tail: [], peak: 0.1))
    }
    func testQuietSecondAfterSpeechIsFinal() {
        XCTAssertTrue(decide(speech: tone(2, 0.1), tail: tone(1, 0.001), peak: 0.1))
    }
    func testSoftTrailingWordAboveTheFloorIsNotFinal() {
        // 0.01 is far under this session's loud speech, but above the absolute floor.
        XCTAssertFalse(decide(speech: tone(2, 0.3), tail: tone(0.3, 0) + tone(0.3, 0.01) + tone(0.2, 0)))
    }
    func testQuietSpeakerUsesTheFloor() {
        XCTAssertTrue(decide(speech: tone(2, 0.01), tail: tone(1, 0.0005), peak: 0.01))
        XCTAssertFalse(decide(speech: tone(2, 0.01), tail: tone(1, 0.006), peak: 0.01))
    }
    func testNoPartialYetIsNotFinal() {
        XCTAssertFalse(decide(speech: [], tail: tone(0.1, 0), peak: 0))
        XCTAssertFalse(decide(speech: [], tail: tone(2, 0), peak: 0.1))
    }
    func testWindowedPeakSpansChunks() {
        var peak = WindowedPeak(windowSize: 800)
        let silence = tone(0.05, 0), loud = tone(0.1, 0.2)
        for start in stride(from: 0, to: silence.count, by: 300) { peak.add(silence[start..<min(start + 300, silence.count)]) }
        for start in stride(from: 0, to: loud.count, by: 500) { peak.add(loud[start..<min(start + 500, loud.count)]) }
        XCTAssertEqual(peak.rms, 0.2, accuracy: 1e-5)
    }
}
