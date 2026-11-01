import Foundation

/// Buffers microphone audio and transcribes it while the person speaks, so the
/// preview fills in live. Speech up to a natural pause is transcribed once and
/// settled; each update and the final pass cover only the audio since then, so
/// they stay fast however long the dictation runs.
final class LiveTranscriber {
    private let engineProvider: () async throws -> SpeechEngine
    /// The person's list of terms, applied to every pass.
    private let customWords: CustomWords
    private let lock = NSLock()
    private var samples: [Float] = []
    private var peakLevel: Float = 0
    private var loop: Task<Void, Never>?
    private var engine: SpeechEngine?
    /// Transcripts of the audio up to each settled pause, in order, as the engine
    /// returned them, with the sample index each one ends at.
    private var segments: [(text: String, end: Int)] = []
    /// `segments` joined into one transcript.
    private var settledText = ""
    /// Where the live region starts: the end of the last settled segment.
    private var settledUpTo = 0
    /// Where to look for the next cut, past a segment whose pass came back empty, so
    /// that segment is retried as part of a longer one instead of being settled as nothing.
    /// An empty pass over audio that is quiet by the relative rule, or over a segment
    /// longer than 25 s, is settled as nothing instead.
    private var retryFrom = 0
    /// How much of the recording the newest update saw, so the next one waits for new
    /// audio. Used only by the live loop.
    private var updatedCount = 0
    /// The newest partial: the whole transcript up to `covered`, its live part, and
    /// where the live part started.
    private var latest: (text: String, live: String, covered: Int, liveFrom: Int) = ("", "", 0, 0)
    /// This session's speech level, kept up to date in `append` so an update doesn't rescan
    /// the whole recording. Its robust peak sets the relative quiet rule, which only picks
    /// cut points and judges filler phrases; audio is left untranscribed, and a tail
    /// counts as nothing new at the finish, only when it is under the absolute floor.
    private var speechPeak = WindowedPeak(windowSize: TranscriptTail.windowSize(sampleRate: sampleRate))

    /// Delivered on the main actor.
    var onPartial: (@MainActor (String) -> Void)?
    var onError: (@MainActor (Error) -> Void)?
    /// A segment was settled: its transcript and the sample index it ends at.
    var onSettle: (@MainActor (String, Int) -> Void)?

    static let sampleRate = 16_000
    /// Re-run only once this much new audio has arrived.
    private static let minNewSamples = sampleRate * 3 / 10
    /// The engine's shortest input.
    private static let minSamples = sampleRate / 4
    /// Below this, the recording is treated as silence (avoids hallucinated text).
    private static let silenceThreshold: Float = 0.02

    init(customWords: CustomWords = CustomWords([]), engineProvider: @escaping () async throws -> SpeechEngine) {
        self.customWords = customWords
        self.engineProvider = engineProvider
    }

    func append(_ chunk: [Float], level: Float) {
        lock.lock()
        samples.append(contentsOf: chunk)
        speechPeak.add(chunk[...])
        peakLevel = max(peakLevel, level)
        lock.unlock()
    }

    /// The whole recording so far, copied.
    func recording() -> [Float] {
        lock.withLock { samples }
    }

    /// The audio from `start` on, copied so a pass doesn't hold the whole recording.
    private func region(from start: Int) -> (audio: [Float], total: Int, peak: Float, speechPeak: Float) {
        lock.lock(); defer { lock.unlock() }
        let start = min(start, samples.count)
        return (Array(samples[start...]), samples.count, peakLevel, speechPeak.robustRMS)
    }

    /// The transcript settled so far and the sample index it covers, so it can be
    /// inserted before the last stretch is finished.
    func settledSnapshot() -> (text: String, upTo: Int) {
        lock.lock(); defer { lock.unlock() }
        return (settledText, settledUpTo)
    }

    /// The newest partial, if the audio after it (and the last 100 ms) is quiet, so a
    /// final pass would add nothing. Call after `stopPartials()`, so no pass is in flight.
    func finalPartial() -> String? {
        lock.lock(); defer { lock.unlock() }
        guard tailIsQuiet() else { return nil }
        return latest.text
    }

