import AppKit
import ApplicationServices

/// Where the person is typing: the focused element, its caret position on
/// screen, and the character just before the insertion point.
struct FocusContext {
    let element: AXUIElement?
    let appPID: pid_t?
    /// Caret rectangle in Cocoa screen coordinates (origin bottom-left).
    let caretRect: CGRect?
    /// Frame of the focused element in Cocoa screen coordinates.
    let elementFrame: CGRect?
    let isEditable: Bool
    let precedingCharacter: Character?
    /// Set when the caret sits at the end of a line, so ghost text can be drawn inline.
    let inline: InlineStyle?
    /// A password field: Hushhh never dictates into these.
    var isSecure = false
    /// Selection when the context was captured.
    var selection: CFRange? = nil
    /// Font reported next to the caret, used to estimate layout in bubble mode too.
    var font: NSFont? = nil
    /// How the caret was found.
    var caretSource: CaretSource = .none

    enum CaretSource: String {
        /// The app reported character positions (most native apps).
        case accessibility
        /// A web editor's own caret element, e.g. Google Docs' `kix-cursor-caret`.
        case pageCaret
        /// WebKit's and Chromium's text markers (rich web editors).
        case textMarker
        /// A web code editor's hidden input, which it moves to the caret (VS Code, CodeMirror).
        case hiddenInput
        /// Hushhh laid out the field's text itself (apps that report no positions).
        case estimated
        case none
    }

    /// How to draw ghost text so it looks like part of the document.
    struct InlineStyle {
        let caret: CGRect
        let font: NSFont?
        let color: NSColor?
        /// Left edge of the caret's line, where wrapped lines start.
        let lineStartX: CGFloat
        /// Right edge of the text area, where lines wrap.
        let rightEdgeX: CGFloat
        /// Text fields and spreadsheet cells: ghost text stays on one line.
        let singleLine: Bool
        /// Width of a block cursor (terminals); ghost text starts after it so the
        /// cursor doesn't hide the first letter.
        var cursorWidth: CGFloat = 0
        /// Screen box of selected text that dictation will replace. The ghost text is
        /// drawn over it on an opaque backdrop so the old text doesn't show through.
        var replacing: CGRect?
        /// The text field's frame; the scrim never extends past it.
        var bounds: CGRect?
        /// Native text views put extra line spacing below the text, so ghost text aligns
        /// to the top of the caret. Web pages (CSS) and terminals centre it in the line.
        var alignsToTop = false
        /// The field's own background colour, when the app reports it.
        var background: NSColor?
    }

    static let terminalBundleIDs: Set<String> = [
        "com.apple.Terminal", "com.mitchellh.ghostty", "com.googlecode.iterm2", "dev.warp.Warp-Stable",
        "net.kovidgoyal.kitty", "org.alacritty", "io.alacritty", "com.github.wez.wezterm",
    ]

    static let textRoles: Set<String> = [
        kAXTextFieldRole, kAXTextAreaRole, kAXComboBoxRole, "AXSearchField",
    ]

