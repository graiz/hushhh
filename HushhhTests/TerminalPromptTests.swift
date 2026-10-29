import XCTest

final class TerminalPromptTests: XCTestCase {
    private let rule = String(repeating: "─", count: 124)

    /// A Claude Code screen inside a pane manager with a 24-column sidebar, as Ghostty
    /// reports it (46 rows, trailing spaces trimmed).
    private var paneManagerScreen: [String] {
        var rows = Array(repeating: "                        │", count: 37)
        rows += [
            "  claude                │",
            "○ notes                 │✶ Choreographing… (1m 28s · ↓ 3.6k tokens)",
            "  claude                │  ⎿  Tip: Run claude --continue or claude --resume to resume a conversation",
            "○ docs · 1              │",
            "  claude                │" + rule,
            "○ api · 2               │❯",
            "  claude                │" + rule,
            "○ web · 3               │  ➜ project | model | 120K tokens | 40% of session limit",
            "  claude               «│  ⏵⏵ auto mode on (shift+tab to cycle) · ← 1 agent",
        ]
        return rows
    }

    private func assertLocate(_ rows: [String], row: Int, column: Int, preceding: Character?,
                              file: StaticString = #filePath, line: UInt = #line) {
        guard let found = TerminalPrompt.locate(rows: rows) else { return XCTFail("no prompt", file: file, line: line) }
        XCTAssertEqual(found.row, row, "row", file: file, line: line)
        XCTAssertEqual(found.column, column, "column", file: file, line: line)
        XCTAssertEqual(found.preceding, preceding, "preceding", file: file, line: line)
    }

    func testPaneManagerScreen() {
        let rows = paneManagerScreen
        XCTAssertEqual(rows.count, 46)
        assertLocate(rows, row: 42, column: 27, preceding: " ")
    }

    func testBoxWithoutSidebar() {
        let rows = ["some output", "", rule, "❯ ", rule, "  ⏵⏵ auto mode on (shift+tab to cycle)", ""]
        assertLocate(rows, row: 3, column: 2, preceding: " ")
    }

    func testBorderedBox() {
        let rows = ["╭─────────────────╮", "│ > hello         │", "╰─────────────────╯", "  ? for shortcuts"]
        assertLocate(rows, row: 1, column: 9, preceding: "o")
    }

    func testTypedInput() {
        let rows = ["output", rule, "❯ fix the parser", rule, "  status"]
        assertLocate(rows, row: 2, column: 16, preceding: "r")
    }

    func testTypedInputInPane() {
        let rows = ["sidebar     │" + rule, "  claude    │❯ fix the parser", "            │" + rule]
        assertLocate(rows, row: 1, column: 13 + 16, preceding: "r")
    }

    func testEmojiCountsAsTwoCells() {
        let rows = [rule, "❯ ship it 🚀", rule]
        assertLocate(rows, row: 1, column: 12, preceding: "🚀")
    }

    func testWrappedInput() {
        let rows = ["output", rule, "❯ a long request that runs past the edge of", "  the box onto a second row", rule]
        assertLocate(rows, row: 3, column: 27, preceding: "w")
    }

    func testPlaceholder() {
        let rows = [rule, "❯ Try \"refactor the parser\"", rule]
        assertLocate(rows, row: 1, column: 2, preceding: " ")
    }

    func testNoBreakSpaceAfterMark() {
        let rows = ["sidebar  ▕│" + rule, "  agents ▕│❯\u{00A0}fix it", "         ▕│" + rule]
        assertLocate(rows, row: 1, column: 11 + 8, preceding: "t")
    }

    /// A labelled top rule and the hint shown when the input goes to an agent.
    func testAgentMessagePlaceholder() {
        let rows = ["    mail                 ▕│" + String(repeating: "─", count: 112) + " @reviewers ─",
                    "  ○ app                  ▕│❯\u{00A0}Message @reviewers…",
                    "    claude               ▕│" + rule,
                    "  ○ site · 2             ▕│  status line"]
        assertLocate(rows, row: 1, column: 29, preceding: " ")
    }

    func testTopRuleUpToThreeRowsAbove() {
        let rows = [rule, "", "", "❯ hi", rule]
        assertLocate(rows, row: 3, column: 4, preceding: "i")
        XCTAssertNil(TerminalPrompt.locate(rows: [rule, "", "", "", "❯ hi", rule]))
    }

    func testPlainShellPrompt() {
        XCTAssertNil(TerminalPrompt.locate(rows: ["$ ls", "a b c", "> "]))
        XCTAssertNil(TerminalPrompt.locate(rows: ["❯ git status", "clean", "❯ "]))
    }

    func testVimScreen() {
        let rows = ["fn main() {", "    let a = b > c;", "}", "~", "~", "~", "\"main.rs\" 3L, 30B"]
        XCTAssertNil(TerminalPrompt.locate(rows: rows))
    }

    func testVimSplitScreen() {
        let rows = ["fn main() {       │> quoted", "    a > b         │~", "~                 │~",
                    "main.rs ──────────┴──────── other.rs"]
        XCTAssertNil(TerminalPrompt.locate(rows: rows))
    }

    func testTmuxStatusLine() {
        let rows = ["$ make test", "ok", "> ", "", "[0] 0:zsh*                         \"host\" 12:00 29-Oct-26"]
        XCTAssertNil(TerminalPrompt.locate(rows: rows))
    }

    func testTmuxSplitWithShellOnly() {
        let rows = ["$ ls          │$ top", "> │", "──────────────┼──────", "              │"]
        XCTAssertNil(TerminalPrompt.locate(rows: rows))
    }

    func testRulesInOtherPaneDoNotCount() {
        // The rules belong to the left pane; the prompt is in the right one.
        let rows = ["──────────│", "text      │❯ hi", "──────────│"]
        XCTAssertNil(TerminalPrompt.locate(rows: rows))
    }

    func testMarkMustBeFollowedBySpace() {
        XCTAssertNil(TerminalPrompt.locate(rows: [rule, ">>> code", rule]))
    }

    func testCodexStylePromptMark() {
        assertLocate([rule, "› explain this", rule], row: 1, column: 14, preceding: "s")
    }
}
