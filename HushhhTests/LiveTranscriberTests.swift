import XCTest

/// Drives `LiveTranscriber` with a fake engine over synthetic audio, so the settling and
/// finishing bookkeeping is checked without a model or real time.
final class LiveTranscriberTests: XCTestCase {
    private let rate = LiveTranscriber.sampleRate

    private func tone(_ seconds: Double, _ amplitude: Float) -> [Float] {
        // A 160 Hz square wave: the RMS of any window is exactly `amplitude`, and it's voiced
        // like speech (few zero crossings), so it isn't mistaken for clicks.
        (0..<Int(seconds * Double(rate))).map { ($0 / 50) % 2 == 0 ? amplitude : -amplitude }
    }
    private func word(_ name: String, _ seconds: Double = 1) -> [Float] {
        tone(seconds, FakeEngine.amplitudes[name]!)
    }
    private func quiet(_ seconds: Double) -> [Float] { tone(seconds, 0) }

    /// "alpha bravo", a pause, "charlie delta", a pause, then "echo" and quiet.
    private func threeSegments() -> [Float] {
        let parts: [[Float]] = [
            word("alpha"), quiet(0.2), word("bravo"), quiet(0.6),
            word("charlie"), quiet(0.2), word("delta"), quiet(0.6),
            word("echo", 0.4), quiet(1.5),
        ]
        return parts.flatMap { $0 }
    }

    private func transcriber(_ engine: FakeEngine, audio: [Float]) -> LiveTranscriber {
        let live = LiveTranscriber(engineProvider: { engine })
        live.append(audio, level: 1)
        return live
    }

    // MARK: settling while the partials stop

    func testSegmentSettledWhileStoppingIsNeitherLostNorDuplicated() async {
        // Two pauses: the first segment settles before the keypress, the second while
        // `stopPartials()` waits for its pass.
        let audio = threeSegments()
        let engine = FakeEngine()
        engine.holdCall = 1
        let live = transcriber(engine, audio: audio)
        live.start()

        await engine.waitUntilHeld()
        let settled = live.settledSnapshot()
        XCTAssertEqual(settled.text, "alpha bravo")
        await live.stopPartials()
        XCTAssertGreaterThan(live.settledSnapshot().upTo, settled.upTo, "the second segment settles during the stop")

        // The newest partial predates that settle, so the rest needs the final pass.
        XCTAssertNil(live.quietRest(after: settled.upTo))
        let rest = await live.transcribeRest(after: settled.upTo)
        XCTAssertEqual(SpeechSegmenter.join(settled.text, rest), "alpha bravo charlie delta echo")
    }

    func testRestAfterASettledSnapshotHasEveryWordOnce() async throws {
        let audio = threeSegments()
        let engine = FakeEngine()
        let live = transcriber(engine, audio: audio)
        let first = live.settledSnapshot()
        _ = await live.update(with: engine)

        // Everything settled after the snapshot, plus the live part, without the first part.
        let rest = try XCTUnwrap(live.quietRest(after: first.upTo))
        XCTAssertEqual(SpeechSegmenter.join(first.text, rest), "alpha bravo charlie delta echo")
        let latest = live.settledSnapshot()
        XCTAssertEqual(latest.text, "alpha bravo charlie delta")
        XCTAssertEqual(live.quietRest(after: latest.upTo), "echo")
    }

    // MARK: empty passes

    func testSoundThatNeverGivesWordsIsSettledAsNothingAfter25s() async {
        // 2.5 s of sound the engine finds no words in, then a pause, ten times over.
        var audio: [Float] = []
        for _ in 0..<10 { audio += word("mumble", 2.5) + quiet(0.5) }
        let engine = FakeEngine()
        let live = transcriber(engine, audio: audio)
        _ = await live.update(with: engine)

        let settled = live.settledSnapshot()
        XCTAssertEqual(settled.text, "")
        XCTAssertGreaterThan(settled.upTo, 25 * rate)

        // Words after it are still transcribed, and only the new audio is passed.
        live.append(word("alpha") + quiet(1.5), level: 1)
        _ = await live.update(with: engine)
        XCTAssertEqual(live.quietRest(after: settled.upTo), "alpha")
        XCTAssertLessThan(engine.lastInputCount, 10 * rate)
    }

