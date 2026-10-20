import Foundation
import WhisperKit

/// An on-device speech-to-text engine that transcribes a whole 16 kHz mono buffer.
protocol SpeechEngine: AnyObject {
    var displayName: String { get }
    func load() async throws
    func transcribe(_ samples: [Float]) async -> String
}

// MARK: - QVAC TranscribePsy

/// All engine access happens on `queue`.
final class QVACEngine: SpeechEngine, @unchecked Sendable {
    let modelURL: URL
    let useGPU: Bool
    private let queue = DispatchQueue(label: "com.graizlabs.hushhh.qvac", qos: .userInitiated)
    private var transcriber: QVACTranscriber?

    var displayName: String { "QVAC TranscribePsy" }

    init(modelURL: URL, useGPU: Bool) {
        self.modelURL = modelURL
        self.useGPU = useGPU
    }

    func load() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async {
                do {
                    self.transcriber = try QVACTranscriber(modelPath: self.modelURL.path, useGPU: self.useGPU)
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    func transcribe(_ samples: [Float]) async -> String {
        await withCheckedContinuation { continuation in
            queue.async {
                let text = samples.withUnsafeBufferPointer { buffer -> String in
                    guard let base = buffer.baseAddress, let transcriber = self.transcriber else { return "" }
                    return transcriber.transcribeSamples(base, count: buffer.count)
                }
                continuation.resume(returning: text.trimmingCharacters(in: .whitespacesAndNewlines))
            }
        }
    }
}

// MARK: - Whisper (WhisperKit)

final class WhisperEngine: SpeechEngine {
    let model: WhisperModel
    let folder: URL
    private var pipe: WhisperKit?

    var displayName: String { "Whisper \(model.title)" }

    init(model: WhisperModel, folder: URL) {
        self.model = model
        self.folder = folder
    }

    func load() async throws {
        let config = WhisperKitConfig(
            model: model.rawValue,
            downloadBase: ModelStore.whisperBase,
            modelFolder: folder.path,
            tokenizerFolder: ModelStore.whisperBase,
            verbose: false,
            logLevel: .error,
            prewarm: true,
            load: true,
            download: false
        )
        // The tokenizer is fetched on first load; retry once if that download is interrupted.
        do {
            pipe = try await WhisperKit(config)
        } catch {
            try await Task.sleep(nanoseconds: 500_000_000)
            pipe = try await WhisperKit(config)
        }
    }

    func transcribe(_ samples: [Float]) async -> String {
        guard let pipe else { return "" }
        let options = DecodingOptions(
            task: .transcribe,
            language: model.isEnglishOnly ? "en" : nil,
            temperature: 0,
            usePrefillPrompt: true,
            detectLanguage: !model.isEnglishOnly,
            skipSpecialTokens: true,
            withoutTimestamps: true,
            suppressBlank: true,
            chunkingStrategy: .vad
        )
        let results = (try? await pipe.transcribe(audioArray: samples, decodeOptions: options)) ?? []
        return Self.clean(results.map(\.text).joined(separator: " "))
    }

    /// Strips Whisper's non-speech annotations such as "[BLANK_AUDIO]" or "(music)".
    static func clean(_ text: String) -> String {
        var t = text.replacingOccurrences(of: #"\[[^\]]*\]"#, with: "", options: .regularExpression)
        t = t.replacingOccurrences(of: #"(?i)\((?:music|silence|inaudible|blank_audio|applause|laughs?|noise)\)"#,
                                   with: "", options: .regularExpression)
        t = t.replacingOccurrences(of: #"\s{2,}"#, with: " ", options: .regularExpression)
        return t.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
