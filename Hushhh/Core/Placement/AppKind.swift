import Foundation

/// The engine an app draws its text with, read from its bundle on disk. Electron and
/// Chromium apps only build their accessibility tree when asked, and Chromium
/// browsers also need AXEnhancedUserInterface before they report text positions.
enum AppKind: Equatable {
    case electron
    case chromium
    case native

    /// Browsers whose engine framework might not be recognisable by name.
    static let knownChromiumBundleIDs: Set<String> = [
        "com.google.Chrome", "com.google.Chrome.canary", "com.google.Chrome.beta", "com.google.Chrome.dev",
        "com.microsoft.edgemac", "com.microsoft.edgemac.Beta", "com.microsoft.edgemac.Dev",
        "com.brave.Browser", "company.thebrowser.Browser", "company.thebrowser.dia",
        "com.vivaldi.Vivaldi", "com.operasoftware.Opera", "org.chromium.Chromium",
    ]

    static func classify(bundleID: String?, frameworkNames: [String], hasAppArchive: Bool, infoKeys: Set<String>) -> AppKind {
        // Some Electron apps rename "Electron Framework" after the product; their app
        // archive and its integrity key still give them away.
        if frameworkNames.contains("Electron Framework.framework") || hasAppArchive || infoKeys.contains("ElectronAsarIntegrity") {
            return .electron
        }
        if frameworkNames.contains("Chromium Embedded Framework.framework") { return .chromium }
        // Chromium browsers ship their engine as "<Product> Framework.framework"
        // (Google Chrome Framework, Microsoft Edge Framework).
        if frameworkNames.contains(where: { $0.hasSuffix(" Framework.framework") }) { return .chromium }
        if let bundleID, knownChromiumBundleIDs.contains(bundleID) { return .chromium }
        return .native
    }

    private static var cache: [String: AppKind] = [:]

    static func of(bundleURL: URL?, bundleID: String?) -> AppKind {
        guard let bundleURL else {
            return classify(bundleID: bundleID, frameworkNames: [], hasAppArchive: false, infoKeys: [])
        }
        if let cached = cache[bundleURL.path] { return cached }
        let contents = bundleURL.appendingPathComponent("Contents")
        let fm = FileManager.default
        let frameworks = (try? fm.contentsOfDirectory(atPath: contents.appendingPathComponent("Frameworks").path)) ?? []
        let archive = fm.fileExists(atPath: contents.appendingPathComponent("Resources/app.asar").path)
        let info = (NSDictionary(contentsOf: contents.appendingPathComponent("Info.plist")) as? [String: Any]).map { Set($0.keys) } ?? []
        let kind = classify(bundleID: bundleID, frameworkNames: frameworks, hasAppArchive: archive, infoKeys: info)
        cache[bundleURL.path] = kind
        return kind
    }
}