    /// - Parameter pid: inspect this app instead of the frontmost one (diagnostics).
    /// - Parameter forceInline: place ghost text even mid-line (alignment tests).
    /// - Parameter preferTextMarkers: skip index lookups and use text markers (alignment tests).
    static func capture(pid: pid_t? = nil, forceInline: Bool = false,
                        preferTextMarkers: Bool = false) -> FocusContext {
        let targetPID = pid ?? NSWorkspace.shared.frontmostApplication?.processIdentifier
        let root: AXUIElement
        var justEnabled = false
        if let targetPID {
            root = AXUIElementCreateApplication(targetPID)
            // Only when dictation starts, never in the background: switching this on costs
            // Chromium apps some CPU and memory.
            justEnabled = enableAccessibility(pid: targetPID)
        } else {
            root = AXUIElementCreateSystemWide()
        }
        AXUIElementSetMessagingTimeout(root, 0.25)

        var focused: AXUIElement? = copyElement(root, kAXFocusedUIElementAttribute)
        if focused == nil, justEnabled || targetPID.map({ appKind(pid: $0) == .electron }) == true {
            // Chromium and Electron build their accessibility tree just after being asked;
            // give it one moment.
            usleep(150_000)
            focused = copyElement(root, kAXFocusedUIElementAttribute)
        }
        guard let element = focused else {
            return FocusContext(element: nil, appPID: targetPID, caretRect: nil,
                                elementFrame: nil, isEditable: false, precedingCharacter: nil, inline: nil)
        }
        AXUIElementSetMessagingTimeout(element, 0.25)

        let role: String = copyValue(element, kAXRoleAttribute) ?? ""
        let subrole: String = copyValue(element, kAXSubroleAttribute) ?? ""
        if subrole == kAXSecureTextFieldSubrole {
            var context = FocusContext(element: element, appPID: targetPID, caretRect: nil, elementFrame: nil,
                                       isEditable: false, precedingCharacter: nil, inline: nil)
            context.isSecure = true
            return context
        }
        let range = selectedRange(element)
        var settable: DarwinBoolean = false
        AXUIElementIsAttributeSettable(element, kAXValueAttribute as CFString, &settable)
        var isEditable = textRoles.contains(role) || (range != nil && settable.boolValue)
        let isWeb = isWebContent(element)

        var preceding: Character?
        var following: Character?
        let value: String? = copyValue(element, kAXValueAttribute)
        if let range {
            let end = range.location + max(range.length, 0)
            // Ask for the characters directly: in web and Electron editors the value's
            // indices don't always line up with the selection.
            if range.location > 0 {
                preceding = string(element, CFRange(location: range.location - 1, length: 1))?.last
            }
            following = string(element, CFRange(location: end, length: 1))?.first
            if let value {
                let ns = value as NSString
                if preceding == nil, range.location > 0, range.location <= ns.length {
                    preceding = ns.substring(with: ns.rangeOfComposedCharacterSequence(at: range.location - 1)).first
                }
                if following == nil, end < ns.length {
                    following = ns.substring(with: ns.rangeOfComposedCharacterSequence(at: end)).first
                }
            }
        }

        // Web editors pad their hidden input with zero-width characters (Google Docs
        // uses U+200B); they aren't real text, so don't let them drive spacing.
        if let c = preceding, c.isZeroWidth { preceding = nil }
        if let c = following, c.isZeroWidth { following = nil }

        var caret = preferTextMarkers ? nil : range.flatMap { caretRect(element, range: $0, precedingIsNewline: preceding?.isNewline == true) }
        let frame = elementFrame(element)
        var source: CaretSource = caret != nil ? .accessibility : .none
        var fallbackInline: InlineStyle?

        // Rich web editors that answer index lookups with nothing: ask with text markers,
        // but only in editable content, since a page's own selection is not a typing caret.
        if caret == nil, isWeb, isEditable || copyElement(element, "AXEditableAncestor") != nil,
           // Code editors' hidden inputs have their own block below.
           !(axFrame(element).map(HiddenInput.isHidden) ?? false),
           let found = TextMarkerCaret.locate(element),
           // Some editors report a box far taller than a line near the caret.
           CaretCheck.isPlausible(toCocoa(found.caret), in: frame.flatMap { isUsable($0) ? $0 : nil }) {
            let markerCaret = toCocoa(found.caret)
            caret = markerCaret
            source = .textMarker
            if preceding == nil, let c = found.preceding, !c.isZeroWidth { preceding = c }
            if following == nil, let c = found.following, !c.isZeroWidth { following = c }
            // A caret inside an editable region means the page takes typing here.
            isEditable = true
            let style = textStyle(from: found.attributes, pid: targetPID)
            let rightEdge = frame.map { max(markerCaret.maxX + 120, $0.maxX) } ?? markerCaret.minX + 480
            var built = InlineStyle(caret: markerCaret, font: style.font, color: style.color,
                                    lineStartX: min(found.lineStartX ?? markerCaret.minX, markerCaret.minX),
                                    rightEdgeX: rightEdge, singleLine: role == kAXTextFieldRole)
            built.replacing = found.selection.map(toCocoa)
            built.background = style.background
            fallbackInline = built
        }

        // Web editors that draw text themselves (Google Docs) keep a caret element in the page.
        if caret == nil, isWeb, let found = pageCaret(app: root) {
            caret = found.caret
            source = .pageCaret
            // A live caret in a web editor means the page is accepting typing, even
            // though its hidden input isn't a standard text field.
            isEditable = true
            // The hidden input carries no URL; the window title names the app.
            let windowTitle: String = copyElement(root, kAXFocusedWindowAttribute).flatMap { copyValue($0, kAXTitleAttribute) } ?? ""
            let docs = windowTitle.contains("Google Docs")
                || (copyValue(element, "AXURL") as URL?)?.absoluteString.contains("docs.google.com/document") == true
            let font = docs ? NSFont(name: "Arial", size: found.caret.height / 1.16)
                            : NSFont.systemFont(ofSize: min(28, max(11, found.caret.height / 1.25)))
            // Google Docs' default margins are one inch of an 8.5-inch page.
            let margin = found.page.map { $0.width * 96 / 816 } ?? 0
            fallbackInline = InlineStyle(caret: found.caret, font: font, color: nil,
                                         lineStartX: found.page.map { $0.minX + margin } ?? found.caret.minX,
                                         rightEdgeX: found.page.map { $0.maxX - margin } ?? found.caret.maxX + 420,
                                         singleLine: false)
        }

        // Web code editors (VS Code, CodeMirror, Ace) type into a tiny textarea parked at
        // the caret. Read the line drawn there.
        if caret == nil, isWeb, let input = axFrame(element), HiddenInput.isHidden(input) {
            // Just right of the input (0–1 pt wide), so the hit test finds the text, not the input.
            let lineNode = lineElement(at: CGPoint(x: input.minX + 3, y: input.midY), app: root)
            let line = lineNode.flatMap(axFrame)
            if let found = HiddenInput.caret(input: input, line: line), isUsable(toCocoa(found).insetBy(dx: -10, dy: 0)) {
                let inputCaret = toCocoa(found)
                caret = inputCaret
                source = .hiddenInput
                isEditable = true
                let reported = range.map { textStyle(element, range: $0, hasPreceding: preceding != nil, pid: targetPID) }
                let font = reported?.font ?? NSFont.systemFont(ofSize: min(28, max(11, found.height / 1.35)))
                let lineStart = line.flatMap { HiddenInput.isLineClass(lineNode.flatMap { copyValue($0, "AXDOMClassList") } ?? []) ? toCocoa($0).minX : nil }
                var built = InlineStyle(caret: inputCaret, font: font, color: reported?.color,
                                        lineStartX: min(lineStart ?? inputCaret.minX, inputCaret.minX),
                                        rightEdgeX: inputCaret.minX + 480, singleLine: false)
                built.background = reported?.background
                fallbackInline = built
            }
        }

        let bundleID = targetPID.flatMap { NSRunningApplication(processIdentifier: $0)?.bundleIdentifier }
        let isTerminal = bundleID.map(terminalBundleIDs.contains) ?? false

        // Terminals that report their screen text but no positions (Ghostty): find
        // the cursor on the character grid. The cursor is at the end of the prompt.
        if caret == nil, isTerminal, let frame, isUsable(frame), let value, !value.isEmpty,
           let grid = terminalCaret(element, frame: frame, value: value, bundleID: bundleID) {
            caret = grid.caret
            source = .estimated
            preceding = grid.preceding
            following = nil
            var style = InlineStyle(caret: grid.caret, font: grid.font, color: nil,
                                    lineStartX: frame.minX + grid.padding, rightEdgeX: frame.maxX - grid.padding,
                                    singleLine: false)
            style.cursorWidth = grid.cellWidth
            fallbackInline = style
        }

        // Apps that report the field but no character positions (e.g. Superhuman):
        // lay the field's text out ourselves at its real width to find the caret.
        if caret == nil, !isTerminal, let frame, isUsable(frame), let range {
            let reported = textStyle(element, range: range, hasPreceding: preceding != nil, pid: targetPID)
            let font = reported.font ?? NSFont.systemFont(ofSize: 14)
            // Where the field's text starts inside its frame. Chromium's address bar draws
            // it 7 pt in (measured); web editors start at the edge.
            let description: String = copyValue(element, kAXDescriptionAttribute) ?? ""
            let addressBar = role == kAXTextFieldRole && description.localizedCaseInsensitiveContains("address")
            let inset: CGFloat = addressBar ? 7 : 0
            let textFrame = CGRect(x: frame.minX + inset, y: frame.minY, width: frame.width - 2 * inset, height: frame.height)
            if let estimate = estimateCaret(in: textFrame, text: value ?? "", upTo: range.location, font: font) {
                caret = estimate
                source = .estimated
                var built = InlineStyle(caret: estimate, font: font, color: reported.color,
                                        lineStartX: textFrame.minX, rightEdgeX: textFrame.maxX,
                                        singleLine: frame.height < estimate.height * 1.8 && role != kAXTextAreaRole)
                built.background = reported.background
                fallbackInline = built
            }
        }

        // Text after the caret only matters if it's on the caret's line.
        var atLineEnd = forceInline || following == nil || following?.isNewline == true
        if !atLineEnd, let caret, let range,
           let next = bounds(element, for: CFRange(location: range.location + max(range.length, 0), length: 1)),
           next.height > 1, toCocoa(next).maxY <= caret.minY + 1 {
            atLineEnd = true
        }

        // Inline ghost text only when nothing follows the caret on its line;
        // otherwise it would draw over existing words.
        var inline: InlineStyle?
        fallbackInline?.bounds = frame.flatMap { isUsable($0) ? $0 : nil }
        if source == .pageCaret || source == .estimated || source == .textMarker || source == .hiddenInput {
            // A hidden input's value is empty, so we can't tell if code follows the caret: no inline text over it.
            inline = (source == .hiddenInput ? forceInline : (atLineEnd || source == .pageCaret)) ? fallbackInline : nil
        } else if var caret, let range, atLineEnd {
            let style = textStyle(element, range: range, hasPreceding: preceding != nil, pid: targetPID)
            var lineStart = (preceding == nil || preceding?.isNewline == true)
                ? caret.minX
                : (lineStartX(element, index: range.location - 1) ?? caret.minX)

            // Some apps report a box that can't be one character: the whole field for
            // every character (Excel cells), or a collapsed one. Then measure the line's
            // text in the field's font from where the line starts.
            if !isTerminal, let value, range.location > 0,
               let preceding, !preceding.isNewline,
               let previous = bounds(element, for: CFRange(location: range.location - 1, length: 1)),
               !CaretMath.isPlausibleCharacterBox(previous, fontSize: style.font?.pointSize ?? 13) {
                let font = style.font ?? NSFont.systemFont(ofSize: 13)
                let ns = value as NSString
                let head = ns.substring(to: min(range.location, ns.length))
                let line = head.components(separatedBy: .newlines).last ?? head
                var measuredStart: CGFloat?
                if let startBox = lineStartBox(element, index: range.location - 1),
                   CaretMath.isPlausibleCharacterBox(startBox, fontSize: font.pointSize) {
                    measuredStart = startBox.minX
                } else if let frame {
                    measuredStart = frame.minX + 4   // Excel draws cell text 4 pt in from the cell edge (measured)
                }
                // Without an established line start the reported caret stands.
                if let measuredStart {
                    lineStart = measuredStart
                    caret = CGRect(x: CaretMath.caretX(lineStartX: lineStart, prefix: line, font: font,
                                                       limit: frame?.maxX ?? .greatestFiniteMagnitude),
                                   y: caret.minY, width: 1, height: caret.height)
                }
            }

            var rightEdge = caret.minX + 480
            if let frame {
                // Mirror the left inset of the text inside its view.
                let inset = max(0, min(lineStart - frame.minX, 40))
                rightEdge = max(caret.maxX + 120, frame.maxX - inset)
            }
            let singleLine = [kAXTextFieldRole, kAXComboBoxRole, "AXSearchField"].contains(role)
                || (frame.map { $0.height < caret.height * 1.8 } ?? false)
            var font = style.font
            // Web views report only the size; identify the family from how wide the
            // text before the caret really is.
            if let reported = font, reported.fontName.hasPrefix("."), !isTerminal, range.location > 0 {
                font = matchFont(element, before: range.location, size: reported.pointSize, lineHeight: caret.height) ?? reported
            }
            var cursorWidth: CGFloat = 0
            if isTerminal, range.location > 0, let cell = lastVisibleCell(element, before: range.location) {
                // Terminals (Terminal.app) report no font: use a monospaced one sized to the
                // character cell. Trailing spaces are reported as zero width, so count
                // cells on from the last visible character to find the cursor.
                font = font ?? monospacedFont(cellWidth: cell.box.width)
                cursorWidth = cell.box.width
                caret = CGRect(x: cell.box.maxX + CGFloat(cell.spacesAfter) * cell.box.width, y: cell.box.minY,
                               width: 1, height: cell.box.height)
            }
            var built = InlineStyle(caret: caret, font: font, color: style.color,
                                    lineStartX: min(lineStart, caret.minX), rightEdgeX: rightEdge,
                                    singleLine: singleLine)
            built.cursorWidth = cursorWidth
            built.bounds = frame.flatMap { isUsable($0) ? $0 : nil }
            built.alignsToTop = !isTerminal && !isWeb
            built.background = style.background
            if range.length > 0, let selected = bounds(element, for: range), selected.height > 1, selected.origin != .zero {
                built.replacing = toCocoa(selected)
            }
            inline = built
        }

        return FocusContext(element: element,
                            appPID: targetPID,
                            caretRect: caret,
                            elementFrame: frame,
                            isEditable: isEditable,
                            precedingCharacter: preceding,
                            inline: inline,
                            selection: range,
                            font: inline?.font ?? range.flatMap { textStyle(element, range: $0, hasPreceding: preceding != nil, pid: targetPID).font },
                            caretSource: source)
    }

