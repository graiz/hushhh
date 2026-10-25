import XCTest

final class SpeechSegmenterTests: XCTestCase {
    private let rate = 16_000

    private func tone(_ seconds: Double, _ amplitude: Float) -> [Float] {
        // Alternating sign, so the RMS of any window is exactly `amplitude`.
        (0..<Int(seconds * Double(rate))).map { $0 % 2 == 0 ? amplitude : -amplitude }
    }

    private func settle(_ audio: [Float], from start: Int = 0, peak: Float = 0.1) -> Int? {
        SpeechSegmenter.settlePoint(recording: audio[...], from: start, sampleRate: rate, speechPeakRMS: peak)
    }

    // MARK: settlePoint

    func testPauseInTheMiddleSettlesInsideThePause() {
        let audio = tone(3, 0.1) + tone(0.5, 0) + tone(2, 0.1)
        let point = try! XCTUnwrap(settle(audio))
        XCTAssertGreaterThanOrEqual(point, 3 * rate)
        XCTAssertLessThanOrEqual(point, 3 * rate + rate / 2)
    }

    func testPauseIsFoundRelativeToTheStart() {
        // A pause at 1 s is before the start; the next one, 3 s after it, is found.
        let audio = tone(1, 0.1) + tone(0.5, 0) + tone(3, 0.1) + tone(0.5, 0) + tone(2, 0.1)
        let start = rate + rate / 4
        let point = try! XCTUnwrap(settle(audio, from: start))
        XCTAssertGreaterThanOrEqual(point, Int(4.5 * Double(rate)))
        XCTAssertLessThanOrEqual(point, 5 * rate)
    }

    func testPauseTooEarlyIsIgnored() {
        let audio = tone(1, 0.1) + tone(0.5, 0) + tone(3, 0.1)
        XCTAssertNil(settle(audio))
    }

    func testPauseTooCloseToTheEndIsIgnored() {
        // The pause ends 0.5 s before the end of the recording.
        let audio = tone(3, 0.1) + tone(0.5, 0) + tone(0.5, 0.1)
        XCTAssertNil(settle(audio))
    }

    func testShortGapIsNotAPause() {
        let audio = tone(3, 0.1) + tone(0.2, 0) + tone(3, 0.1)
        XCTAssertNil(settle(audio))
    }

    func testSoftSpeechIsNotAPause() {
        // 0.02 is above 0.15 × 0.1, so it's speech, not a pause.
        let audio = tone(3, 0.1) + tone(0.5, 0.02) + tone(2, 0.1)
        XCTAssertNil(settle(audio))
    }

    func testNoPauseUnderTheLimitIsNil() {
        XCTAssertNil(settle(tone(20, 0.1)))
    }

    func testNoPauseOverTheLimitSettlesInTheQuietestWindow() {
        // Loud speech throughout, with one softer dip at 12 s that isn't a full pause.
        let audio = tone(12, 0.1) + tone(0.1, 0.05) + tone(14, 0.1)
        let point = try! XCTUnwrap(settle(audio))
        XCTAssertGreaterThanOrEqual(point, 12 * rate)
        XCTAssertLessThanOrEqual(point, 12 * rate + rate / 10)
    }

    func testSafetyNetStaysInsideItsRange() {
        // The quietest audio is in the first 5 s, which the safety net skips.
        let audio = tone(1, 0.05) + tone(25, 0.1)
        let point = try! XCTUnwrap(settle(audio))
        XCTAssertGreaterThanOrEqual(point, 5 * rate)
        XCTAssertLessThanOrEqual(point, audio.count - rate)
    }

    func testSafetyNetLimitCountsFromTheLiveRegionStart() {
        // Looking from 10 s (past a segment that came back empty), the live region is
        // still over 25 s long, so the quietest window after the search start is used.
        let audio = tone(20, 0.1) + tone(0.1, 0.05) + tone(7, 0.1)
        let point = try! XCTUnwrap(settle(audio, from: 10 * rate))
        XCTAssertGreaterThanOrEqual(point, 20 * rate)
        XCTAssertLessThanOrEqual(point, 20 * rate + rate / 10)
    }

    func testSafetyNetCutsAtLeast5sPastTheSearchStart() {
        let audio = tone(1, 0.05) + tone(26, 0.1)
        let point = try! XCTUnwrap(settle(audio, from: 12 * rate))
        XCTAssertGreaterThanOrEqual(point, 17 * rate)
    }

