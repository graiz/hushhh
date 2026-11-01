// Transcribes WAV files with Apple's on-device SpeechTranscriber (macOS 26), for
// scripts/benchmark.py. Prints one line per file: "<name>\t<seconds>\t<text>".
// usage: AppleSpeech <file.wav>...
import AVFoundation
import Foundation
import Speech

@main struct AppleSpeech {
    static func main() async throws {
        let locale = Locale(identifier: "en-US")
        for path in CommandLine.arguments.dropFirst() {
            let transcriber = SpeechTranscriber(locale: locale, preset: .transcription)
            if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
                try await request.downloadAndInstall()
            }
            let analyzer = SpeechAnalyzer(modules: [transcriber])
            let collect = Task { () -> String in
                var text = ""
                for try await result in transcriber.results where result.isFinal { text += String(result.text.characters) }
                return text
            }
            let file = try AVAudioFile(forReading: URL(fileURLWithPath: path))
            let start = Date()
            try await analyzer.start(inputAudioFile: file, finishAfterFile: true)
            let text = try await collect.value.trimmingCharacters(in: .whitespacesAndNewlines)
            print("\((path as NSString).lastPathComponent)\t\(String(format: "%.2f", Date().timeIntervalSince(start)))\t\(text)")
        }
    }
}
