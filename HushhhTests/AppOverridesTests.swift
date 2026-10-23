import AppKit
import XCTest

final class AppOverridesTests: XCTestCase {
    func testMergedTakesTheOthersSetFields() {
        let base = AppOverride(fontScale: 1.1, verticalOffset: 1)
        let merged = base.merged(with: AppOverride(verticalOffset: 2, greyGhostText: true))
        XCTAssertEqual(merged, AppOverride(fontScale: 1.1, verticalOffset: 2, greyGhostText: true))
    }
    func testResolveOrder() {
        let builtIn = ["com.example.app": AppOverride(verticalOffset: 1, textInset: 4)]
        let user = ["com.example.app": AppOverride(verticalOffset: 2),
                    "domain:*.atlassian.net": AppOverride(fontScale: 1.1)]
        let resolved = AppOverrides.resolve(bundleID: "com.example.app", host: "acme.atlassian.net", builtIn: builtIn, user: user)
        XCTAssertEqual(resolved, AppOverride(fontScale: 1.1, verticalOffset: 2, textInset: 4))
    }
    func testSiteBeatsApp() {
        let user = ["com.example.app": AppOverride(inlineDisabled: false), "domain:docs.example.com": AppOverride(inlineDisabled: true)]
        XCTAssertEqual(AppOverrides.resolve(bundleID: "com.example.app", host: "docs.example.com", builtIn: [:], user: user).inlineDisabled, true)
    }
    func testHostMatching() {
        XCTAssertTrue(AppOverrides.hostMatches("docs.example.com", "docs.example.com"))
        XCTAssertFalse(AppOverrides.hostMatches("docs.example.com", "mail.example.com"))
        XCTAssertTrue(AppOverrides.hostMatches("*.atlassian.net", "acme.atlassian.net"))
        XCTAssertTrue(AppOverrides.hostMatches("*.atlassian.net", "atlassian.net"))
        XCTAssertFalse(AppOverrides.hostMatches("*.atlassian.net", "notatlassian.net"))
    }
    func testDecode() {
        let data = Data(#"{"com.example.app": {"verticalOffset": 1.5, "greyGhostText": true}}"#.utf8)
        XCTAssertEqual(AppOverrides.decode(data)?["com.example.app"], AppOverride(verticalOffset: 1.5, greyGhostText: true))
        XCTAssertNil(AppOverrides.decode(Data("nope".utf8)))
    }
    func testAdjust() {
        let o = AppOverride(fontScale: 1.5, horizontalOffset: 2, verticalOffset: -1)
        XCTAssertEqual(o.adjust(CGRect(x: 10, y: 10, width: 1, height: 18)), CGRect(x: 12, y: 9, width: 1, height: 18))
        XCTAssertEqual(o.adjust(font: NSFont(name: "Helvetica", size: 12))?.pointSize, 18)
        XCTAssertNil(o.adjust(font: nil))
        XCTAssertEqual(AppOverride().adjust(CGRect(x: 10, y: 10, width: 1, height: 18)), CGRect(x: 10, y: 10, width: 1, height: 18))
    }
    func testExcelInsetIsBuiltIn() {
        XCTAssertEqual(AppOverrides.builtIn["com.microsoft.Excel"]?.textInset, 4)
    }
}