    /// Font and colour of the text next to the caret.
    private static func textStyle(_ element: AXUIElement, range: CFRange, hasPreceding: Bool, pid: pid_t?) -> (font: NSFont?, color: NSColor?, background: NSColor?) {
        var probe = CFRange(location: hasPreceding ? range.location - 1 : range.location, length: 1)
        guard let param = AXValueCreate(.cfRange, &probe) else { return (nil, nil, nil) }
        var value: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(element, kAXAttributedStringForRangeParameterizedAttribute as CFString, param, &value) == .success,
              let attributed = value as? NSAttributedString, attributed.length > 0 else { return (nil, nil, nil) }
        return textStyle(from: attributed.attributes(at: 0, effectiveRange: nil), pid: pid)
    }

    /// Font, colour and background from the attributes an app reports for a run of text.
    private static func textStyle(from attrs: [NSAttributedString.Key: Any], pid: pid_t?) -> (font: NSFont?, color: NSColor?, background: NSColor?) {
        var font: NSFont?
        if let info = attrs[NSAttributedString.Key("AXFont")] as? [String: Any],
           let size = (info["AXFontSize"] as? NSNumber).map({ CGFloat($0.doubleValue) }) {
            let name = info["AXFontName"] as? String
            let family = (info["AXFontFamily"] as? String) ?? (info["AXVisibleName"] as? String)
            // Some apps send a system placeholder name (".AppleSystemUIFont") plus the real family.
            if let name, !name.hasPrefix("."), let named = NSFont(name: name, size: size) {
                font = named
            } else if let family, !family.hasPrefix("."),
                      let fromFamily = NSFontManager.shared.font(withFamily: family, traits: [], weight: 5, size: size)
                        ?? registerBundledFonts(pid: pid).flatMap({ _ in NSFontManager.shared.font(withFamily: family, traits: [], weight: 5, size: size) }) {
                font = fromFamily
            } else {
                font = NSFont.systemFont(ofSize: size)
            }
        }
        func colour(_ key: String) -> NSColor? {
            guard let raw = attrs[NSAttributedString.Key(key)], CFGetTypeID(raw as CFTypeRef) == CGColor.typeID else { return nil }
            return NSColor(cgColor: raw as! CGColor)
        }
        return (font, colour("AXForegroundColor"), colour("AXBackgroundColor"))
    }

