import AppKit

/// Inserts text into whichever app has keyboard focus.
enum TextInserter {
    /// Inserts `text` now. With paste, the person's clipboard is restored after the app is
    /// done with it; if the app hasn't read the paste within 1 s, `text` is left on the
    /// clipboard instead and `notRead` runs, so a late read or the person's Cmd-V still
    /// inserts it.
    @MainActor
    static func insert(_ text: String, method: InsertionMethod, notRead: @escaping @MainActor () -> Void = {}) {
        switch method {
        case .type: type(text)
        case .paste:
            let paste = startPaste(text)
            Task { @MainActor in
                _ = await paste.waitForRead()
                finish(paste, text: text, notRead: notRead)
            }
        }
    }

    /// What `insertAndWait` returns.
    struct Inserted {
        fileprivate let paste: PromisedText?
        /// Whether the app has read the text by now; typed text always counts. A read can
        /// arrive after the 1 s wait, so this is checked again just before acting on it.
        var wasRead: Bool { paste?.wasRead ?? true }
    }

    /// Inserts `text` and returns once the app has it: with paste, once the app has read
    /// the clipboard, or after 1 s if it never does. While the result isn't `wasRead`, a
    /// second paste could land before this one, so don't send one. Pass
    /// `restoringClipboard: false` when another insert follows, then let the last one
    /// restore it, so the person's clipboard comes back once; if that last one isn't read
    /// in time, its text is left on the clipboard instead.
    @MainActor @discardableResult
    static func insertAndWait(_ text: String, method: InsertionMethod, restoringClipboard: Bool = true) async -> Inserted {
        switch method {
        case .type:
            type(text)
            return Inserted(paste: nil)
        case .paste:
            // A paste right after another waits until at least 40 ms after that Cmd-V, so
            // the app has handled the first before the clipboard changes.
            if let last = pending?.text.postedAt {
                let wait = Self.minimumGap - Date().timeIntervalSince(last)
                if wait > 0 { try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000)) }
            }
            let paste = startPaste(text)
            _ = await paste.waitForRead()
            if restoringClipboard { finish(paste, text: text) }
            return Inserted(paste: paste)
        }
    }

    /// Restores the person's clipboard once the app has read `paste`; otherwise leaves
    /// `text` on the clipboard as plain text, so it can still be pasted.
    @MainActor
    private static func finish(_ paste: PromisedText, text: String, notRead: @MainActor () -> Void = {}) {
        if paste.wasRead {
            restoreClipboard()
        } else {
            copyToClipboard(text)
            notRead()
        }
    }
    private static let minimumGap: TimeInterval = 0.04

    /// Adds a leading space when continuing after a word, so dictated
    /// phrases don't run into existing text.
    static func applySmartSpacing(_ text: String, after preceding: Character?) -> String {
        guard let preceding, !preceding.isZeroWidth, let first = text.first else { return text }
        if preceding.isWhitespace || "([{\"'“‘/-".contains(preceding) { return text }
        if ".,;:!?)]}…".contains(first) { return text }
        return " " + text
    }

    /// Copies to the clipboard (used when no text field has focus).
    static func copyToClipboard(_ text: String) {
        pending = nil
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    // MARK: Paste, then restore the clipboard

    /// The clipboard as it was before our pastes that haven't been restored yet, and the
    /// change count our last paste left, so a paste right after another one restores
    /// the person's clipboard, not ours.
    private static var pending: (saved: [NSPasteboardItem], change: Int, text: PromisedText)?

    /// Puts `text` on the clipboard as a promise, so Hushhh learns when the app reads
    /// it, and presses Cmd-V.
    private static func startPaste(_ text: String) -> PromisedText {
        let pasteboard = NSPasteboard.general
        let saved = pending.flatMap { $0.change == pasteboard.changeCount ? $0.saved : nil } ?? snapshot(pasteboard)
        let promised = PromisedText(text)

        pasteboard.clearContents()
        let item = NSPasteboardItem()
        item.setDataProvider(promised, forTypes: [.string])
        // Clipboard managers skip items marked transient.
        item.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.TransientType"))
        pasteboard.writeObjects([item])
        pending = (saved, pasteboard.changeCount, promised)

        pressPaste()
        promised.postedAt = Date()
        return promised
    }

    /// Puts back the clipboard our pastes replaced, unless something else has written to
    /// it since. It waits until 1 s after the last Cmd-V, since some apps read the
    /// clipboard again after the paste itself; a newer paste of ours takes this over.
    @MainActor
    static func restoreClipboard() {
        guard let last = pending else { return }
        let delay = max(0, Self.restoreDelay - Date().timeIntervalSince(last.text.postedAt))
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            guard let pending, pending.text === last.text else { return }
            self.pending = nil
            let pasteboard = NSPasteboard.general
            guard pasteboard.changeCount == pending.change else { return }
            pasteboard.clearContents()
            if !pending.saved.isEmpty { pasteboard.writeObjects(pending.saved) }
        }
    }
    private static let restoreDelay: TimeInterval = 1.0

    private static func snapshot(_ pasteboard: NSPasteboard) -> [NSPasteboardItem] {
        (pasteboard.pasteboardItems ?? []).map { item in
            let copy = NSPasteboardItem()
            for type in item.types {
                if let data = item.data(forType: type) { copy.setData(data, forType: type) }
            }
            return copy
        }
    }

    private static func pressPaste() {
        let source = CGEventSource(stateID: .combinedSessionState)
        for step in PasteKeystrokes.events(physicallyHeld: CGEventSource.flagsState(.hidSystemState)) {
            let event = CGEvent(keyboardEventSource: source, virtualKey: step.key, keyDown: step.isDown)
            event?.flags = step.flags
            event?.post(tap: .cghidEventTap)
        }
    }

    // MARK: Type as Unicode key events

    static func type(_ text: String) {
        let source = CGEventSource(stateID: .combinedSessionState)
        // About 20 UTF-16 units per event, split only between characters so an emoji's
        // surrogate pair is never cut in two.
        var chunks: [[UInt16]] = [[]]
        for character in text {
            let units = Array(String(character).utf16)
            if chunks[chunks.count - 1].count + units.count > 20, !chunks[chunks.count - 1].isEmpty { chunks.append([]) }
            chunks[chunks.count - 1] += units
        }
        for chunk in chunks where !chunk.isEmpty {
            for keyDown in [true, false] {
                let event = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: keyDown)
                event?.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: chunk)
                event?.post(tap: .cghidEventTap)
            }
            usleep(2_000)
        }
    }
}

