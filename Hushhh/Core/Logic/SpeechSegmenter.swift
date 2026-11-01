import Foundation

/// Splits a recording at natural pauses, so speech before a pause is transcribed once
/// and later passes only cover the audio since then.
enum SpeechSegmenter {
    /// A pause is at least this many quiet 50 ms windows in a row.
    private static let pauseWindows = 6
    /// A segment holds at least 2 s, so each pass has enough context to transcribe well.
    private static let minSegmentSeconds = 2
    /// The newest second stays live, since a pause there may just be a breath.
    private static let liveSeconds = 1
    /// Past this without a pause, settle anyway, so a pass never grows without bound.
    private static let maxSegmentSeconds = 25
    /// The safety net doesn't cut a segment shorter than this.
    private static let minForcedSegmentSeconds = 5

    /// Where to settle the audio, looking from `start`: the middle of the earliest pause
    /// at least 2 s after `start` that ends at least 1 s before the end of `recording`.
    /// Without a pause, once `recording` (the live region, from its first index) is over
    /// 25 s long, it's the quietest 50 ms window from 5 s after `start` to 1 s before the
    /// end. `start` is past the live region's start when a segment there came back empty;
    /// the 25 s still counts from the region's start, so a retried segment is cut in time.
    /// Indices are `recording`'s own.
    static func settlePoint(recording: ArraySlice<Float>, from start: Int, sampleRate: Int,
                            speechPeakRMS: Float) -> Int? {
        let window = TranscriptTail.windowSize(sampleRate: sampleRate)
        let start = max(start, recording.startIndex)
        let end = recording.endIndex - liveSeconds * sampleRate
        guard window > 0, end > start else { return nil }
        let threshold = TranscriptTail.quietThreshold(speechPeakRMS: speechPeakRMS)

        var runStart: Int?
        var index = start + minSegmentSeconds * sampleRate
        while index + window <= end {
            let quiet = TranscriptTail.rms(recording[index..<index + window]) < threshold
            if quiet {
                if runStart == nil { runStart = index }
            } else if let first = runStart {
                if (index - first) / window >= pauseWindows { return (first + index) / 2 }
                runStart = nil
            }
            index += window
        }
        if let first = runStart, (index - first) / window >= pauseWindows { return (first + index) / 2 }

        guard recording.endIndex - recording.startIndex > maxSegmentSeconds * sampleRate else { return nil }
        var quietest: (index: Int, rms: Float)?
        index = start + minForcedSegmentSeconds * sampleRate
        while index + window <= end {
            let level = TranscriptTail.rms(recording[index..<index + window])
            if quietest == nil || level < quietest!.rms { quietest = (index, level) }
            index += window
        }
        return quietest.map { $0.index + window / 2 }
    }

    /// Whether a segment `segmentSamples` long, from the live region's start, is settled
    /// even though its pass came back empty. A shorter one stays live and is retried as
    /// part of a longer one; past 25 s, sound with no words in it isn't speech.
    static func settlesWhenEmpty(segmentSamples: Int, sampleRate: Int) -> Bool {
        segmentSamples > maxSegmentSeconds * sampleRate
    }

    /// Two transcripts as one: a single space between them, and `next` lowercased when
    /// `settled` stops mid-sentence, since each segment is transcribed on its own and
    /// starts with a capital. A full stop the engine put only where the segment was cut
    /// is dropped (see `endsAtCut`); other punctuation is kept as transcribed.
    static func join(_ settled: String, _ next: String) -> String {
        var settled = settled.trimmingCharacters(in: .whitespacesAndNewlines)
        let next = next.trimmingCharacters(in: .whitespacesAndNewlines)
        if settled.isEmpty { return next }
        if next.isEmpty { return settled }
        if endsAtCut(settled, before: next) { settled = holdingBackStop(settled).text }
        return settled + continuation(next, after: settled)
    }

    /// Whether the full stop or ellipsis ending `settled` marks only where the recording was
    /// cut at a pause, not the end of a sentence: the engine ends every segment with one.
    /// That shows when `next` starts in lowercase, as the engine heard it carry on, or when
    /// the stop follows a word a sentence doesn't end on ("staring at.").
    static func endsAtCut(_ settled: String, before next: String) -> Bool {
        let held = holdingBackStop(settled)
        guard !held.stop.isEmpty else { return false }
        if let first = next.first(where: \.isLetter), first.isLowercase { return true }
        let lastWord = held.text.split(whereSeparator: \.isWhitespace).last.map { $0.lowercased().filter(\.isLetter) } ?? ""
        return unfinishedEndings.contains(lastWord)
    }

