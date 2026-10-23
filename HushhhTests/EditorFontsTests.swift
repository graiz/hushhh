import AppKit
import XCTest

final class EditorFontsTests: XCTestCase {
    func testCSSListDropsQuotesAndGenericFamilies() {
        XCTAssertEqual(EditorFonts.families(fromCSSList: "'Fira Code', Menlo, \"Courier New\", monospace"),
                       ["Fira Code", "Menlo", "Courier New"])
    }
    func testCodeFamiliesFromSettingsWithComments() {
        let settings = """
        {
          // Editor
          "editor.fontFamily": "JetBrains Mono, Menlo",
          "editor.fontSize": 15,
        }
        """
        XCTAssertEqual(EditorFonts.codeFamilies(settings: settings), ["JetBrains Mono", "Menlo"])
        XCTAssertEqual(EditorFonts.codeFontSize(settings: settings), 15)
    }
    func testCodeDefaultsWhenUnset() {
        XCTAssertEqual(EditorFonts.codeFamilies(settings: "{}"), EditorFonts.codeDefaultFamilies)
        XCTAssertEqual(EditorFonts.codeFamilies(settings: "not json"), EditorFonts.codeDefaultFamilies)
        XCTAssertNil(EditorFonts.codeFontSize(settings: "{}"))
    }
    func testGhosttyConfigPathsInLoadOrder() {
        let home = URL(fileURLWithPath: "/Users/test")
        XCTAssertEqual(EditorFonts.ghosttyConfigPaths(home: home, xdgConfigHome: nil).map(\.path), [
            "/Users/test/.config/ghostty/config",
            "/Users/test/.config/ghostty/config.ghostty",
            "/Users/test/Library/Application Support/com.mitchellh.ghostty/config",
            "/Users/test/Library/Application Support/com.mitchellh.ghostty/config.ghostty",
        ])
        XCTAssertEqual(EditorFonts.ghosttyConfigPaths(home: home, xdgConfigHome: "/tmp/xdg").first?.path, "/tmp/xdg/ghostty/config")
    }
    func testKeyValuesLaterLinesWinAndCommentsAreSkipped() {
        var result: [String: String] = [:]
        EditorFonts.parseKeyValues("font-size = 14\n# font-family = Nope\nfont-family = \"Iosevka\"", into: &result)
        EditorFonts.parseKeyValues("font-size = 16", into: &result)
        XCTAssertEqual(result["font-size"], "16")
        XCTAssertEqual(result["font-family"], "Iosevka")
    }
    func testTerminalProfileFont() throws {
        let suite = "com.graizlabs.hushhh.tests.terminal"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let data = try NSKeyedArchiver.archivedData(withRootObject: NSFont(name: "Menlo-Regular", size: 13)!, requiringSecureCoding: true)
        defaults.set("Basic", forKey: "Default Window Settings")
        defaults.set(["Basic": ["Font": data]], forKey: "Window Settings")
        XCTAssertEqual(EditorFonts.terminalProfileFont(defaults: defaults)?.familyName, "Menlo")
        XCTAssertNil(EditorFonts.terminalProfileFont(defaults: nil))
    }
    func testFontSizedToCellWidth() throws {
        let font = try XCTUnwrap(EditorFonts.font(family: "Menlo", cellWidth: 8))
        XCTAssertEqual(("M" as NSString).size(withAttributes: [.font: font]).width, 8, accuracy: 0.05)
        XCTAssertNil(EditorFonts.font(family: "No Such Family 123", cellWidth: 8))
    }
}
