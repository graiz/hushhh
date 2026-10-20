import AppKit
import Carbon.HIToolbox

/// Inserts text into whichever app has keyboard focus.
enum TextInserter {
    static func insert(_ text: String, method: InsertionMethod) {
        switch method {
        case .paste: paste(text)
        case .type: type(text)
        }
    }

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
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    // MARK: Paste, then restore the clipboard

    private static func paste(_ text: String) {
        let pasteboard = NSPasteboard.general
        let saved = snapshot(pasteboard)

        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        // Clipboard managers skip items marked transient.
        pasteboard.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.TransientType"))
        let ourChange = pasteboard.changeCount

        postKey(CGKeyCode(kVK_ANSI_V), flags: .maskCommand)

        // Long enough for slow apps (Electron, remote desktops) to read the paste first.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            // Only restore if nothing else has written to the clipboard since.
            guard pasteboard.changeCount == ourChange else { return }
            pasteboard.clearContents()
            if !saved.isEmpty { pasteboard.writeObjects(saved) }
        }
    }

    private static func snapshot(_ pasteboard: NSPasteboard) -> [NSPasteboardItem] {
        (pasteboard.pasteboardItems ?? []).map { item in
            let copy = NSPasteboardItem()
            for type in item.types {
                if let data = item.data(forType: type) { copy.setData(data, forType: type) }
            }
            return copy
        }
    }

    private static func postKey(_ key: CGKeyCode, flags: CGEventFlags) {
        let source = CGEventSource(stateID: .combinedSessionState)
        let down = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: true)
        let up = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: false)
        down?.flags = flags
        up?.flags = flags
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
    }

    /// Selects the text Hushhh typed this session (`typed`, starting at `location`) so a
    /// paste or delete replaces exactly it. Succeeds only if the app lets us set the
    /// selection and the selected text reads back as what we typed.
    static func selectTyped(_ typed: String, in element: AXUIElement, at location: Int) -> Bool {
        var settable: DarwinBoolean = false
        guard AXUIElementIsAttributeSettable(element, kAXSelectedTextRangeAttribute as CFString, &settable) == .success,
              settable.boolValue else { return false }
        let length = (typed as NSString).length
        var range = CFRange(location: location, length: length)
        guard let value = AXValueCreate(.cfRange, &range),
              AXUIElementSetAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, value) == .success else { return false }
        usleep(30_000)   // let the app apply the selection
        var selected: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXSelectedTextAttribute as CFString, &selected)
        func normalized(_ s: String) -> String {
            s.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "\u{00A0}", with: " ")
        }
        guard let text = selected as? String, normalized(text) == normalized(typed) else {
            // Not what we typed: put the caret back at the end and leave the text alone.
            var end = CFRange(location: location + length, length: 0)
            if let back = AXValueCreate(.cfRange, &end) {
                AXUIElementSetAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, back)
            }
            return false
        }
        return true
    }

    /// Deletes the last `count` characters before the caret (used to undo a cancelled session).
    static func deleteBackward(_ count: Int) {
        for _ in 0..<count {
            postKey(CGKeyCode(kVK_Delete), flags: [])
            usleep(1_500)
        }
    }

    // MARK: Type as Unicode key events

    static func type(_ text: String) {
        let source = CGEventSource(stateID: .combinedSessionState)
        let utf16 = Array(text.utf16)
        var index = 0
        while index < utf16.count {
            let chunk = Array(utf16[index..<min(index + 20, utf16.count)])
            for keyDown in [true, false] {
                let event = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: keyDown)
                event?.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: chunk)
                event?.post(tap: .cghidEventTap)
            }
            index += 20
            usleep(2_000)
        }
    }
}