    private static var registeredFontBundles: Set<String> = []

    /// Apps like Microsoft Office ship fonts inside their bundle. Register them
    /// for this process only, so ghost text can be measured and drawn in them.
    /// Returns nil when there was nothing new to register.
    private static func registerBundledFonts(pid: pid_t?) -> Void? {
        guard let pid, let bundle = NSRunningApplication(processIdentifier: pid)?.bundleURL,
              !registeredFontBundles.contains(bundle.path) else { return nil }
        registeredFontBundles.insert(bundle.path)
        var urls: [URL] = []
        for folder in ["Contents/Resources/DFonts", "Contents/Resources/Fonts"] {
            let dir = bundle.appendingPathComponent(folder)
            let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
            urls += files.filter { ["ttf", "otf", "ttc"].contains($0.pathExtension.lowercased()) }
        }
        guard !urls.isEmpty else { return nil }
        CTFontManagerRegisterFontURLs(urls as CFArray, .process, false, nil)
        return ()
    }

    /// Screen x of the first character on the line containing `index`.
    private static func lineStartX(_ element: AXUIElement, index: Int) -> CGFloat? {
        lineStartBox(element, index: index)?.minX
    }

    /// Box (Accessibility coordinates) of the first character on the line containing `index`.
    private static func lineStartBox(_ element: AXUIElement, index: Int) -> CGRect? {
        var lineValue: CFTypeRef?
        guard index >= 0,
              AXUIElementCopyParameterizedAttributeValue(element, kAXLineForIndexParameterizedAttribute as CFString,
                                                         NSNumber(value: index), &lineValue) == .success,
              let line = lineValue as? NSNumber else { return nil }
        var rangeValue: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(element, kAXRangeForLineParameterizedAttribute as CFString,
                                                         line, &rangeValue) == .success,
              let rangeValue, CFGetTypeID(rangeValue) == AXValueGetTypeID() else { return nil }
        var lineRange = CFRange()
        guard AXValueGetValue(rangeValue as! AXValue, .cfRange, &lineRange) else { return nil }
        guard let rect = bounds(element, for: CFRange(location: lineRange.location, length: 1)),
              rect.height > 1, rect.origin != .zero else { return nil }
        return rect
    }

