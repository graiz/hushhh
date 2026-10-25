import Foundation

/// An on-device speech-to-text engine that transcribes a whole 16 kHz mono buffer.
protocol SpeechEngine: AnyObject {
    var displayName: String { get }
    func load() async throws
    func transcribe(_ samples: [Float]) async -> String
}
