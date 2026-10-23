import AppKit

/// Placement adjustments for one app or site that reports its text slightly wrong.
struct AppOverride: Codable, Equatable {
    /// Never draw ghost text inline; show the bubble instead.
    var inlineDisabled: Bool? = nil
    /// Multiplies the ghost text's font size.
    var fontScale: Double? = nil
    /// Points to move ghost text right (positive) or left.
    var horizontalOffset: Double? = nil
    /// Points to move ghost text up (positive) or down.
    var verticalOffset: Double? = nil
    /// Points between a field's edge and its text, used when Hushhh measures the text itself.
    var textInset: Double? = nil
    /// Draw ghost text in neutral grey instead of the app's reported text colour.
    var greyGhostText: Bool? = nil
    /// Switch AXEnhancedUserInterface on (true) or never (false), whatever the app's engine.
    var enhancedUserInterface: Bool? = nil

    /// This override with every field that `other` sets replaced.
    func merged(with other: AppOverride) -> AppOverride {
        AppOverride(inlineDisabled: other.inlineDisabled ?? inlineDisabled,
                    fontScale: other.fontScale ?? fontScale,
                    horizontalOffset: other.horizontalOffset ?? horizontalOffset,
                    verticalOffset: other.verticalOffset ?? verticalOffset,
                    textInset: other.textInset ?? textInset,
                    greyGhostText: other.greyGhostText ?? greyGhostText,
                    enhancedUserInterface: other.enhancedUserInterface ?? enhancedUserInterface)
    }

    /// `rect` (Cocoa coordinates, so up is +y) moved by the offsets.
    func adjust(_ rect: CGRect) -> CGRect {
        rect.offsetBy(dx: CGFloat(horizontalOffset ?? 0), dy: CGFloat(verticalOffset ?? 0))
    }

    /// `font` scaled by `fontScale`; a missing or non-positive scale leaves it as it is.
    func adjust(font: NSFont?) -> NSFont? {
        guard let font, let scale = fontScale, scale > 0 else { return font }
        return NSFont(descriptor: font.fontDescriptor, size: font.pointSize * CGFloat(scale))
    }
}

enum AppOverrides {
    /// Adjustments Hushhh ships with, measured by hand.
    static let builtIn: [String: AppOverride] = [
        // Excel draws cell text 4 pt in from the cell edge.
        "com.microsoft.Excel": AppOverride(textInset: 4),
    ]

    /// Keys are bundle IDs or "domain:<host>" ("domain:*.example.com" matches subdomains).
    /// Site entries win over app entries, and the person's own entries win over built-in ones.
    static func resolve(bundleID: String?, host: String?, builtIn: [String: AppOverride], user: [String: AppOverride]) -> AppOverride {
        func site(_ table: [String: AppOverride]) -> AppOverride? {
            guard let host else { return nil }
            let matches = table.keys.filter { $0.hasPrefix(sitePrefix) && hostMatches(String($0.dropFirst(sitePrefix.count)), host) }
            return matches.max { specificity($0) < specificity($1) }.flatMap { table[$0] }
        }
        let layers = [bundleID.flatMap { builtIn[$0] }, bundleID.flatMap { user[$0] }, site(builtIn), site(user)]
        return layers.compactMap { $0 }.reduce(AppOverride()) { $0.merged(with: $1) }
    }

    static let sitePrefix = "domain:"

    /// True when either table has a site entry, so pages are only asked for their
    /// address when an entry could use it.
    static func hasSiteEntries(_ tables: [String: AppOverride]...) -> Bool {
        tables.contains { $0.keys.contains { $0.hasPrefix(sitePrefix) } }
    }

    /// Ranks matching site keys so the most specific wins: an exact host beats any
    /// wildcard, and a longer wildcard apex beats a shorter one.
    private static func specificity(_ key: String) -> Int {
        let pattern = key.dropFirst(sitePrefix.count)
        return pattern.hasPrefix("*.") ? pattern.count - 2 : Int.max
    }

    static func hostMatches(_ pattern: String, _ host: String) -> Bool {
        guard pattern.hasPrefix("*.") else { return host == pattern }
        let apex = String(pattern.dropFirst(2))
        return host == apex || host.hasSuffix("." + apex)
    }

    static func decode(_ data: Data) -> [String: AppOverride]? {
        try? JSONDecoder().decode([String: AppOverride].self, from: data)
    }
}
