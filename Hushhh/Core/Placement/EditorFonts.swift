import AppKit

/// Fonts that apps name in their own settings, so ghost text can match them without
/// guessing.
enum EditorFonts {
    /// VS Code and its forks: bundle ID → folder under ~/Library/Application Support.
    static let codeSettingsFolders: [String: String] = [
        "com.microsoft.VSCode": "Code",
        "com.microsoft.VSCodeInsiders": "Code - Insiders",
        "com.todesktop.230313mzl4w4u92": "Cursor",
        "com.exafunction.windsurf": "Windsurf",
        "com.vscodium": "VSCodium",
        "com.google.antigravity": "Antigravity",
    ]
    /// VS Code's default editor font list on macOS.
    static let codeDefaultFamilies = ["Menlo", "Monaco", "Courier New"]

    private static let genericFamilies: Set<String> = ["monospace", "serif", "sans-serif", "system-ui", "ui-monospace"]

    /// Font families named in a CSS-style list ("'Fira Code', Menlo, monospace"), without
    /// generic families.
    static func families(fromCSSList list: String) -> [String] {
        list.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "'\"")) }
            .filter { !$0.isEmpty && !genericFamilies.contains($0.lowercased()) }
    }

    /// `editor.fontFamily` from a settings file (JSON with comments and trailing commas).
    static func codeFamilies(settings: String) -> [String] {
        guard let list = settingsObject(settings)?["editor.fontFamily"] as? String else { return codeDefaultFamilies }
        let found = families(fromCSSList: list)
        return found.isEmpty ? codeDefaultFamilies : found
    }

    /// `editor.fontSize` from a settings file.
    static func codeFontSize(settings: String) -> CGFloat? {
        (settingsObject(settings)?["editor.fontSize"] as? NSNumber).map { CGFloat($0.doubleValue) }
    }

    private static func settingsObject(_ text: String) -> [String: Any]? {
        guard let data = text.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data, options: [.json5Allowed])) as? [String: Any]
    }

    /// Ghostty's config files in the order it loads them; later files override earlier ones.
    static func ghosttyConfigPaths(home: URL, xdgConfigHome: String?) -> [URL] {
        let config = xdgConfigHome.map { URL(fileURLWithPath: $0) } ?? home.appendingPathComponent(".config")
        let support = home.appendingPathComponent("Library/Application Support/com.mitchellh.ghostty")
        return [config.appendingPathComponent("ghostty/config"), config.appendingPathComponent("ghostty/config.ghostty"),
                support.appendingPathComponent("config"), support.appendingPathComponent("config.ghostty")]
    }

    /// Reads `key = value` lines; later lines win and `#` starts a comment.
    static func parseKeyValues(_ text: String, into result: inout [String: String]) {
        for line in text.split(separator: "\n") {
            let parts = line.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            if parts.count == 2, !parts[0].hasPrefix("#") {
                result[parts[0]] = parts[1].trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            }
        }
    }

    /// The font of Terminal's default profile, from its preferences.
    static func terminalProfileFont(defaults: UserDefaults?) -> NSFont? {
        guard let defaults, let name = defaults.string(forKey: "Default Window Settings"),
              let profile = defaults.dictionary(forKey: "Window Settings")?[name] as? [String: Any],
              let data = profile["Font"] as? Data else { return nil }
        return try? NSKeyedUnarchiver.unarchivedObject(ofClass: NSFont.self, from: data)
    }

    /// A font of `family` at the size whose "M" is exactly one terminal cell wide.
    static func font(family: String, cellWidth: CGFloat) -> NSFont? {
        guard let reference = NSFontManager.shared.font(withFamily: family, traits: [], weight: 5, size: 100) else { return nil }
        let advance = ("M" as NSString).size(withAttributes: [.font: reference]).width / 100
        return NSFontManager.shared.font(withFamily: family, traits: [], weight: 5, size: cellWidth / advance)
    }
}
