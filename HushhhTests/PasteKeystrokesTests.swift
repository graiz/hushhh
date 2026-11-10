import CoreGraphics
import XCTest

final class PasteKeystrokesTests: XCTestCase {
    private let command = PasteKeystrokes.commandKey
    private let v = PasteKeystrokes.vKey

    func testAPasteEndsByReleasingCommand() {
        let keys = PasteKeystrokes.events(physicallyHeld: [])
        XCTAssertEqual(keys, [
            .init(key: command, isDown: true, flags: .maskCommand),
            .init(key: v, isDown: true, flags: .maskCommand),
            .init(key: v, isDown: false, flags: .maskCommand),
            .init(key: command, isDown: false, flags: []),
        ])
    }

    func testCommandHeldByThePersonIsLeftDown() {
        XCTAssertEqual(PasteKeystrokes.events(physicallyHeld: .maskCommand), [
            .init(key: v, isDown: true, flags: .maskCommand),
            .init(key: v, isDown: false, flags: .maskCommand),
        ])
    }

    func testOtherHeldModifiersDontChangeThePasteAndSurviveIt() {
        let keys = PasteKeystrokes.events(physicallyHeld: [.maskShift, .maskAlphaShift])
        XCTAssertEqual(keys.dropLast().map(\.flags), [.maskCommand, .maskCommand, .maskCommand])
        XCTAssertEqual(keys.last, .init(key: command, isDown: false, flags: .maskShift))
    }
}