    /// The transcript of everything after `upTo` (a `settledSnapshot()` index), if the
    /// newest partial covers it all and the audio after it is quiet. Call after
    /// `stopPartials()`.
    func quietRest(after upTo: Int) -> String? {
        lock.lock(); defer { lock.unlock() }
        // A segment settled after the newest partial, so its live part is out of date.
        guard latest.liveFrom == settledUpTo, tailIsQuiet() else { return nil }
        return SpeechSegmenter.join(settledText(after: upTo), latest.live)
    }

    /// Whether the audio after the newest partial is under the absolute floor, so a soft
    /// last word still gets the final pass. Call with `lock` held.
    private func tailIsQuiet() -> Bool {
        TranscriptTail.partialIsFinal(recording: samples[...], coveredSamples: latest.covered,
                                      sampleRate: Self.sampleRate)
    }

    /// The settled segments that end after `upTo`, joined. Call with `lock` held.
    private func settledText(after upTo: Int) -> String {
        segments.filter { $0.end > upTo }.reduce("") { SpeechSegmenter.join($0, $1.text) }
    }

    func start() {
        loop = Task { [weak self] in
            guard let self else { return }
            do {
                self.engine = try await self.engineProvider()
            } catch {
                await MainActor.run { self.onError?(error) }
                return
            }
            while !Task.isCancelled, let engine = self.engine {
                if await !self.update(with: engine) {
                    try? await Task.sleep(nanoseconds: 100_000_000)
                }
            }
        }
    }

    /// One live update: settles the audio up to each finished pause, then transcribes the
    /// live region and publishes the partial. Returns false, doing nothing, until enough
    /// new audio has arrived. The live loop calls it, and tests drive it directly.
    func update(with engine: SpeechEngine) async -> Bool {
        let (count, peak) = lock.withLock { (samples.count, peakLevel) }
        guard count >= Self.minSamples, count - updatedCount >= Self.minNewSamples,
              peak >= Self.silenceThreshold else { return false }
        var from = lock.withLock { settledUpTo }
        let snapshot = region(from: from)
        var audio = snapshot.audio
        let speechPeak = snapshot.speechPeak
        updatedCount = snapshot.total

        // Settle the audio up to each finished pause, once.
        var searchFrom = max(0, lock.withLock { retryFrom } - from)
        while let point = SpeechSegmenter.settlePoint(recording: audio[...], from: searchFrom,
                                                      sampleRate: Self.sampleRate,
                                                      speechPeakRMS: speechPeak) {
            let segment = audio[..<point]
            let silent = TranscriptTail.isSilent(segment, sampleRate: Self.sampleRate)
            let pass = silent ? nil : await self.transcribe(Array(segment), with: engine, padded: false,
                                                            speechPeak: speechPeak)
            let text = pass?.text ?? ""
            // Silence, a filler phrase or an empty pass from quiet audio, and a segment over
            // 25 s with no words are settled as nothing.
            let retries = text.isEmpty && !silent && !(pass?.onlyNoise ?? false)
                && !SpeechSegmenter.settlesWhenEmpty(segmentSamples: point, sampleRate: Self.sampleRate)
            if retries {
                // Nothing came back for audio with sound in it: keep it live, so a
                // longer segment or the final pass covers it.
                searchFrom = point
                let retry = from + point
                lock.withLock { retryFrom = retry }
                if Task.isCancelled { return true }
                continue
            }
            from += point
            let end = from
            lock.withLock {
                segments.append((text, end))
                settledText = SpeechSegmenter.join(settledText, text)
                settledUpTo = end
                retryFrom = end
            }
            audio = Array(audio[point...])
            searchFrom = 0
            if !text.isEmpty { await MainActor.run { self.onSettle?(text, end) } }
            if Task.isCancelled { return true }
        }

        // Then the live region since the last pause. Only audio under the
        // absolute floor is skipped, so the engine isn't asked to find words in hiss.
        let settled = lock.withLock { settledText }
        let long = audio.count >= Self.minSamples
        let live = long && !TranscriptTail.isSilent(audio[...], sampleRate: Self.sampleRate)
            ? await self.transcribe(audio, with: engine, padded: true, speechPeak: speechPeak).text : ""
        let text = SpeechSegmenter.join(settled, live)
        // Kept even when cancelled mid-pass, so the finish can use it. An engine can return
        // nothing when cancelled, so an empty cancelled pass doesn't count as covering the
        // audio: the finish then transcribes it.
        let liveFrom = from
        let covered = long && !(Task.isCancelled && live.isEmpty) ? liveFrom + audio.count : liveFrom
        lock.withLock { latest = (text, live, covered, liveFrom) }
        if Task.isCancelled { return true }
        await MainActor.run { self.onPartial?(text) }
        return true
    }

