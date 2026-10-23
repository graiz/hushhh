import AppKit
import ApplicationServices

/// Finds the caret through text markers, the position API WebKit and Chromium offer
/// for rich web editors (contenteditable). Those editors often answer index-based
/// lookups with nothing, or with positions from the wrong line.
enum TextMarkerCaret {
    struct Result {
        /// Caret in Accessibility coordinates (top-left origin).
        let caret: CGRect
        /// Left edge of the caret's line, in Accessibility coordinates.
        let lineStartX: CGFloat?
        let preceding: Character?
        let following: Character?
        /// Attributes of the character before the caret (AXFont, AXForegroundColor).
        let attributes: [NSAttributedString.Key: Any]
        /// Box of the selected text when the selection isn't empty, in Accessibility coordinates.
        let selection: CGRect?
    }

    static func locate(_ element: AXUIElement) -> Result? {
        guard let (host, selected) = selectedRange(from: element) else { return nil }
        let start = AXTextMarkerRangeCopyStartMarker(selected)
        let end = AXTextMarkerRangeCopyEndMarker(selected)

        let previous = marker(host, "AXPreviousTextMarkerForTextMarker", start)
        let before = previous.map { range($0, start) }
        let preceding = before.flatMap { string(host, $0) }?.last
        let following = marker(host, "AXNextTextMarkerForTextMarker", end).flatMap { string(host, range(end, $0)) }?.first

        // Some editors (Slack) give no box for a range built from the caret marker, but do
        // for their own empty selection.
        let zero = bounds(host, range(start, start)).flatMap(usable)
            ?? (CFEqual(start, end) ? bounds(host, selected).flatMap(usable) : nil)
        var caret: CGRect?
        if let before, preceding?.isNewline != true, let box = bounds(host, before).flatMap(usable) {
            // The collapsed box is the most precise, but only when it sits on the
            // previous character's line.
            if let zero, abs(zero.midY - box.midY) < box.height * 0.5, zero.minX >= box.minX, zero.minX <= box.maxX + 1 {
                caret = CGRect(x: zero.minX, y: box.minY, width: 1, height: box.height)
            } else {
                caret = CGRect(x: box.maxX, y: box.minY, width: 1, height: box.height)
            }
        } else if before == nil || preceding?.isNewline == true,
                  let next = marker(host, "AXNextTextMarkerForTextMarker", start),
                  let box = bounds(host, range(start, next)).flatMap(usable), box.width > 0,
                  zero.map({ box.height <= $0.height * 1.5 }) ?? true {
            // At the start of a line: the leading edge of the character after the caret.
            // With an unusable preceding box this is skipped, as the next character may sit on the next line,
            // and the collapsed box is used instead when the next character's box spans more than a line, as in an empty field.
            caret = CGRect(x: box.minX, y: box.minY, width: 1, height: box.height)
        } else if let zero {
            caret = CGRect(x: zero.minX, y: zero.minY, width: 1, height: zero.height)
        }
        guard let caret else { return nil }

        let attributed = before.flatMap { attributedString(host, $0) }
        let attributes = attributed.map { $0.length > 0 ? $0.attributes(at: 0, effectiveRange: nil) : [:] } ?? [:]
        // Markers can differ by node yet sit at one position, so require a visible width.
        let selection = CFEqual(start, end) ? nil : bounds(host, selected).flatMap(usable).flatMap { $0.width > 1 ? $0 : nil }
        return Result(caret: caret, lineStartX: lineStartX(host, start), preceding: preceding, following: following,
                      attributes: attributes, selection: selection)
    }

    /// The selection, asked of the focused element first and then of its ancestors up
    /// to the web page, since some engines answer only at the page level.
    private static func selectedRange(from element: AXUIElement) -> (AXUIElement, AXTextMarkerRange)? {
        var node: AXUIElement? = element
        for _ in 0..<40 {
            guard let current = node else { return nil }
            var value: CFTypeRef?
            if AXUIElementCopyAttributeValue(current, "AXSelectedTextMarkerRange" as CFString, &value) == .success,
               let value, CFGetTypeID(value) == AXTextMarkerRangeGetTypeID() {
                return (current, value as! AXTextMarkerRange)
            }
            var role: CFTypeRef?
            AXUIElementCopyAttributeValue(current, kAXRoleAttribute as CFString, &role)
            if (role as? String) == "AXWebArea" { return nil }
            var parent: CFTypeRef?
            guard AXUIElementCopyAttributeValue(current, kAXParentAttribute as CFString, &parent) == .success,
                  let parent, CFGetTypeID(parent) == AXUIElementGetTypeID() else { return nil }
            node = (parent as! AXUIElement)
        }
        return nil
    }

    /// Left edge of the first character on the marker's line.
    private static func lineStartX(_ host: AXUIElement, _ marker: AXTextMarker) -> CGFloat? {
        var value: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(host, "AXLineTextMarkerRangeForTextMarker" as CFString, marker, &value) == .success,
              let value, CFGetTypeID(value) == AXTextMarkerRangeGetTypeID() else { return nil }
        let first = AXTextMarkerRangeCopyStartMarker(value as! AXTextMarkerRange)
        guard let second = self.marker(host, "AXNextTextMarkerForTextMarker", first),
              let box = bounds(host, range(first, second)).flatMap(usable) else { return nil }
        return box.minX
    }

    private static func range(_ start: AXTextMarker, _ end: AXTextMarker) -> AXTextMarkerRange {
        AXTextMarkerRangeCreate(kCFAllocatorDefault, start, end)
    }

    private static func marker(_ host: AXUIElement, _ attribute: String, _ from: AXTextMarker) -> AXTextMarker? {
        var value: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(host, attribute as CFString, from, &value) == .success,
              let value, CFGetTypeID(value) == AXTextMarkerGetTypeID() else { return nil }
        let found = value as! AXTextMarker
        // At either end of the document some engines hand back the same marker.
        return CFEqual(found, from) ? nil : found
    }

    private static func bounds(_ host: AXUIElement, _ range: AXTextMarkerRange) -> CGRect? {
        var value: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(host, "AXBoundsForTextMarkerRange" as CFString, range, &value) == .success,
              let value, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var rect = CGRect.zero
        return AXValueGetValue(value as! AXValue, .cgRect, &rect) ? rect : nil
    }

    private static func string(_ host: AXUIElement, _ range: AXTextMarkerRange) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(host, "AXStringForTextMarkerRange" as CFString, range, &value) == .success,
              let text = value as? String, !text.isEmpty else { return nil }
        return text
    }

    private static func attributedString(_ host: AXUIElement, _ range: AXTextMarkerRange) -> NSAttributedString? {
        var value: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(host, "AXAttributedStringForTextMarkerRange" as CFString, range, &value) == .success
        else { return nil }
        return value as? NSAttributedString
    }

    private static func usable(_ rect: CGRect) -> CGRect? {
        rect.height > 1 && rect.origin != .zero ? rect : nil
    }
}
