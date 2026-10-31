import XCTest

final class DictationKeyTests: XCTestCase {
    func testCapsLockIsTheDefaultAndShowsItsSymbol() {
        XCTAssertTrue(DictationKey.capsLock.isCapsLock)
        XCTAssertEqual(DictationKey.capsLock.symbol, "⇪")
        XCTAssertEqual(DictationKey.capsLock.title, "⇪ Caps Lock")
    }

    func testModifiersShowInMenuOrder() {
        let key = DictationKey(keyCode: 2, modifiers: [.command, .control, .option, .shift], name: "D")
        XCTAssertEqual(key.symbol, "⌃⌥⇧⌘D")
        XCTAssertFalse(key.isCapsLock)
    }

    func testMatchesNeedTheSameModifiers() {
        let key = DictationKey(keyCode: 2, modifiers: [.option], name: "D")
        XCTAssertTrue(key.matches(keyCode: 2, modifiers: [.option]))
        XCTAssertFalse(key.matches(keyCode: 2, modifiers: []))
        XCTAssertFalse(key.matches(keyCode: 2, modifiers: [.option, .shift]))
        XCTAssertFalse(key.matches(keyCode: 3, modifiers: [.option]))
    }

    func testFunctionKeysNeedNoModifiers() {
        XCTAssertNil(DictationKey.rejection(keyCode: 96, modifiers: []))   // F5
        XCTAssertNil(DictationKey.rejection(keyCode: 80, modifiers: [.shift]))   // ⇧F19
    }

    func testTypingKeysNeedAModifierOtherThanShift() {
        XCTAssertNotNil(DictationKey.rejection(keyCode: 2, modifiers: []))
        XCTAssertNotNil(DictationKey.rejection(keyCode: 2, modifiers: [.shift]))
        XCTAssertNotNil(DictationKey.rejection(keyCode: 49, modifiers: []))   // Space
        XCTAssertNil(DictationKey.rejection(keyCode: 2, modifiers: [.option]))
        XCTAssertNil(DictationKey.rejection(keyCode: 49, modifiers: [.control]))
    }

    func testEscAndTabAreTaken() {
        XCTAssertNotNil(DictationKey.rejection(keyCode: DictationKey.escapeKeyCode, modifiers: []))
        XCTAssertNotNil(DictationKey.rejection(keyCode: DictationKey.tabKeyCode, modifiers: [.shift]))
        XCTAssertNil(DictationKey.rejection(keyCode: DictationKey.tabKeyCode, modifiers: [.option]))
    }

    func testNames() {
        XCTAssertEqual(DictationKey.name(keyCode: 96, characters: "\u{F708}"), "F5")
        XCTAssertEqual(DictationKey.name(keyCode: 49, characters: " "), "Space")
        XCTAssertEqual(DictationKey.name(keyCode: 2, characters: "d"), "D")
        XCTAssertEqual(DictationKey.name(keyCode: 200, characters: nil), "Key 200")
    }

    func testRoundTripsThroughJSON() throws {
        let key = DictationKey(keyCode: 2, modifiers: [.option, .command], name: "D")
        let decoded = try JSONDecoder().decode(DictationKey.self, from: JSONEncoder().encode(key))
        XCTAssertEqual(decoded, key)
    }
}