    /// `text` without a full stop or ellipsis at its end, and that stop. A dictation's first
    /// part is pasted before the rest is known, so its stop waits until it's clear whether
    /// a new sentence follows.
    static func holdingBackStop(_ text: String) -> (text: String, stop: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        for stop in ["...", "…", "."] where trimmed.hasSuffix(stop) {
            return (String(trimmed.dropLast(stop.count)), stop)
        }
        return (trimmed, "")
    }

    /// English words a spoken sentence doesn't end on: articles, prepositions,
    /// conjunctions and possessives. Words that can close a sentence ("that", "to", "in",
    /// "her") aren't here.
    private static let unfinishedEndings: Set<String> = [
        "a", "an", "the", "of", "at", "from", "by", "into", "onto", "with", "for", "and", "or", "but", "nor",
        "because", "than", "if", "my", "your", "our", "their", "its", "is", "are", "was", "were", "will", "would",
    ]

    /// `next` as it follows `previous` in the same dictation: a leading space unless
    /// `previous` already ends in one or `next` starts with punctuation, and the
    /// first letter adjusted as `join` does.
    static func continuation<S: StringProtocol>(_ next: String, after previous: S) -> String {
        var next = next.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let last = previous.last, let first = next.first else { return next }
        let trimmedPrevious = previous.trimmingCharacters(in: .whitespacesAndNewlines)
        if let end = trimmedPrevious.last, !".!?…".contains(end), shouldLowercase(next) {
            next = first.lowercased() + next.dropFirst()
        }
        if last.isWhitespace || ".,;:!?)]}…".contains(first) { return next }
        return " " + next
    }

    /// `text` in sentence case when it is all in capitals, so a short segment reads like
    /// the rest of the dictation. A transcript of up to 3 words keeps its 2–4 letter
    /// words as they are, since those are likely acronyms ("FBI CIA", "OK").
    static func fixingAllCaps(_ text: String) -> String {
        let lettered = text.split(whereSeparator: \.isWhitespace).filter { $0.contains(where: \.isLetter) }
        guard !text.contains(where: \.isLowercase) else { return text }
        let keepsShortWords = lettered.count <= 3
        var startsSentence = true
        let words = text.split(separator: " ", omittingEmptySubsequences: false).map { part -> String in
            let letters = part.filter(\.isLetter)
            var word: String
            if lettered.count == 1 || (keepsShortWords && (2...4).contains(letters.count)) {
                word = String(part)
            } else {
                word = part.lowercased()
                let isI = letters == "I" || word.hasPrefix("i'") || word.hasPrefix("i’")
                if startsSentence || isI, let first = word.first { word = first.uppercased() + word.dropFirst() }
            }
            if let last = word.last { startsSentence = ".!?…".contains(last) }
            return word
        }
        return words.joined(separator: " ")
    }

    /// Phrases a speech model tends to produce from room noise. Only a whole transcript
    /// that is one of these counts, never a sentence that contains one.
    private static let fillers: Set<String> = [
        "thanksforwatching", "thankyouforwatching", "thankyou", "thanks", "you", "bye",
        "pleasesubscribe", "music",
    ]

    /// Whether `text` is empty, only an ellipsis, or a filler phrase such as "Thanks for
    /// watching.", ignoring case, punctuation and spaces.
    static func isFiller(_ text: String) -> Bool {
        let normalised = String(text.lowercased().filter { $0.isLetter || $0.isNumber })
        return normalised.isEmpty || fillers.contains(normalised) || normalised.hasPrefix("subtitlesby")
    }

    /// The text to keep from a pass: a filler phrase from audio that was quiet by the
    /// relative rule is dropped, since nothing was said there. Output from louder audio is
    /// always kept.
    static func kept(_ text: String, regionIsQuiet: Bool) -> String {
        regionIsQuiet && isFiller(text) ? "" : text
    }

    /// Whether the first word is an ordinary capitalised word, not "I", an "I'"
    /// contraction or an all-caps word.
    private static func shouldLowercase(_ text: String) -> Bool {
        let word = text.prefix { !$0.isWhitespace }
        guard let first = word.first, first.isUppercase else { return false }
        let letters = word.filter(\.isLetter)
        if letters == "I" || word.hasPrefix("I'") || word.hasPrefix("I’") { return false }
        if letters.count > 1, letters.allSatisfy(\.isUppercase) { return false }
        return true
    }
}