    func testOnlyASegmentOverTheLimitIsSettledWhenEmpty() {
        XCTAssertFalse(SpeechSegmenter.settlesWhenEmpty(segmentSamples: 25 * rate, sampleRate: rate))
        XCTAssertTrue(SpeechSegmenter.settlesWhenEmpty(segmentSamples: 25 * rate + 1, sampleRate: rate))
    }

    // MARK: join

    func testJoinAfterASentenceEndKeepsTheCapital() {
        XCTAssertEqual(SpeechSegmenter.join("This is one.", "Here is two."), "This is one. Here is two.")
        XCTAssertEqual(SpeechSegmenter.join("Really?", "Yes."), "Really? Yes.")
    }

    func testJoinMidSentenceLowercasesTheNextWord() {
        XCTAssertEqual(SpeechSegmenter.join("This is one,", "And here is two."), "This is one, and here is two.")
        XCTAssertEqual(SpeechSegmenter.join("So we went", "To the shop."), "So we went to the shop.")
    }

    func testJoinKeepsIAndAllCapsWords() {
        XCTAssertEqual(SpeechSegmenter.join("And then", "I left."), "And then I left.")
        XCTAssertEqual(SpeechSegmenter.join("And then", "I'm gone."), "And then I'm gone.")
        XCTAssertEqual(SpeechSegmenter.join("And then", "I’ll go."), "And then I’ll go.")
        XCTAssertEqual(SpeechSegmenter.join("We use", "NASA data."), "We use NASA data.")
        XCTAssertEqual(SpeechSegmenter.join("Then", "It works."), "Then it works.")
    }

    func testJoinKeepsTheEnginesPunctuation() {
        XCTAssertEqual(SpeechSegmenter.join("Here is the second sentence.", "which keeps going."),
                       "Here is the second sentence. which keeps going.")
        XCTAssertEqual(SpeechSegmenter.join("Wait...", "then go."), "Wait... then go.")
    }

    func testJoinWithAnEmptySide() {
        XCTAssertEqual(SpeechSegmenter.join("", "Hello."), "Hello.")
        XCTAssertEqual(SpeechSegmenter.join("Hello.", ""), "Hello.")
        XCTAssertEqual(SpeechSegmenter.join(" Hello. ", " There. "), "Hello. There.")
    }

    // MARK: continuation

    func testContinuationAddsASpaceAndAdjustsTheCase() {
        XCTAssertEqual(SpeechSegmenter.continuation("And more.", after: "Some text,"), " and more.")
        XCTAssertEqual(SpeechSegmenter.continuation("More.", after: "Some text."), " More.")
    }

    func testContinuationAfterNothingIsUnchanged() {
        XCTAssertEqual(SpeechSegmenter.continuation("More.", after: ""), "More.")
    }

    func testContinuationAfterWhitespaceOrBeforePunctuationAddsNoSpace() {
        XCTAssertEqual(SpeechSegmenter.continuation("More.", after: "Text. "), "More.")
        XCTAssertEqual(SpeechSegmenter.continuation(", then more.", after: "Text"), ", then more.")
    }

    // MARK: all caps

    func testAllCapsTranscriptBecomesSentenceCase() {
        XCTAssertEqual(SpeechSegmenter.fixingAllCaps("WITHOUT ANY PAUSE AT THE VERY END"),
                       "Without any pause at the very end")
        XCTAssertEqual(SpeechSegmenter.fixingAllCaps("I THINK SO. I'M SURE! WE WILL GO"), "I think so. I'm sure! We will go")
    }

    func testOrdinaryTranscriptsAreUnchanged() {
        XCTAssertEqual(SpeechSegmenter.fixingAllCaps("We use NASA data."), "We use NASA data.")
        XCTAssertEqual(SpeechSegmenter.fixingAllCaps("NASA"), "NASA")
        XCTAssertEqual(SpeechSegmenter.fixingAllCaps("25 and 100."), "25 and 100.")
        XCTAssertEqual(SpeechSegmenter.fixingAllCaps(""), "")
    }

