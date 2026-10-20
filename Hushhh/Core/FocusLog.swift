import AppKit

/// An opt-in rolling log of what apps report about the caret (positions, field
/// sizes and font names — never the text itself), at ~/Library/Logs/Hushhh/focus.log,
/// for diagnosing ghost-text placement in specific apps. Off unless enabled in
/// Settings › General › Troubleshooting.
enum FocusLog {
    /// Read on the main thread when a session starts; see `Preferences.diagnosticLog`.
    nonisolated(unsafe) static var isEnabled = false

    private static let url: URL = {
        let dir = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs/Hushhh", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("focus.log")
    }()
    private static let queue = DispatchQueue(label: "com.graizlabs.hushhh.focuslog", qos: .utility)
    private static let formatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withTime, .withFractionalSeconds]
        return f
    }()

    static func write(_ message: String) {
        guard isEnabled else { return }
        let line = "\(formatter.string(from: Date())) \(message)\n"
        queue.async {
            if let size = try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int, size > 512_000 {
                try? FileManager.default.removeItem(at: url)
            }
            if let handle = try? FileHandle(forWritingTo: url) {
                handle.seekToEndOfFile()
                handle.write(Data(line.utf8))
                try? handle.close()
            } else {
                // Readable only by this user.
                FileManager.default.createFile(atPath: url.path, contents: Data(line.utf8),
                                               attributes: [.posixPermissions: 0o600])
            }
        }
    }

    static func describe(_ r: CGRect?) -> String {
        guard let r else { return "nil" }
        return String(format: "(%.0f,%.0f %.0fx%.0f)", r.minX, r.minY, r.width, r.height)
    }
}
