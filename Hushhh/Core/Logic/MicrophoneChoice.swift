import Foundation

/// Picks which of several microphones, all listening from the start of a dictation,
/// hears the person best. The others are closed once it's decided.
enum MicrophoneChoice {
    /// 50 ms windows at 16 kHz.
    static let windowSize = 800
    /// The first stretch of each microphone is ignored: it holds the click of the key
    /// that started dictation, which the built-in microphone hears loudest.
    static let ignoredSamples = 16_000 * 3 / 10
    /// How much speech the comparison covers.
    static let recentWindows = 8
    /// Below this, a microphone hasn't heard anyone yet (the same floor as `TranscriptTail`).
    static let speechFloor: Float = 0.003
    /// Below this, a microphone hears nothing at all, not even room noise: a virtual
    /// device with nothing routed to it, or a muted one.
    static let deadLevel: Float = 0.0001
    /// Another microphone must be this much louder than the default one to be chosen
    /// (about 3.5 dB), so the default wins near-ties.
    static let margin: Float = 1.5
    /// With no speech by then, keep the default microphone.
    static let giveUpSamples = 16_000 * 3

    /// One microphone's recent loudness.
    struct Meter {
        private(set) var received = 0
        private var sumOfSquares: Float = 0
        private var inWindow = 0
        private var windows: [Float] = []

        mutating func add(_ samples: [Float]) {
            for sample in samples {
                received += 1
                guard received > ignoredSamples else { continue }
                sumOfSquares += sample * sample
                inWindow += 1
                if inWindow == windowSize {
                    windows.append((sumOfSquares / Float(windowSize)).squareRoot())
                    if windows.count > recentWindows { windows.removeFirst() }
                    sumOfSquares = 0
                    inWindow = 0
                }
            }
        }

        /// The mean loudness of the most recent full stretch, or nil until there is one.
        var recentRMS: Float? {
            windows.count == recentWindows ? windows.reduce(0, +) / Float(recentWindows) : nil
        }
    }

    struct Choice: Equatable {
        var index: Int
        /// False when nobody spoke and the first was kept, so the choice says nothing
        /// about which microphone is best.
        var isConfident: Bool
    }

    /// The microphone to keep, or nil to keep listening on all of them.
    /// - Parameters:
    ///   - meters: one per microphone, in order; index 0 is preferred in a near-tie.
    static func choose(_ meters: [Meter]) -> Choice? {
        guard meters.count > 1 else { return meters.isEmpty ? nil : Choice(index: 0, isConfident: false) }
        let levels = meters.map { $0.recentRMS ?? 0 }
        guard let loudest = levels.indices.max(by: { levels[$0] < levels[$1] }) else { return nil }
        // A first microphone that hears nothing at all loses to any that hears the room,
        // without waiting for speech.
        if let first = meters[0].recentRMS, first < deadLevel, levels[loudest] >= deadLevel {
            return Choice(index: loudest, isConfident: true)
        }
        guard levels[loudest] >= speechFloor else {
            // Nobody has spoken yet; after a while, settle on the first.
            return meters[0].received >= giveUpSamples ? Choice(index: 0, isConfident: false) : nil
        }
        // A microphone still starting up (Bluetooth) can't be compared yet; the ones that
        // have heard speech decide.
        return Choice(index: levels[loudest] >= levels[0] * margin ? loudest : 0, isConfident: true)
    }
}
