import AVFoundation

/// For developers: keeps the last few dictations' audio and transcripts at
/// ~/Library/Logs/Hushhh/Recordings, so a misheard dictation can be replayed with
/// `Hushhh --transcribe <file>.wav`. Off unless turned on with
/// `defaults write com.graizlabs.hushhh keepRecentRecordings -bool true`.
enum RecentRecordings {
    /// Read on the main thread when a session starts.
    nonisolated(unsafe) static var isEnabled = false
    /// About 32 KB per second of audio, so 200 typical dictations take under 100 MB.
    static let keep = 200

    static let directory: URL = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Logs/Hushhh/Recordings", isDirectory: true)

    private static let queue = DispatchQueue(label: "com.graizlabs.hushhh.recordings", qos: .utility)
    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd'T'HH-mm-ss"
        return f
    }()

    /// Saves 16 kHz mono `samples` and what Hushhh made of them (`outcome` says how the
    /// session ended), then removes all but the newest `keep`.
    /// `samples` is only copied when this is on.
    static func save(_ samples: @autoclosure () -> [Float], transcript: String, outcome: String) {
        guard isEnabled else { return }
        let samples = samples()
        guard !samples.isEmpty else { return }
        let name = formatter.string(from: Date())
        queue.async {
            let fm = FileManager.default
            // Readable only by this user.
            try? fm.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let audio = directory.appendingPathComponent(name + ".wav")
            guard write(samples, to: audio) else { return }
            try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: audio.path)
            fm.createFile(atPath: directory.appendingPathComponent(name + ".txt").path,
                          contents: Data("\(outcome)\n\(transcript)\n".utf8), attributes: [.posixPermissions: 0o600])
            prune()
        }
    }

    private static func write(_ samples: [Float], to url: URL) -> Bool {
        let rate = Double(LiveTranscriber.sampleRate)
        let settings: [String: Any] = [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: rate,
                                       AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 16,
                                       AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false]
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 1, interleaved: false),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)),
              let file = try? AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32,
                                          interleaved: false) else { return false }
        buffer.frameLength = buffer.frameCapacity
        samples.withUnsafeBufferPointer { buffer.floatChannelData![0].update(from: $0.baseAddress!, count: samples.count) }
        return (try? file.write(from: buffer)) != nil
    }

    private static func prune() {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: directory.path) else { return }
        // Names are timestamps, so they sort oldest first.
        let stems = Set(names.filter { $0.hasSuffix(".wav") }.map { String($0.dropLast(4)) }).sorted()
        for stem in stems.dropLast(keep) {
            for ext in ["wav", "txt"] { try? fm.removeItem(at: directory.appendingPathComponent("\(stem).\(ext)")) }
        }
    }
}