/// Text promised to the clipboard, supplied when the app asks for it, which tells
/// Hushhh the paste has been read.
fileprivate final class PromisedText: NSObject, NSPasteboardItemDataProvider {
    let text: String
    /// When Cmd-V was posted for it.
    var postedAt = Date()
    private var read = false
    /// Whether the app has read the text, even after the wait for it ended.
    var wasRead: Bool { read }
    private var waiters: [CheckedContinuation<Void, Never>] = []

    /// Long enough for slow apps (Electron, remote desktops) to read the paste.
    private static let fallback: UInt64 = 1_000_000_000
    /// Lets the app finish handling the paste before a second paste changes the clipboard.
    private static let settle: UInt64 = 30_000_000

    init(_ text: String) { self.text = text }

    func pasteboard(_ pasteboard: NSPasteboard?, item: NSPasteboardItem,
                    provideDataForType type: NSPasteboard.PasteboardType) {
        item.setString(text, forType: type)
        DispatchQueue.main.async { self.finish(read: true) }
    }

    func pasteboardFinishedWithDataProvider(_ pasteboard: NSPasteboard) {}

    /// Returns once the app has read the text (plus a short settle), or after the fallback.
    /// Returns whether the app read it.
    @MainActor
    func waitForRead() async -> Bool {
        if !read {
            await withCheckedContinuation { continuation in
                waiters.append(continuation)
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: Self.fallback)
                    self.finish(read: false)
                }
            }
        }
        if read { try? await Task.sleep(nanoseconds: Self.settle) }
        return read
    }

    private func finish(read: Bool) {
        if read { self.read = true }
        let waiting = waiters
        waiters = []
        waiting.forEach { $0.resume() }
    }
}
