import Foundation

/// Buffers microphone audio and re-transcribes it while the person speaks, so
/// the preview fills in live. The final pass runs over the whole recording.
final class LiveTranscriber {
    private let engineProvider: () async throws -> SpeechEngine
    private let lock = NSLock()
    private var samples: [Float] = []
    private var peakLevel: Float = 0
    private var loop: Task<Void, Never>?
    private var engine: SpeechEngine?

    /// Delivered on the main actor.
    var onPartial: (@MainActor (String) -> Void)?
    var onError: (@MainActor (Error) -> Void)?

    private static let sampleRate = 16_000
    /// Re-run only once this much new audio has arrived.
    private static let minNewSamples = sampleRate * 3 / 10
    private static let minSamples = sampleRate / 4
    /// Below this, the recording is treated as silence (avoids hallucinated text).
    private static let silenceThreshold: Float = 0.02

    init(engineProvider: @escaping () async throws -> SpeechEngine) {
        self.engineProvider = engineProvider
    }

    func append(_ chunk: [Float], level: Float) {
        lock.lock()
        samples.append(contentsOf: chunk)
        peakLevel = max(peakLevel, level)
        lock.unlock()
    }

    private func snapshot() -> (samples: [Float], peak: Float) {
        lock.lock(); defer { lock.unlock() }
        return (samples, peakLevel)
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
            var transcribedCount = 0
            while !Task.isCancelled {
                let (audio, peak) = self.snapshot()
                if audio.count >= Self.minSamples,
                   audio.count - transcribedCount >= Self.minNewSamples,
                   peak >= Self.silenceThreshold,
                   let engine = self.engine {
                    let text = await engine.transcribe(audio)
                    transcribedCount = audio.count
                    if Task.isCancelled { break }
                    await MainActor.run { self.onPartial?(text) }
                } else {
                    try? await Task.sleep(nanoseconds: 100_000_000)
                }
            }
        }
    }

    /// Stops the live loop and returns the transcript of the whole recording.
    func finish() async -> String {
        let running = loop
        running?.cancel()
        await running?.value
        if engine == nil {
            // The model was still loading when the person finished speaking.
            engine = try? await engineProvider()
        }
        let (audio, peak) = snapshot()
        guard let engine, audio.count >= Self.minSamples, peak >= Self.silenceThreshold else { return "" }
        return await engine.transcribe(audio)
    }

    func cancel() {
        loop?.cancel()
        loop = nil
    }
}