    func testShortAllCapsWordsInAShortTranscriptAreKept() {
        XCTAssertEqual(SpeechSegmenter.fixingAllCaps("FBI CIA"), "FBI CIA")
        XCTAssertEqual(SpeechSegmenter.fixingAllCaps("OK"), "OK")
        XCTAssertEqual(SpeechSegmenter.fixingAllCaps("OK, NASA."), "OK, NASA.")
        XCTAssertEqual(SpeechSegmenter.fixingAllCaps("TALK TO THE FBI"), "Talk to the fbi")
    }

    // MARK: robust peak and silence

    func testOneCoughDoesNotTurnSoftSpeechIntoPauses() {
        var peak = WindowedPeak(windowSize: TranscriptTail.windowSize(sampleRate: rate))
        let speech = tone(0.05, 0.5) + tone(8, 0.02)
        peak.add(speech[...])
        XCTAssertEqual(peak.rms, 0.5, accuracy: 1e-4)
        XCTAssertLessThan(peak.robustRMS, 0.03)
        XCTAssertGreaterThan(peak.robustRMS, 0.015)
        // With the robust peak, the soft speech isn't quiet, so nothing is cut inside it.
        XCTAssertNil(settle(speech, peak: peak.robustRMS))
    }

    func testSpeechAfterACoughIsTranscribed() {
        let speech = tone(0.05, 0.5) + tone(3, 0.02)
        XCTAssertFalse(TranscriptTail.isSilent(speech[...], sampleRate: rate))
        // A settled segment of soft speech alone is transcribed too.
        XCTAssertFalse(TranscriptTail.isSilent(tone(3, 0.02)[...], sampleRate: rate))
    }

    func testSoftLastPhraseIsNotSkipped() {
        // 0.005 is under 0.15 × 0.1, but above the absolute floor.
        let tail = tone(0.5, 0) + tone(1, 0.005)
        XCTAssertFalse(TranscriptTail.isSilent(tail[...], sampleRate: rate))
    }

    func testOnlyAudioUnderTheFloorIsSilent() {
        XCTAssertTrue(TranscriptTail.isSilent(tone(2, 0.002)[...], sampleRate: rate))
        XCTAssertTrue(TranscriptTail.isSilent([Float]()[...], sampleRate: rate))
    }

    func testRobustPeakFollowsMostlySpeech() {
        var peak = WindowedPeak(windowSize: TranscriptTail.windowSize(sampleRate: rate))
        peak.add(tone(1, 0)[...])
        peak.add(tone(3, 0.1)[...])
        XCTAssertEqual(peak.robustRMS, 0.1, accuracy: 0.015)
    }

    // MARK: filler phrases

    func testFillerPhrases() {
        for text in ["Thanks for watching.", "Thank you for watching!", "Thank you.", "thanks", "You",
                     "Bye.", "Please subscribe.", "Subtitles by the Amara.org community", "Music", "[Music]",
                     "", "...", " … "] {
            XCTAssertTrue(SpeechSegmenter.isFiller(text), text)
        }
    }

    func testRealSpeechIsNotFiller() {
        for text in ["Thank you for the update, I'll reply tomorrow.", "Thank you, Anna.", "You are right.",
                     "Watch the music video.", "25"] {
            XCTAssertFalse(SpeechSegmenter.isFiller(text), text)
        }
    }

    func testFillerIsDroppedOnlyFromQuietAudio() {
        XCTAssertEqual(SpeechSegmenter.kept("Thanks for watching.", regionIsQuiet: true), "")
        XCTAssertEqual(SpeechSegmenter.kept("Thanks for watching.", regionIsQuiet: false), "Thanks for watching.")
        XCTAssertEqual(SpeechSegmenter.kept("Call me later.", regionIsQuiet: true), "Call me later.")
    }

    func testQuietByTheRelativeRule() {
        // Room noise above the floor, but far under the speech level.
        XCTAssertTrue(TranscriptTail.isQuiet(tone(1, 0.006)[...], sampleRate: rate, speechPeakRMS: 0.1))
        XCTAssertFalse(TranscriptTail.isQuiet((tone(0.5, 0) + tone(0.1, 0.05))[...], sampleRate: rate,
                                              speechPeakRMS: 0.1))
        XCTAssertTrue(TranscriptTail.isQuiet([Float]()[...], sampleRate: rate, speechPeakRMS: 0.1))
    }
}
