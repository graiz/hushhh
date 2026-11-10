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
        let audio = tone(11, 0.1) + tone(0.5, 0) + tone(2, 0.1)
        let point = try! XCTUnwrap(settle(audio))
        XCTAssertGreaterThanOrEqual(point, 11 * rate)
        XCTAssertLessThanOrEqual(point, 11 * rate + rate / 2)
    }

    func testPauseIsFoundRelativeToTheStart() {
        // A pause at 1 s is before the start; the next one, 11 s after it, is found.
        let audio = tone(1, 0.1) + tone(0.5, 0) + tone(11, 0.1) + tone(0.5, 0) + tone(2, 0.1)
        let start = rate + rate / 4
        let point = try! XCTUnwrap(settle(audio, from: start))
        XCTAssertGreaterThanOrEqual(point, Int(12.5 * Double(rate)))
        XCTAssertLessThanOrEqual(point, 13 * rate)
    }

    func testPauseTooEarlyIsIgnored() {
        // Under 10 s in: a segment that short would give the engine too little context.
        let audio = tone(9, 0.1) + tone(0.5, 0) + tone(3, 0.1)
        XCTAssertNil(settle(audio))
    }

    func testPauseTooCloseToTheEndIsIgnored() {
        // The pause ends 0.5 s before the end of the recording.
        let audio = tone(11, 0.1) + tone(0.5, 0) + tone(0.5, 0.1)
        XCTAssertNil(settle(audio))
    }

    func testShortGapIsNotAPause() {
        let audio = tone(11, 0.1) + tone(0.2, 0) + tone(3, 0.1)
        XCTAssertNil(settle(audio))
    }

    func testSoftSpeechIsNotAPause() {
        // 0.02 is above 0.15 × 0.1, so it's speech, not a pause.
        let audio = tone(11, 0.1) + tone(0.5, 0.02) + tone(2, 0.1)
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

    func testJoinKeepsRealSentenceEnds() {
        XCTAssertEqual(SpeechSegmenter.join("It tries to match the font.", "That helps."),
                       "It tries to match the font. That helps.")
        XCTAssertEqual(SpeechSegmenter.join("Is it on?", "yes it is."), "Is it on? yes it is.")
        XCTAssertEqual(SpeechSegmenter.join("Wait!", "then go."), "Wait! then go.")
    }

    func testJoinDropsAStopWhereTheNextSegmentCarriesOn() {
        // A segment ends at a pause, and the engine ends it with a full stop. A next segment
        // that starts in lowercase shows the sentence went on.
        XCTAssertEqual(SpeechSegmenter.join("It tries to match the font.", "so that when you finish"),
                       "It tries to match the font so that when you finish")
        XCTAssertEqual(SpeechSegmenter.join("Or if you want to hit escape.", "which would clear the text."),
                       "Or if you want to hit escape which would clear the text.")
        XCTAssertEqual(SpeechSegmenter.join("It gives you a...", "view of what things will look like."),
                       "It gives you a view of what things will look like.")
        XCTAssertEqual(SpeechSegmenter.join("Wait…", "then go."), "Wait then go.")
    }

    func testJoinDropsAStopAfterAWordThatCantEndASentence() {
        XCTAssertEqual(SpeechSegmenter.join("So you're not just staring at.", "Talking bubble."),
                       "So you're not just staring at talking bubble.")
        XCTAssertEqual(SpeechSegmenter.join("The last couple runs of.", "The Cadence application."),
                       "The last couple runs of the Cadence application.")
        XCTAssertEqual(SpeechSegmenter.join("It was the.", "I think."), "It was the I think.")
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

    // MARK: engine markers

    func testUnknownWordMarkersAreRemoved() {
        XCTAssertEqual(SpeechSegmenter.withoutUnknownMarkers("Great seeing you in Boston<unk> really appreciate it."),
                       "Great seeing you in Boston really appreciate it.")
        XCTAssertEqual(SpeechSegmenter.withoutUnknownMarkers("<unk> Hello <unk>, there<unk>"), "Hello, there")
        XCTAssertEqual(SpeechSegmenter.withoutUnknownMarkers("Plain text."), "Plain text.")
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

    func testAShortAllCapsSegmentIsOrdinaryWords() {
        // The engine sometimes returns a short segment in capitals; its words are ordinary.
        XCTAssertEqual(SpeechSegmenter.fixingAllCaps("THE NEW HUSH"), "The new hush")
        XCTAssertEqual(SpeechSegmenter.fixingAllCaps("AS YOU'RE SPEAKING"), "As you're speaking")
        XCTAssertEqual(SpeechSegmenter.fixingAllCaps("YES LET'S"), "Yes let's")
        XCTAssertEqual(SpeechSegmenter.fixingAllCaps("PROGRAM"), "Program")
        // Acronyms the person uses come back through Custom Words.
        XCTAssertEqual(SpeechSegmenter.fixingAllCaps("TALK TO THE FBI"), "Talk to the fbi")
    }

    func testALongRunInCapitalsBecomesSentenceCase() {
        // A longer segment can come back mostly in capitals, with a stray lowercase letter.
        XCTAssertEqual(SpeechSegmenter.fixingAllCaps("AND MANY ANGELS WILL AVOID AN LLC StRUCTURE THIS ISN'T TO SAY"),
                       "And many angels will avoid an llc structure this isn't to say")
        // Inside ordinary text it continues the sentence around it.
        XCTAssertEqual(SpeechSegmenter.fixingAllCaps("Number one, AND MANY ANGELS WILL AVOID THEM today."),
                       "Number one, and many angels will avoid them today.")
        XCTAssertEqual(SpeechSegmenter.fixingAllCaps("It works. I THINK SO. WE WILL GO NOW"),
                       "It works. I think so. We will go now")
    }

    func testAFewCapitalWordsInOrdinaryTextAreKept() {
        XCTAssertEqual(SpeechSegmenter.fixingAllCaps("We use NASA FBI and CIA data."), "We use NASA FBI and CIA data.")
        XCTAssertEqual(SpeechSegmenter.fixingAllCaps("Tell the FBI CIA NSA USA today."), "Tell the FBI CIA NSA USA today.")
    }

    func testASingleShortAllCapsWordIsKept() {
        XCTAssertEqual(SpeechSegmenter.fixingAllCaps("OK"), "OK")
        XCTAssertEqual(SpeechSegmenter.fixingAllCaps("FBI."), "FBI.")
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

    /// A voiced sound, like a vowel: a 150 Hz sine.
    private func voice(_ seconds: Double, _ amplitude: Float) -> [Float] {
        (0..<Int(seconds * Double(rate))).map { amplitude * sin(2 * .pi * 150 * Float($0) / Float(rate)) }
    }

    private func quiet(_ audio: [Float], peak: Float = 0.1) -> Bool {
        TranscriptTail.isQuiet(audio[...], sampleRate: rate, speechPeakRMS: peak)
    }

    func testQuietByTheRelativeRule() {
        // Room noise above the floor, but far under the speech level.
        XCTAssertTrue(quiet(voice(1, 0.006)))
        // Half a second of voice at speech level is speech.
        XCTAssertFalse(quiet(tone(0.5, 0) + voice(0.5, 0.05)))
        XCTAssertTrue(quiet([]))
    }

    func testKeyClickAtTheEndIsStillQuiet() {
        // The key that finishes a dictation clicks for about 30 ms, after seconds of silence.
        let quiet = quiet(tone(3, 0.0008) + tone(0.03, 0.04), peak: 0.026)
        XCTAssertTrue(quiet)
        // So "Thank you." made up from it is dropped.
        XCTAssertEqual(SpeechSegmenter.kept("Thank you.", regionIsQuiet: quiet), "")
    }

    func testTapsAndBreathsInAPauseAreQuiet() {
        // A soft speaker (peak 0.02) pausing: taps and clicks as loud as speech, and short
        // voiced bits, but under 200 ms of voice in all. The engine hears "Thank you." there.
        var pause = tone(0.5, 0.0006)
        for _ in 0..<4 { pause += tone(0.06, 0.04) + voice(0.04, 0.03) + tone(0.4, 0.0006) }
        XCTAssertTrue(quiet(pause, peak: 0.02))
    }

    func testADictationWithNoSpeechIsQuiet() {
        // Nothing said: the session's loudest is room noise (about 0.006), with a hum that
        // is voiced and over the relative threshold. The engine hears "Thank you." in it.
        let noise = tone(0.3, 0.004) + voice(0.3, 0.016) + tone(1.7, 0.004)
        XCTAssertTrue(quiet(noise, peak: 0.0063))
    }

    func testAShortPhraseIsSpeech() {
        // "Thank you", softly: about 400 ms of voice.
        XCTAssertFalse(quiet(tone(1, 0.0006) + voice(0.4, 0.01) + tone(1, 0.0006), peak: 0.02))
    }
}