    /// The attributes Hushhh itself switched on, per app, for the current dictation session.
    /// Only these are switched off again; one that was already on belongs to someone else.
    private static var switchedOn: [pid_t: [String]] = [:]

    private static func isOn(_ app: AXUIElement, _ name: String) -> Bool {
        var value: CFTypeRef?
        AXUIElementCopyAttributeValue(app, name as CFString, &value)
        return (value as? Bool) == true
    }

    private static func appKind(pid: pid_t) -> AppKind {
        let running = NSRunningApplication(processIdentifier: pid)
        return AppKind.of(bundleURL: running?.bundleURL, bundleID: running?.bundleIdentifier)
    }

    /// Chromium browsers only report text positions once AXEnhancedUserInterface is on, so
    /// Hushhh switches that on for the session. It never sets AXManualAccessibility: it
    /// makes VS Code switch into its screen-reader mode, and Electron reads it back as
    /// false, so Hushhh couldn't tell whether another assistive app had set it and would
    /// switch that app's setting off on release. Electron builds its tree when queried.
    /// Returns true if this call switched an attribute on.
    @discardableResult
    static func enableAccessibility(pid: pid_t) -> Bool {
        guard switchedOn[pid] == nil else { return false }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.25)
        let names = appKind(pid: pid) == .chromium ? ["AXEnhancedUserInterface"] : []
        var set: [String] = []
        for name in names where !isOn(app, name) {
            // Chromium applies the change yet reports cannotComplete, so check the value too.
            let result = AXUIElementSetAttributeValue(app, name as CFString, kCFBooleanTrue)
            if result == .success || isOn(app, name) { set.append(name) }
        }
        switchedOn[pid] = set
        return !set.isEmpty
    }

    /// Switches off the accessibility attributes Hushhh switched on this session, so apps
    /// stop paying for an accessibility tree nobody is reading. Attributes that were
    /// already on (another assistive app's) are left alone: switching them off would
    /// break that app.
    static func releaseAccessibility() {
        for (pid, attributes) in switchedOn {
            let app = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(app, 0.25)
            for name in attributes { AXUIElementSetAttributeValue(app, name as CFString, kCFBooleanFalse) }
        }
        switchedOn = [:]
    }

    // MARK: AX helpers

    /// Finds a terminal's cursor from its visible screen text. Ghostty reports every
    /// screen row padded with spaces to the terminal's width, which also gives us the
    /// grid size: columns = row length, rows = row count.
    private static func terminalCaret(_ element: AXUIElement, frame: CGRect, value: String, bundleID: String?)
        -> (caret: CGRect, font: NSFont, cellWidth: CGFloat, padding: CGFloat, preceding: Character?)? {
        let ns = value as NSString
        var start = 0
        if let visible = axValue(element, "AXVisibleCharacterRange") {
            var r = CFRange()
            if AXValueGetValue(visible, .cfRange, &r), r.location >= 0, r.location < ns.length { start = r.location }
        }
        var rows = ns.substring(from: start).components(separatedBy: "\n")
        if rows.count > 1, rows.last?.isEmpty == true { rows.removeLast() }
        let totalRows = rows.count
        let columns = rows.map(displayWidth).max() ?? 0

        var lines = rows
        // Blank rows below the prompt aren't where the cursor is.
        while lines.count > 1, lines.last?.trimmingCharacters(in: .whitespaces).isEmpty == true { lines.removeLast() }
        // No visible prompt (e.g. a full-screen TUI): the cursor could be anywhere.
        guard let line = lines.last, totalRows > 0, columns > 0 else { return nil }
        let content = line.replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression)
        guard !content.isEmpty else { return nil }
        // Full-screen apps (Claude Code, vim, tmux) end the screen with a bordered status
        // line, not a prompt; there the cursor could be anywhere.
        guard !["│", "┃", "║", "────"].contains(where: { content.contains($0) }) else { return nil }

        let config = bundleID == "com.mitchellh.ghostty" ? ghosttyConfig() : [:]
        let paddingX = config["window-padding-x"].flatMap(Double.init).map { CGFloat($0) } ?? 4
        let paddingY = config["window-padding-y"].flatMap(Double.init).map { CGFloat($0) } ?? paddingX

        // The grid fills the window minus padding, with less than one cell left over.
        let innerWidth = frame.width - 2 * paddingX
        let innerHeight = frame.height - 2 * paddingY
        let size = config["font-size"].flatMap(Double.init).map { CGFloat($0) } ?? 13
        // Ghostty's cell is 0.6 em wide and 1.32 em tall (JetBrains Mono), snapped to
        // whole device pixels.
        let pixelScale = NSScreen.screens.first { $0.frame.intersects(frame) }?.backingScaleFactor ?? 2
        let metricWidth = (size * 0.6 * pixelScale).rounded() / pixelScale
        let metricHeight = (size * 1.32 * pixelScale).rounded(.down) / pixelScale
        // Rows padded to the full width tell us the column count; trust the font metric
        // when it agrees, otherwise divide the window by the columns.
        let cellWidth = abs(Int(innerWidth / metricWidth) - columns) <= 2 ? metricWidth : innerWidth / (CGFloat(columns) + 0.5)
        // Ghostty only reports rows up to the cursor, so the row count says nothing about
        // the screen's height unless it fills it.
        let fillsScreen = abs(Int(innerHeight / metricHeight) - totalRows) <= 1
        let cellHeight = fillsScreen || CGFloat(totalRows) * metricHeight <= innerHeight
            ? metricHeight : innerHeight / (CGFloat(totalRows) + 0.5)
        let font = config["font-family"].flatMap { NSFontManager.shared.font(withFamily: $0, traits: [], weight: 5, size: cellWidth / 0.6) }
            ?? NSFont(name: "JetBrainsMono-Regular", size: cellWidth / 0.6)
            ?? monospacedFont(cellWidth: cellWidth)

        // Trailing spaces are padding, except a prompt usually ends with one space
        // before the cursor.
        let promptSpace = line.count > content.count ? 1 : 0
        let column = displayWidth(content) + promptSpace
        let row = lines.count - 1

        let x = frame.minX + paddingX + CGFloat(column) * cellWidth
        // The substitute font sits about 1 pt lower in the cell than JetBrains Mono (measured).
        let baselineNudge: CGFloat = config["font-family"] == nil ? 1 : 0
        let top = frame.maxY - paddingY - CGFloat(row) * cellHeight + baselineNudge
        guard x <= frame.maxX, top - cellHeight >= frame.minY else { return nil }
        let preceding: Character? = promptSpace == 1 ? " " : content.last
        return (CGRect(x: x, y: top - cellHeight, width: 1, height: cellHeight), font, cellWidth, paddingX, preceding)
    }

    /// Fonts commonly used on the web and in apps, tried when an app reports a font size
    /// but not its family.
    private static let candidateFamilies = [
        "Helvetica Neue", "Helvetica", "Arial", "Georgia", "Times New Roman", "Times", "Verdana",
        "Trebuchet MS", "Inter", "Roboto", "Open Sans", "Lato", "Menlo", "Courier New", "Charter", "Palatino",
    ]

    /// Picks the font whose character positions best match where the app drew the text
    /// just before the caret. Comparing every character boundary (not just the total
    /// width) separates fonts of similar width, e.g. Georgia and Helvetica. Returns nil
    /// (keep the system font) when nothing fits well.
    /// The last match per field, so the per-character lookups run once per field, not on
    /// every caret update.
    private static var fontCache: (key: Int, size: CGFloat, font: NSFont?, time: Date)?

    private static func matchFont(_ element: AXUIElement, before location: Int, size: CGFloat, lineHeight: CGFloat) -> NSFont? {
        let key = Int(CFHash(element))
        if let cached = fontCache, cached.key == key, cached.size == size, Date().timeIntervalSince(cached.time) < 120 {
            return cached.font
        }
        // Up to ~30 lookups: keep each one short so an unresponsive app can't stall us.
        AXUIElementSetMessagingTimeout(element, 0.05)
        defer { AXUIElementSetMessagingTimeout(element, 0.25) }
        let font = measureFont(element, before: location, size: size, lineHeight: lineHeight)
        fontCache = (key, size, font, Date())
        return font
    }

    private static func measureFont(_ element: AXUIElement, before location: Int, size: CGFloat, lineHeight: CGFloat) -> NSFont? {
        // Up to 30 characters before the caret, on the caret's line.
        var start = max(0, location - 30)
        var sample = string(element, CFRange(location: start, length: location - start)) ?? ""
        if let newline = sample.lastIndex(where: \.isNewline) {
            start += sample.distance(from: sample.startIndex, to: sample.index(after: newline))
            sample = String(sample[sample.index(after: newline)...])
        }
        let ns = sample as NSString
        guard ns.length >= 4, ns.length == location - start else { return nil }

        // Where the app put the left edge of each character, relative to the first.
        var positions: [CGFloat] = []
        var origin: CGRect?
        for i in 0..<ns.length {
            guard let box = bounds(element, for: CFRange(location: start + i, length: 1)), box.height > 1 else { return nil }
            if origin == nil { origin = box }
            guard abs(box.minY - origin!.minY) < lineHeight * 0.5 else { return nil }   // one line only
            positions.append(box.minX - origin!.minX)
        }
        positions.append((bounds(element, for: CFRange(location: location - 1, length: 1))?.maxX ?? 0) - origin!.minX)

        func error(_ font: NSFont) -> CGFloat {
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: sample, attributes: [.font: font]))
            var total: CGFloat = 0
            for (i, actual) in positions.enumerated() {
                let predicted = CTLineGetOffsetForStringIndex(line, min(i, ns.length), nil)
                total += (predicted - actual) * (predicted - actual)
            }
            return (total / CGFloat(positions.count)).squareRoot()
        }

        var best = NSFont.systemFont(ofSize: size)
        var bestError = error(best)
        for family in candidateFamilies {
            guard let font = NSFontManager.shared.font(withFamily: family, traits: [], weight: 5, size: size) else { continue }
            let e = error(font)
            if e < bestError { best = font; bestError = e }
        }
        // Positions are reported in whole points, so allow about half a point of noise.
        return bestError < 0.75 ? best : nil
    }

    /// The last non-space character before `location` on its line, as a screen box, and
    /// how many spaces follow it up to `location`.
    private static func lastVisibleCell(_ element: AXUIElement, before location: Int) -> (box: CGRect, spacesAfter: Int)? {
        let start = max(0, location - 200)
        guard let head = string(element, CFRange(location: start, length: location - start)) else { return nil }
        let ns = head as NSString
        var index = ns.length - 1
        var spaces = 0
        while index >= 0, let scalar = UnicodeScalar(ns.character(at: index)), scalar == " " {
            spaces += 1
            index -= 1
        }
        guard index >= 0, let scalar = UnicodeScalar(ns.character(at: index)), !CharacterSet.newlines.contains(scalar),
              let box = bounds(element, for: CFRange(location: start + index, length: 1)), box.width > 2 else { return nil }
        return (toCocoa(box), spaces)
    }

    /// The system monospaced font at the size whose characters are exactly one
    /// terminal cell wide, so ghost text lines up column for column.
    static func monospacedFont(cellWidth: CGFloat) -> NSFont {
        let reference = NSFont.monospacedSystemFont(ofSize: 100, weight: .regular)
        let advance = ("M" as NSString).size(withAttributes: [.font: reference]).width / 100
        return NSFont.monospacedSystemFont(ofSize: cellWidth / advance, weight: .regular)
    }

    /// Terminal columns a string occupies (wide emoji take two).
    private static func displayWidth(_ text: String) -> Int {
        text.reduce(0) { $0 + ($1.unicodeScalars.first?.properties.isEmojiPresentation == true ? 2 : 1) }
    }

    /// Reads simple `key = value` lines from Ghostty's config file.
    private static func ghosttyConfig() -> [String: String] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let paths = [".config/ghostty/config", "Library/Application Support/com.mitchellh.ghostty/config"]
        var result: [String: String] = [:]
        for path in paths {
            guard let text = try? String(contentsOf: home.appendingPathComponent(path), encoding: .utf8) else { continue }
            for line in text.split(separator: "\n") {
                let parts = line.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
                if parts.count == 2, !parts[0].hasPrefix("#") {
                    result[parts[0]] = parts[1].trimmingCharacters(in: CharacterSet(charactersIn: "\""))
                }
            }
        }
        return result
    }

    /// A frame that's on screen and big enough to hold text (Google Docs' focused
    /// element, for example, is a hidden 1-pixel strip).
    static func isUsable(_ frame: CGRect) -> Bool {
        frame.width > 20 && frame.height > 8 && NSScreen.screens.contains { $0.frame.intersects(frame) }
    }

    private static func isWebContent(_ element: AXUIElement) -> Bool {
        var names: CFArray?
        AXUIElementCopyAttributeNames(element, &names)
        return ((names as? [String]) ?? []).contains("AXDOMClassList")
    }

    /// Finds a web editor's caret element (and the page it sits on) in the focused window.
    private static func pageCaret(app: AXUIElement) -> (caret: CGRect, page: CGRect?)? {
        guard let window = copyElement(app, kAXFocusedWindowAttribute) else { return nil }
        let deadline = Date().addingTimeInterval(0.08)
        var queue: [AXUIElement] = [window]
        var caret: CGRect?
        var pages: [CGRect] = []
        var visited = 0
        while !queue.isEmpty, visited < 5000, Date() < deadline {
            let node = queue.removeFirst()
            visited += 1
            let classes: [String] = copyValue(node, "AXDOMClassList") ?? []
            if !classes.isEmpty, let frameValue = axValue(node, "AXFrame") {
                var r = CGRect.zero
                AXValueGetValue(frameValue, .cgRect, &r)
                let isCaret = classes.contains { $0.contains("cursor-caret") }
                    || (classes.contains { $0.contains("caret") } && r.width <= 4 && r.height >= 6 && r.height <= 120)
                if isCaret, r.height >= 6, NSScreen.screens.contains(where: { $0.frame.intersects(toCocoa(r)) }) {
                    // Typed text starts at the caret bar's left edge.
                    caret = toCocoa(CGRect(x: r.minX, y: r.minY, width: 1, height: r.height))
                }
                if classes.contains("kix-page-paginated") { pages.append(toCocoa(r)) }
            }
            if let children: [AXUIElement] = copyValue(node, kAXChildrenAttribute) { queue.append(contentsOf: children) }
        }
        guard let caret else { return nil }
        return (caret, pages.first { $0.minX <= caret.minX && $0.maxX >= caret.maxX })
    }

    /// Lays out `text` up to `location` in `frame` with `font` and returns where the
    /// caret lands, in Cocoa screen coordinates.
    static func estimateCaret(in frame: CGRect, text: String, upTo location: Int, font: NSFont) -> CGRect? {
        let ns = text as NSString
        let head = ns.substring(to: max(0, min(location, ns.length)))
        let storage = NSTextStorage(string: head, attributes: [.font: font])
        let layout = NSLayoutManager()
        let container = NSTextContainer(size: CGSize(width: max(frame.width, 20), height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        layout.addTextContainer(container)
        storage.addLayoutManager(layout)
        layout.ensureLayout(for: container)

        let defaultLine = layout.defaultLineHeight(for: font)
        var position = CGPoint.zero      // flipped, relative to the frame's top-left
        if head.isEmpty || head.hasSuffix("\n") || head.hasSuffix("\r") {
            let extra = layout.extraLineFragmentRect
            position = CGPoint(x: 0, y: head.isEmpty ? 0 : extra.minY)
        } else {
            let lastGlyph = layout.glyphIndexForCharacter(at: (head as NSString).length - 1)
            let line = layout.lineFragmentRect(forGlyphAt: lastGlyph, effectiveRange: nil)
            let glyph = layout.boundingRect(forGlyphRange: NSRange(location: lastGlyph, length: 1), in: container)
            position = CGPoint(x: glyph.maxX, y: line.minY)
        }
        // Scale our line height to the field's: a field that hugs its text tells us
        // the app's real line spacing (CSS line-height, for instance).
        let fullStorage = NSTextStorage(string: text.isEmpty ? " " : text, attributes: [.font: font])
        let fullLayout = NSLayoutManager()
        let fullContainer = NSTextContainer(size: container.size)
        fullContainer.lineFragmentPadding = 0
        fullLayout.addTextContainer(fullContainer)
        fullStorage.addLayoutManager(fullLayout)
        fullLayout.ensureLayout(for: fullContainer)
        let lines = max(1, Int((fullLayout.usedRect(for: fullContainer).height / defaultLine).rounded()))
        let fieldLine = frame.height / CGFloat(lines)
        let lineHeight = fieldLine >= defaultLine * 0.8 && fieldLine <= defaultLine * 2.5 ? fieldLine : defaultLine
        let lineIndex = (position.y / defaultLine).rounded()
        let top = frame.maxY - lineIndex * lineHeight
        return CGRect(x: frame.minX + position.x, y: top - lineHeight, width: 1, height: lineHeight)
    }

    private static func string(_ element: AXUIElement, _ range: CFRange) -> String? {
        var range = range
        guard range.location >= 0, let param = AXValueCreate(.cfRange, &range) else { return nil }
        var value: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(element, kAXStringForRangeParameterizedAttribute as CFString, param, &value) == .success,
              let text = value as? String, !text.isEmpty else { return nil }
        return text
    }

    private static func copyValue<T>(_ element: AXUIElement, _ attribute: String) -> T? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value as? T
    }

    private static func copyElement(_ element: AXUIElement, _ attribute: String) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    private static func axValue(_ element: AXUIElement, _ attribute: String) -> AXValue? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        return (value as! AXValue)
    }

    static func selectedRange(_ element: AXUIElement) -> CFRange? {
        guard let value = axValue(element, kAXSelectedTextRangeAttribute) else { return nil }
        var range = CFRange()
        return AXValueGetValue(value, .cfRange, &range) ? range : nil
    }

    static func bounds(_ element: AXUIElement, for range: CFRange) -> CGRect? {
        var range = range
        guard let param = AXValueCreate(.cfRange, &range) else { return nil }
        var value: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(element, kAXBoundsForRangeParameterizedAttribute as CFString, param, &value) == .success,
              let value, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var rect = CGRect.zero
        guard AXValueGetValue(value as! AXValue, .cgRect, &rect) else { return nil }
        return rect
    }

    private static func caretRect(_ element: AXUIElement, range: CFRange, precedingIsNewline: Bool) -> CGRect? {
        let zero = bounds(element, for: CFRange(location: range.location, length: 0))
            .flatMap { $0.height > 1 && $0.origin != .zero ? $0 : nil }
        // At the start of a line there's no character before the caret. Use the leading
        // edge of the character after it instead: zero-length rects can't be trusted
        // (TextEdit reports them one line too high).
        guard range.location > 0, !precedingIsNewline else {
            if let next = bounds(element, for: CFRange(location: range.location, length: 1)),
               next.height > 1, next.width > 0, next.origin != .zero {
                return toCocoa(CGRect(x: next.minX, y: next.minY, width: 1, height: next.height))
            }
            return zero.map(toCocoa)
        }
        if let previous = bounds(element, for: CFRange(location: range.location - 1, length: 1)),
           previous.height > 1, previous.origin != .zero {
            // The zero-length rect is the most precise (WebKit rounds character boxes
            // outwards to whole points), but only when it's on the previous character's
            // line: TextEdit reports it one line up at the end of a line.
            if let zero, abs(zero.midY - previous.midY) < previous.height * 0.5,
               zero.minX >= previous.minX, zero.minX <= previous.maxX + 1 {
                return toCocoa(CGRect(x: zero.minX, y: previous.minY, width: 1, height: previous.height))
            }
            return toCocoa(CGRect(x: previous.maxX, y: previous.minY, width: 1, height: previous.height))
        }
        return zero.map(toCocoa)
    }

    /// Frame in Accessibility coordinates (top-left origin).
    private static func axFrame(_ element: AXUIElement) -> CGRect? {
        guard let value = axValue(element, "AXFrame") else { return nil }
        var rect = CGRect.zero
        return AXValueGetValue(value, .cgRect, &rect) ? rect : nil
    }

    /// The code line drawn at a screen point (Accessibility coordinates): the element
    /// there or its nearest ancestor (up to 4 levels) that is a code editor's line; nil if none is.
    private static func lineElement(at point: CGPoint, app: AXUIElement) -> AXUIElement? {
        var hit: AXUIElement?
        guard AXUIElementCopyElementAtPosition(app, Float(point.x), Float(point.y), &hit) == .success, var node = hit else { return nil }
        for _ in 0..<4 {
            if HiddenInput.isLineClass(copyValue(node, "AXDOMClassList") ?? []) { return node }
            guard let parent = copyElement(node, kAXParentAttribute) else { break }
            node = parent
        }
        return nil
    }

    private static func elementFrame(_ element: AXUIElement) -> CGRect? {
        guard let posValue = axValue(element, kAXPositionAttribute),
              let sizeValue = axValue(element, kAXSizeAttribute) else { return nil }
        var position = CGPoint.zero
        var size = CGSize.zero
        AXValueGetValue(posValue, .cgPoint, &position)
        AXValueGetValue(sizeValue, .cgSize, &size)
        guard size.width > 0, size.height > 0 else { return nil }
        return toCocoa(CGRect(origin: position, size: size))
    }

    /// Accessibility uses top-left origin coordinates relative to the primary display.
    static func toCocoa(_ rect: CGRect) -> CGRect {
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        return CGRect(x: rect.minX, y: primaryHeight - rect.maxY, width: rect.width, height: rect.height)
    }
}

extension Character {
    /// Invisible formatting characters such as zero-width spaces and joiners.
    var isZeroWidth: Bool {
        unicodeScalars.allSatisfy { ["\u{200B}", "\u{200C}", "\u{200D}", "\u{2060}", "\u{FEFF}"].contains($0) }
    }
}
