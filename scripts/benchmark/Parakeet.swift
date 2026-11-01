// Transcribes 16 kHz mono WAV files with a transcribe.cpp GGUF model (Parakeet), for
// scripts/benchmark.py. Prints one line per file: "<name>\t<seconds>\t<text>".
// usage: Parakeet <model.gguf> <file.wav>...
import AVFoundation
import CTranscribe
import Foundation

func samples(_ path: String) throws -> [Float] {
    let file = try AVAudioFile(forReading: URL(fileURLWithPath: path))
    let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))!
    try file.read(into: buffer)
    return Array(UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength)))
}

let args = Array(CommandLine.arguments.dropFirst())
guard transcribe_init_backends_default() == TRANSCRIBE_OK else { fatalError("no backend") }
var model: OpaquePointer?
guard transcribe_model_load_file(args[0], nil, &model) == TRANSCRIBE_OK else { fatalError("couldn't load \(args[0])") }
var session: OpaquePointer?
guard transcribe_session_init(model, nil, &session) == TRANSCRIBE_OK else { fatalError("no session") }

for path in args.dropFirst() {
    let pcm = try samples(path)
    let start = Date()
    let status = pcm.withUnsafeBufferPointer { transcribe_run(session, $0.baseAddress, Int32($0.count), nil) }
    let text = status == TRANSCRIBE_OK ? String(cString: transcribe_full_text(session)) : ""
    print("\((path as NSString).lastPathComponent)\t\(String(format: "%.2f", Date().timeIntervalSince(start)))\t\(text.trimmingCharacters(in: .whitespacesAndNewlines))")
}
transcribe_session_free(session)
transcribe_model_free(model)
