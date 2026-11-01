import Foundation

/// Whether the newest partial transcript already covers everything that was said:
/// the audio after it is quiet, so a final pass would add nothing.
enum TranscriptTail {
    /// Loudness is judged over 50 ms windows, about one short syllable, so a soft word
    /// isn't averaged away by the silence around it.
    static func windowSize(sampleRate: Int) -> Int { sampleRate / 20 }

    /// The audio after `coveredSamples`, and always the last 100 ms of `recording`, so
    /// someone still talking at the keypress gets the full pass. Only a tail under the
    /// absolute floor counts as nothing new, so a soft last word is always transcribed,
    /// however loud the rest of the session was.
    static func partialIsFinal(recording: ArraySlice<Float>, coveredSamples: Int, sampleRate: Int) -> Bool {
        let covered = min(coveredSamples, recording.count)
        guard covered > 0 else { return false }
        let tailStart = max(0, min(covered, recording.count - sampleRate / 10))
        return isSilent(recording.suffix(recording.count - tailStart), sampleRate: sampleRate)
    }

    /// About 16 dB under this session's loudest speech: soft speech is louder, room noise
    /// is quieter. It picks pauses and judges filler phrases. The 0.003 floor (about
    /// -50 dBFS) is above a quiet microphone's own noise, so hiss isn't taken for speech.
    static func quietThreshold(speechPeakRMS: Float) -> Float {
        max(0.003, 0.15 * speechPeakRMS)
    }

    /// Below this (about -50 dBFS) a microphone records only its own noise.
    static let silenceFloor: Float = 0.003

    /// Whether no 50 ms window of `samples` reaches the absolute floor. Only such audio
    /// is left untranscribed, so soft speech is never skipped, however loud the rest
    /// of the session was.
    static func isSilent(_ samples: ArraySlice<Float>, sampleRate: Int) -> Bool {
        !hasWindow(in: samples, atLeast: silenceFloor, windowSize: windowSize(sampleRate: sampleRate))
    }

    /// Whether `samples` holds no speech, by this session's speech level: no stretch of it
    /// 200 ms long is voiced, in 20 ms frames over the relative quiet threshold with under
    /// 2,000 zero crossings a second (as vowels are; clicks, taps and breath noise cross far
    /// more often). Gaps of up to 60 ms, like the stop in "thank you", don't break a stretch.
    /// A spoken phrase, even "Thanks", is one such stretch; the key click that ends a
    /// dictation, and the taps and breaths scattered through a pause, are not. For a soft
    /// speaker the threshold is near the floor, so loudness alone would count those as sound.
    /// Used only to judge filler phrases.
    static func isQuiet(_ samples: ArraySlice<Float>, sampleRate: Int, speechPeakRMS: Float) -> Bool {
        let threshold = quietThreshold(speechPeakRMS: speechPeakRMS)
        let frame = sampleRate / 50
        guard frame > 1 else { return true }
        let maxCrossings = 2_000 * frame / sampleRate
        var stretchStart: Int?, lastVoiced = 0, index = 0
        var start = samples.startIndex
        while start + frame <= samples.endIndex {
            let window = samples[start..<start + frame]
            if rms(window) >= threshold, crossings(window) < maxCrossings {
                if let first = stretchStart, index - lastVoiced <= maxGapFrames + 1 {
                    if index - first + 1 >= minVoicedFrames { return false }
                } else {
                    stretchStart = index
                }
                lastVoiced = index
            }
            start += frame
            index += 1
        }
        return true
    }
    /// 200 ms of 20 ms frames.
    private static let minVoicedFrames = 10
    /// 60 ms.
    private static let maxGapFrames = 3

    /// How many times `window` changes sign.
    private static func crossings(_ window: ArraySlice<Float>) -> Int {
        var count = 0
        var previous = window.first ?? 0
        for s in window.dropFirst() {
            if (s < 0) != (previous < 0) { count += 1 }
            previous = s
        }
        return count
    }

    /// The root mean square of one window of audio.
    static func rms(_ window: ArraySlice<Float>) -> Float {
        guard !window.isEmpty else { return 0 }
        var sum = 0.0
        for s in window { sum += Double(s * s) }
        return Float((sum / Double(window.count)).squareRoot())
    }

    /// Whether any window of `samples` has an RMS of at least `threshold`. It stops at
    /// the first loud window, so a loud tail is found quickly.
    private static func hasWindow(in samples: ArraySlice<Float>, atLeast threshold: Float, windowSize: Int) -> Bool {
        let size = min(windowSize, samples.count)
        let limit = Double(threshold) * Double(threshold) * Double(size)
        var sum = 0.0
        var index = samples.startIndex
        for (offset, s) in samples.enumerated() {
            sum += Double(s * s)
            if offset >= size {
                let old = samples[index]
                sum -= Double(old * old)
                index += 1
            }
            if offset >= size - 1, sum >= limit { return true }
        }
        return false
    }
}

/// The loudest window of audio so far, fed chunk by chunk as it is recorded. The windows
/// don't overlap, which keeps each chunk's cost to one multiply-add per sample.
struct WindowedPeak {
    let windowSize: Int
    private(set) var rms: Float = 0
    private var sum = 0.0
    private var count = 0
    /// How many windows fell in each 1 dB step from -90 dBFS (index 0) up to 0 dBFS.
    private var histogram = [Int](repeating: 0, count: 91)
    private var windows = 0

    init(windowSize: Int) { self.windowSize = windowSize }

    /// The 95th percentile of window loudness, rounded down to the 1 dB step. A cough
    /// or a knock is a window or two, so it doesn't lift this the way it lifts `rms`,
    /// while speech fills far more than 5% of a dictation. It is used to judge pauses,
    /// so a single loud moment doesn't make the soft speech after it look like one.
    /// The histogram keeps it to a fixed 91 steps, however long the session runs.
    var robustRMS: Float {
        guard windows > 0 else { return 0 }
        let target = Int((Double(windows) * 0.05).rounded(.up))
        var seen = 0
        for step in stride(from: histogram.count - 1, through: 0, by: -1) {
            seen += histogram[step]
            if seen >= target { return step == 0 ? 0 : Float(pow(10, Double(step - 90) / 20)) }
        }
        return 0
    }

    mutating func add(_ chunk: ArraySlice<Float>) {
        for s in chunk {
            sum += Double(s * s)
            count += 1
            if count == windowSize {
                let level = Float((sum / Double(count)).squareRoot())
                rms = max(rms, level)
                let db = level > 0 ? 20 * log10(Double(level)) : -90
                histogram[min(90, max(0, Int(db.rounded(.down)) + 90))] += 1
                windows += 1
                sum = 0
                count = 0
            }
        }
    }
}
