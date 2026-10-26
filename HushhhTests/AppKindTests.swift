import XCTest

final class AppKindTests: XCTestCase {
    func testElectronFrameworkMeansElectron() {
        XCTAssertEqual(AppKind.classify(bundleID: "com.tinyspeck.slackmacgap",
                                        frameworkNames: ["Electron Framework.framework", "Squirrel.framework"],
                                        hasAppArchive: false, infoKeys: []), .electron)
    }

    func testRenamedElectronFrameworkIsStillElectron() {
        XCTAssertEqual(AppKind.classify(bundleID: "com.example.chat", frameworkNames: ["Chat Framework.framework"],
                                        hasAppArchive: true, infoKeys: []), .electron)
        XCTAssertEqual(AppKind.classify(bundleID: "com.example.chat", frameworkNames: ["Chat Framework.framework"],
                                        hasAppArchive: false, infoKeys: ["ElectronAsarIntegrity"]), .electron)
    }

    func testProductFrameworkMeansChromium() {
        XCTAssertEqual(AppKind.classify(bundleID: "com.google.Chrome", frameworkNames: ["Google Chrome Framework.framework"],
                                        hasAppArchive: false, infoKeys: []), .chromium)
        XCTAssertEqual(AppKind.classify(bundleID: "com.example.browser", frameworkNames: ["Example Browser Framework.framework"],
                                        hasAppArchive: false, infoKeys: []), .chromium)
    }

    func testEmbeddedChromiumMeansChromium() {
        XCTAssertEqual(AppKind.classify(bundleID: "com.example.player", frameworkNames: ["Chromium Embedded Framework.framework"],
                                        hasAppArchive: false, infoKeys: []), .chromium)
    }

    func testKnownBrowserWithoutRecognisedFrameworks() {
        XCTAssertEqual(AppKind.classify(bundleID: "company.thebrowser.Browser", frameworkNames: [],
                                        hasAppArchive: false, infoKeys: []), .chromium)
    }

    func testNativeApp() {
        XCTAssertEqual(AppKind.classify(bundleID: "com.apple.TextEdit", frameworkNames: ["Sparkle.framework"],
                                        hasAppArchive: false, infoKeys: ["CFBundleIdentifier"]), .native)
    }

    func testReadsTheBundleOnDisk() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? fm.removeItem(at: root) }

        let browser = root.appendingPathComponent("Browser.app")
        try fm.createDirectory(at: browser.appendingPathComponent("Contents/Frameworks/Browser Framework.framework"),
                               withIntermediateDirectories: true)
        XCTAssertEqual(AppKind.of(bundleURL: browser, bundleID: "com.example.browser"), .chromium)

        let chat = root.appendingPathComponent("Chat.app")
        try fm.createDirectory(at: chat.appendingPathComponent("Contents/Frameworks/Chat Framework.framework"),
                               withIntermediateDirectories: true)
        try fm.createDirectory(at: chat.appendingPathComponent("Contents/Resources"), withIntermediateDirectories: true)
        fm.createFile(atPath: chat.appendingPathComponent("Contents/Resources/app.asar").path, contents: Data())
        XCTAssertEqual(AppKind.of(bundleURL: chat, bundleID: "com.example.chat"), .electron)

        XCTAssertEqual(AppKind.of(bundleURL: nil, bundleID: "com.apple.TextEdit"), .native)
    }

    func testCodeEditorsIncludeVSCodeForks() {
        XCTAssertTrue(AppKind.codeEditorBundleIDs.contains("com.microsoft.VSCode"))
        XCTAssertTrue(AppKind.codeEditorBundleIDs.contains("com.todesktop.230313mzl4w4u92"))
        XCTAssertFalse(AppKind.codeEditorBundleIDs.contains("com.tinyspeck.slackmacgap"))
    }

    func testEnhancedUIIsManagedForChromiumAndElectron() {
        XCTAssertTrue(AppKind.shouldManageEnhancedUI(kind: .chromium, bundleID: "com.google.Chrome", override: nil))
        XCTAssertTrue(AppKind.shouldManageEnhancedUI(kind: .electron, bundleID: "com.anthropic.claudefordesktop", override: nil))
        XCTAssertTrue(AppKind.shouldManageEnhancedUI(kind: .electron, bundleID: nil, override: nil))
        XCTAssertFalse(AppKind.shouldManageEnhancedUI(kind: .native, bundleID: "com.apple.TextEdit", override: nil))
    }

    func testEnhancedUIIsNeverManagedForCodeEditors() {
        XCTAssertFalse(AppKind.shouldManageEnhancedUI(kind: .electron, bundleID: "com.microsoft.VSCode", override: nil))
        XCTAssertFalse(AppKind.shouldManageEnhancedUI(kind: .electron, bundleID: "com.todesktop.230313mzl4w4u92", override: nil))
    }

    func testEnhancedUIOverrideWinsBothWays() {
        XCTAssertFalse(AppKind.shouldManageEnhancedUI(kind: .electron, bundleID: "com.tinyspeck.slackmacgap", override: false))
        XCTAssertFalse(AppKind.shouldManageEnhancedUI(kind: .chromium, bundleID: "com.google.Chrome", override: false))
        XCTAssertTrue(AppKind.shouldManageEnhancedUI(kind: .native, bundleID: "com.apple.TextEdit", override: true))
        XCTAssertTrue(AppKind.shouldManageEnhancedUI(kind: .electron, bundleID: "com.microsoft.VSCode", override: true))
    }
}