    func testEmptyPassUnderTheLimitStaysLive() async {
        // A segment the engine finds no words in, then more speech: it isn't settled as
        // nothing, so the final pass still covers it.
        let audio = word("mumble", 2.5) + quiet(0.6) + word("alpha") + quiet(1.5)
        let engine = FakeEngine()
        let live = transcriber(engine, audio: audio)
        _ = await live.update(with: engine)
        XCTAssertEqual(live.settledSnapshot().upTo, 0)
        XCTAssertEqual(live.quietRest(after: 0), "alpha")
    }

    // MARK: finishing

    func testTailUnderTheFloorTakesTheFastPath() async {
        let engine = FakeEngine()
        let live = transcriber(engine, audio: word("alpha") + quiet(0.2) + word("bravo") + quiet(0.3))
        _ = await live.update(with: engine)
        live.append(tone(0.5, 0.001), level: 1)

        let calls = engine.callCount
        XCTAssertEqual(live.quietRest(after: 0), "alpha bravo")
        XCTAssertEqual(live.finalPartial(), "alpha bravo")
        XCTAssertEqual(engine.callCount, calls, "no final pass")
    }

    func testSoftTailAboveTheFloorRunsTheFinalPass() async {
        let engine = FakeEngine()
        let live = transcriber(engine, audio: word("alpha") + quiet(0.2) + word("bravo") + quiet(0.3))
        _ = await live.update(with: engine)
        // Far softer than the rest of the session, but above the absolute floor.
        live.append(word("soft", 0.3) + quiet(0.2), level: 1)

        XCTAssertNil(live.quietRest(after: 0))
        XCTAssertNil(live.finalPartial())
        let rest = await live.transcribeRest(after: 0)
        XCTAssertEqual(rest, "alpha bravo soft")
    }
}

/// Finds "words" in synthetic audio: each run of sound is one word, named by its
/// amplitude. Sound at an amplitude it doesn't know ("mumble") gives no word.
private final class FakeEngine: SpeechEngine, @unchecked Sendable {
    static let amplitudes: [String: Float] = [
        "alpha": 0.2, "bravo": 0.25, "charlie": 0.3, "delta": 0.35, "echo": 0.4,
        "soft": 0.01, "mumble": 0.05,
    ]
    private static let names: [String: Float] = amplitudes.filter { $0.key != "mumble" }

    var displayName: String { "Fake" }
    /// The call (counting from 0) that waits until the live loop is cancelled.
    var holdCall: Int?

    private let lock = NSLock()
    private var calls = 0
    private var inputCount = 0
    private let held = Gate()

    var callCount: Int { lock.withLock { calls } }
    var lastInputCount: Int { lock.withLock { inputCount } }

    func load() async throws {}

    func transcribe(_ samples: [Float]) async -> String {
        let index = lock.withLock { () -> Int in
            calls += 1
            inputCount = samples.count
            return calls - 1
        }
        if index == holdCall {
            held.open()
            let cancelled = Gate()
            await withTaskCancellationHandler {
                await cancelled.wait()
            } onCancel: {
                cancelled.open()
            }
        }
        return Self.words(in: samples)
    }

    func waitUntilHeld() async { await held.wait() }

    private static func words(in samples: [Float]) -> String {
        var words: [String] = []
        var inRun = false
        for s in samples {
            let level = abs(s)
            if level > 0.002, !inRun {
                inRun = true
                if let name = names.first(where: { abs($0.value - level) < 0.004 })?.key { words.append(name) }
            } else if level <= 0.002 {
                inRun = false
            }
        }
        return words.joined(separator: " ")
    }
}

/// Resumes every waiter once opened, including ones that arrive later.
private final class Gate: @unchecked Sendable {
    private let lock = NSLock()
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func open() {
        let waiting = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
            isOpen = true
            defer { waiters = [] }
            return waiters
        }
        waiting.forEach { $0.resume() }
    }

    func wait() async {
        await withCheckedContinuation { continuation in
            let resumeNow = lock.withLock { () -> Bool in
                if isOpen { return true }
                waiters.append(continuation)
                return false
            }
            if resumeNow { continuation.resume() }
        }
    }
}