    /// Stops the live loop and returns the settled segments as they were transcribed,
    /// followed by a final pass over the live region.
    func finish() async -> String {
        await stopPartials()
        return await transcribeAll()
    }

    /// Stops the live loop and returns the newest partial when nothing was said after
    /// it, so the person doesn't wait for a pass that would add nothing.
    func finishFast() async -> String {
        await stopPartials()
        if let text = finalPartial() { return text }
        return await transcribeAll()
    }

    /// Stops the live loop and waits for an in-flight partial, which can take one
    /// partial's time. Audio keeps buffering until the recorder stops.
    func stopPartials() async {
        let running = loop
        running?.cancel()
        await running?.value
    }

    /// The final pass: the settled transcript plus the live region, transcribed now.
    func transcribeAll() async -> String {
        await transcribeRest(after: 0)
    }

    /// The transcript of everything after `upTo` (a `settledSnapshot()` index): the
    /// segments settled since, then the live region, transcribed now.
    func transcribeRest(after upTo: Int) async -> String {
        if engine == nil {
            // The model was still loading when the person finished speaking.
            engine = try? await engineProvider()
        }
        let (settled, from) = lock.withLock { (settledText(after: upTo), settledUpTo) }
        let (audio, _, peak, speechPeak) = region(from: from)
        guard let engine, peak >= Self.silenceThreshold, audio.count >= Self.minSamples,
              !TranscriptTail.isSilent(audio[...], sampleRate: Self.sampleRate) else { return settled }
        let pass = await self.transcribe(audio, with: engine, padded: true, speechPeak: speechPeak)
        return SpeechSegmenter.join(settled, pass.text)
    }

    /// A settled segment ends inside a pause. The live region often stops right at the
    /// last word, so Hushhh adds the silence a pause would give it; a word that ends the
    /// audio is then transcribed as cleanly as one before a pause. Each pass's text is
    /// put in sentence case if it came back all in capitals. A filler phrase ("Thanks for
    /// watching.") from audio that is quiet by the relative rule is dropped, since nothing
    /// was said there; louder audio keeps every word. Then misheard terms from the person's
    /// list are corrected.
    private func transcribe(_ audio: [Float], with engine: SpeechEngine, padded: Bool,
                            speechPeak: Float) async -> (text: String, onlyNoise: Bool) {
        let input = padded ? audio + [Float](repeating: 0, count: Self.trailingSilence) : audio
        let output = SpeechSegmenter.fixingAllCaps(await engine.transcribe(input))
        let quiet = TranscriptTail.isQuiet(audio[...], sampleRate: Self.sampleRate, speechPeakRMS: speechPeak)
        // An empty pass over quiet audio counts too: there was only noise to transcribe.
        return (customWords.correct(SpeechSegmenter.kept(output, regionIsQuiet: quiet)),
                quiet && SpeechSegmenter.isFiller(output))
    }
    private static let trailingSilence = sampleRate * 2 / 5

    func cancel() {
        loop?.cancel()
        loop = nil
    }
}
