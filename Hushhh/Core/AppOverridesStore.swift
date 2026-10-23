import Foundation

/// The person's own placement overrides, from a JSON file they can edit. Read the
/// first time a dictation session needs it and kept until the next session starts, so
/// edits take effect on the next dictation.
enum AppOverridesStore {
    static let url: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Hushhh/app-overrides.json")

    private static var cached: [String: AppOverride]?

    static func current(bundleID: String?, host: String?) -> AppOverride {
        AppOverrides.resolve(bundleID: bundleID, host: host, builtIn: AppOverrides.builtIn, user: user())
    }

    private static var cachedHasSiteEntries: Bool?

    /// Whether any entry is for a site, so capture only looks up the page's address
    /// when one could apply. Kept for the session, like the table.
    static var hasSiteEntries: Bool {
        if let cachedHasSiteEntries { return cachedHasSiteEntries }
        let found = AppOverrides.hasSiteEntries(AppOverrides.builtIn, user())
        cachedHasSiteEntries = found
        return found
    }

    /// Forget the file's contents; the next lookup reads it again.
    static func beginSession() {
        cached = nil
        cachedHasSiteEntries = nil
    }

    private static func user() -> [String: AppOverride] {
        if let cached { return cached }
        var table: [String: AppOverride] = [:]
        if let data = try? Data(contentsOf: url) {
            if let decoded = AppOverrides.decode(data) {
                table = decoded
            } else {
                FocusLog.write("overrides: couldn't read \(url.lastPathComponent); ignoring it")
            }
        }
        cached = table
        return table
    }

    /// Creates the file with an example entry the first time, so Settings can open it.
    static func ensureFile() -> URL {
        if !FileManager.default.fileExists(atPath: url.path) {
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let example = """
            {
              "com.example.app": { "verticalOffset": 0, "horizontalOffset": 0, "fontScale": 1.0 }
            }

            """
            try? example.write(to: url, atomically: true, encoding: .utf8)
        }
        return url
    }
}
