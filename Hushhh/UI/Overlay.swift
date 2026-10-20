import AppKit
import SwiftUI

/// What the floating overlay is showing.
@MainActor
final class OverlayModel: ObservableObject {
    enum Phase: Equatable {
        case listening
        case finishing
        case message(symbol: String, text: String, isError: Bool)

        var isMessage: Bool {
            if case .message = self { return true }
            return false
        }
    }

    enum Placement { case inline, pill }

    @Published var phase: Phase = .listening
    @Published var text: String = ""
    @Published var level: Float = 0
    @Published var fontSize: CGFloat = 14
    @Published var placement: Placement = .pill
    @Published var showHint = true
    @Published var engineLoading = false
    /// Shown while finishing, e.g. "Polishing with Claude…".
    @Published var busyLabel: String?
    /// Whether Tab can send the dictation to Claude for clean-up.
    @Published var canPolish = false

    var maxTextWidth: CGFloat { placement == .inline ? 380 : 520 }
}

// MARK: - Panel

/// A borderless, non-activating panel so the target app keeps keyboard focus.
final class OverlayPanel: NSPanel {
    init() {
        super.init(contentRect: .zero,
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered,
                   defer: true)
        isFloatingPanel = true
        level = .statusBar
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        ignoresMouseEvents = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class OverlayController {
    let model = OverlayModel()
    private let panel = OverlayPanel()
    private let hosting: OverlayHostingView
    private let ghostPanel = OverlayPanel()
    private let ghostView = GhostContainerView()
    private var anchor: Anchor = .screen
    private var hideWork: DispatchWorkItem?
    /// False from the moment `hide()` starts, so a late layout pass can't bring a panel back.
    private var isShown = false

    /// Shadow/blur margin around the bubble inside the panel.
    static let margin: CGFloat = 16

    enum Anchor {
        /// Ghost text drawn in the document's own font, continuing from the caret.
        case inline(FocusContext.InlineStyle)
        case caret(CGRect)
        case element(CGRect)
        case screen
    }

    init() {
        hosting = OverlayHostingView(rootView: OverlayView(model: model))
        hosting.sizingOptions = [.intrinsicContentSize]
        panel.contentView = hosting
        ghostPanel.contentView = ghostView
        // SwiftUI updates asynchronously; re-place the panel whenever the content size changes.
        hosting.onSizeChange = { [weak self] in
            guard let self, self.isShown else { return }
            self.layout()
        }
    }

    private var isInline: Bool {
        if case .inline = anchor { return true }
        return false
    }

    func show(anchor: Anchor) {
        hideWork?.cancel()
        isShown = true
        self.anchor = anchor
        switch anchor {
        case .inline:
            model.placement = .inline
        case .caret(let rect):
            model.placement = .pill
            model.fontSize = min(16, max(12, rect.height * 0.7))
        case .element, .screen:
            model.placement = .pill
            model.fontSize = 14
        }
        layout()
        for p in visiblePanels {
            p.alphaValue = 0
            p.orderFrontRegardless()
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.12
            for p in visiblePanels { p.animator().alphaValue = 1 }
        }
    }

    /// Moves the ghost text after the caret has moved (e.g. after committed words were typed).
    func move(to anchor: Anchor) {
        guard isShown else { return }
        self.anchor = anchor
        if isInline {
            model.placement = .inline
        } else {
            model.placement = .pill
            ghostPanel.orderOut(nil)
            if case .caret(let rect) = anchor { model.fontSize = min(16, max(12, rect.height * 0.7)) }
        }
        layout()
    }

    private var visiblePanels: [OverlayPanel] {
        isInline && !model.phase.isMessage ? [ghostPanel, panel] : [panel]
    }

    /// Shows a short message, then fades out.
    func flash(symbol: String, text: String, isError: Bool = false, duration: TimeInterval = 1.8) {
        model.phase = .message(symbol: symbol, text: text, isError: isError)
        // The panel never takes focus, so announce the message for VoiceOver.
        NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested, userInfo: [
            .announcement: text,
            .priority: NSAccessibilityPriorityLevel.high.rawValue,
        ])
        ghostPanel.orderOut(nil)
        if !panel.isVisible { show(anchor: anchor) } else { layout() }
        let work = DispatchWorkItem { [weak self] in self?.hide() }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: work)
    }

    func hide() {
        hideWork?.cancel()
        isShown = false
        ghostPanel.orderOut(nil)
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.15
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            Task { @MainActor in
                guard let self, !self.isShown else { return }
                self.panel.orderOut(nil)
                self.model.text = ""
                self.model.level = 0
            }
        })
    }

    /// Resizes the panels to fit the content and places them next to the anchor.
    func layout() {
        if case .inline(let style) = anchor {
            layoutInline(style)
            return
        }
        // Measure with the model's current values; the live hosting view updates asynchronously.
        let size = measuredBubbleSize()
        guard size.width > 0, size.height > 0 else { return }
        let margin = Self.margin
        let visible = screen(containing: anchorPoint).visibleFrame
        var origin: CGPoint

        switch anchor {
        case .caret(let caret):
            // Just below the caret's line, with the transcript starting under the caret,
            // so it never covers the text being written.
            let textInset: CGFloat = 10 + 20 + 8   // bubble padding + meter + spacing
            origin = CGPoint(x: caret.minX - textInset - margin,
                             y: caret.minY - 6 - size.height + margin)
            if origin.y - margin < visible.minY {
                origin.y = caret.maxY + 6 - margin   // no room below: show above the line
            }
        case .element(let frame):
            // Below a small field; inside the bottom edge of a large one (a terminal window).
            origin = frame.height > 200
                ? CGPoint(x: frame.minX + 12 - margin, y: frame.minY + 12 - margin)
                : CGPoint(x: frame.minX - margin, y: frame.minY - 8 - size.height + margin)
        case .screen, .inline:
            origin = CGPoint(x: visible.midX - size.width / 2, y: visible.minY + 72 - margin)
        }
        panel.setFrame(clamp(CGRect(origin: origin, size: size), to: visible), display: true)
    }

    private func layoutInline(_ style: FocusContext.InlineStyle) {
        let caret = style.caret
        let font = style.font ?? NSFont.systemFont(ofSize: min(28, max(11, caret.height / 1.25)))
        // Apps that don't report a text colour get system grey, readable on light and dark themes.
        let color = Self.debugGhostColor ?? style.color.map { $0.withAlphaComponent(0.55) } ?? Self.fallbackGhostColor
        let visibleFrame = screen(containing: CGPoint(x: caret.midX, y: caret.midY)).visibleFrame
        var lineStartX = style.lineStartX
        var width = max(160, style.rightEdgeX - style.lineStartX)
        // Ghost text starts in the cursor's own cell, where typing will put it. The
        // overlay sits above the app, so a block cursor can't hide the first letter.
        let cursorSkip: CGFloat = 0
        var indent = caret.minX + cursorSkip - style.lineStartX
        var lineHeight = Self.lineMetrics.defaultLineHeight(for: font)
        var firstLineTop = style.alignsToTop ? caret.maxY : caret.midY + lineHeight / 2
        if style.singleLine {
            // One line from the caret rightwards, overflowing the field like a cell does.
            lineStartX = caret.minX + cursorSkip
            width = max(80, visibleFrame.maxX - lineStartX - 8)
            indent = 0
        } else if width - indent < font.pointSize * 3 {
            // No room left on this line: continue on the next one.
            indent = 0
            firstLineTop -= max(caret.height, lineHeight)
        }

        let text = style.singleLine ? Self.tail(of: model.text, fitting: width, font: font) : model.text
        let measured = ghostView.update(text: text, font: font, color: color, firstLineIndent: indent, width: width,
                                        maxLines: style.singleLine ? 1 : Self.maxGhostLines)
        lineHeight = measured.lineHeight
        let ghostFrame = CGRect(x: lineStartX, y: firstLineTop - measured.size.height,
                                width: width, height: max(measured.size.height, 1))
        // The panel is a little larger than the text so the scrim has room around it,
        // and covers any selected text that dictation will replace.
        let pad = GhostContainerView.padding
        var panelFrame = ghostFrame.insetBy(dx: -pad, dy: -pad)
        if let selection = style.replacing { panelFrame = panelFrame.union(selection.insetBy(dx: -4, dy: -3)) }
        // Keep the scrim within the text field's left and right edges, so it never spills
        // past the window. Not vertically: wrapped ghost text may run below a short field.
        // Single-line fields (cells) overflow on purpose.
        if let field = style.bounds, !style.singleLine {
            let minX = max(panelFrame.minX, field.minX), maxX = min(panelFrame.maxX, field.maxX)
            if maxX - minX > 20 { panelFrame = CGRect(x: minX, y: panelFrame.minY, width: maxX - minX, height: panelFrame.height) }
        }
        ghostPanel.setFrame(panelFrame, display: false)
        ghostView.arrange(textOrigin: CGPoint(x: ghostFrame.minX - panelFrame.minX, y: panelFrame.maxY - ghostFrame.maxY),
                          cover: style.replacing.map {
                              let r = $0.insetBy(dx: -4, dy: -3)
                              return CGRect(x: r.minX - panelFrame.minX, y: panelFrame.maxY - r.maxY, width: r.width, height: r.height)
                          })
        ghostPanel.display()
        if isShown, !model.phase.isMessage {
            ghostPanel.alphaValue = text.isEmpty ? 0 : 1
            if !ghostPanel.isVisible { ghostPanel.orderFrontRegardless() }
        }

        // The status chip (level meter and key hints) sits just below the ghost text.
        let size = measuredBubbleSize()
        guard size.width > 0, size.height > 0 else { return }
        let visible = visibleFrame
        let margin = Self.margin
        var bottom = text.isEmpty ? caret.minY : min(caret.minY, ghostFrame.minY - (ghostView.isScrimVisible ? pad : 0))
        if let selection = style.replacing { bottom = min(bottom, selection.minY - 3) }
        var origin = CGPoint(x: min(caret.minX, style.lineStartX) - margin, y: bottom - 6 - size.height + margin)
        let above = CGPoint(x: origin.x, y: caret.maxY + 6 - margin)
        if origin.y - margin < visible.minY {
            origin = above   // no room below: show above the line
        } else {
            // Don't sit on the app's own controls (e.g. Google Docs' template buttons under
            // an empty page): if there are buttons below the line, go above it instead.
            let below = CGRect(origin: origin, size: size).insetBy(dx: margin, dy: margin)
            let key = Int(below.minY.rounded()) &* 31 &+ Int(below.minX.rounded())
            if chipPlacementKey != key {
                chipPlacementKey = key
                let aboveRect = CGRect(origin: above, size: size).insetBy(dx: margin, dy: margin)
                chipGoesAbove = Self.hasControls(in: below) && !Self.hasControls(in: aboveRect)
            }
            if chipGoesAbove { origin = above }
        }
        panel.setFrame(clamp(CGRect(origin: origin, size: size), to: visible), display: true)
    }

    /// Cached so the hit-test runs once per position, not on every layout pass.
    private var chipPlacementKey: Int?
    private var chipGoesAbove = false
    private static let controlRoles: Set<String> = [
        kAXButtonRole, kAXPopUpButtonRole, kAXMenuButtonRole, kAXCheckBoxRole, kAXRadioButtonRole,
        "AXLink", kAXComboBoxRole, kAXTextFieldRole,
    ]

    /// Whether another app has clickable controls under `rect` (Cocoa screen coordinates),
    /// using the Accessibility hit-test at a few points across it.
    private static func hasControls(in rect: CGRect) -> Bool {
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 0.1)
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        let ownPID = ProcessInfo.processInfo.processIdentifier
        for fraction in [0.15, 0.5, 0.85] {
            let point = CGPoint(x: rect.minX + rect.width * fraction, y: primaryHeight - rect.midY)
            var hit: AXUIElement?
            guard AXUIElementCopyElementAtPosition(system, Float(point.x), Float(point.y), &hit) == .success,
                  let hit else { continue }
            var pid: pid_t = 0
            AXUIElementGetPid(hit, &pid)
            guard pid != ownPID else { continue }
            var element: AXUIElement? = hit
            // The hit is often a label inside the control; check a couple of parents too.
            for _ in 0..<3 {
                guard let current = element else { break }
                var role: CFTypeRef?
                AXUIElementCopyAttributeValue(current, kAXRoleAttribute as CFString, &role)
                if let role = role as? String, controlRoles.contains(role) { return true }
                var parent: CFTypeRef?
                AXUIElementCopyAttributeValue(current, kAXParentAttribute as CFString, &parent)
                element = parent.map { $0 as! AXUIElement }
            }
        }
        return false
    }

    private static let lineMetrics = NSLayoutManager()
    /// Ghost text for apps that don't report a text colour: a mid grey with at least
    /// 4.5:1 contrast on white (light) or near-black (dark) pages.
    static let fallbackGhostColor = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? NSColor(white: 0.62, alpha: 1) : NSColor(white: 0.42, alpha: 1)
    }
    /// Alignment tests draw the ghost text in a solid colour and hide the chip.
    static var debugGhostColor: NSColor?
    /// Longer dictation shows only its newest lines, so it can't cover the page.
    private static let maxGhostLines = 6

    /// Measures the bubble with the model's current values. A fresh controller is
    /// needed: a reused one can report the size of its previous content.
    private func measuredBubbleSize() -> CGSize {
        NSHostingController(rootView: OverlayView(model: model))
            .sizeThatFits(in: CGSize(width: 2000, height: 2000))
    }

    /// The end of `text` that fits on one line, with a leading ellipsis if trimmed.
    static func tail(of text: String, fitting width: CGFloat, font: NSFont) -> String {
        func fits(_ s: String) -> Bool { (s as NSString).size(withAttributes: [.font: font]).width <= width }
        guard !fits(text) else { return text }
        var words = text.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
        while words.count > 1, !fits("…" + words.joined(separator: " ")) { words.removeFirst() }
        return "…" + words.joined(separator: " ")
    }

    private func clamp(_ frame: CGRect, to visible: CGRect) -> CGRect {
        let margin = Self.margin
        var f = frame
        f.origin.x = min(max(f.origin.x, visible.minX - margin), visible.maxX - f.width + margin)
        f.origin.y = min(max(f.origin.y, visible.minY - margin), visible.maxY - f.height + margin)
        return f
    }

    private var anchorPoint: CGPoint {
        switch anchor {
        case .inline(let s): CGPoint(x: s.caret.midX, y: s.caret.midY)
        case .caret(let r): CGPoint(x: r.midX, y: r.midY)
        case .element(let r): CGPoint(x: r.midX, y: r.midY)
        case .screen: NSEvent.mouseLocation
        }
    }

    private func screen(containing point: CGPoint) -> NSScreen {
        NSScreen.screens.first { $0.frame.contains(point) } ?? NSScreen.main ?? NSScreen.screens[0]
    }
}

/// Ghost text plus a scrim: once the text wraps onto a second line, a blurred
/// backdrop fades in behind it so it stays readable over whatever is below. The
/// scrim follows the text's shape, so it never covers the caret's line before the caret.
final class GhostContainerView: NSView {
    static let padding: CGFloat = 8

    private let scrim = ScrimView()
    private let text = GhostTextView()
    private(set) var isScrimVisible = false
    private var textColor: NSColor = .systemGray

    override init(frame: NSRect) {
        super.init(frame: frame)
        scrim.alphaValue = 0
        addSubview(scrim)
        addSubview(text)
        setAccessibilityElement(false)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    func update(text string: String, font: NSFont, color: NSColor, firstLineIndent: CGFloat, width: CGFloat,
                maxLines: Int) -> (size: CGSize, lineHeight: CGFloat) {
        textColor = color
        var shown = string
        var result = text.update(text: shown, font: font, color: color, firstLineIndent: firstLineIndent, width: width)
        // Too long: drop words from the start until it fits, marking the cut with "…".
        if result.lines > maxLines {
            var words = string.split(separator: " ").map(String.init)
            while words.count > 1, result.lines > maxLines {
                words.removeFirst(max(1, words.count / 12))
                shown = "… " + words.joined(separator: " ")
                result = text.update(text: shown, font: font, color: color, firstLineIndent: firstLineIndent, width: width)
            }
        }

        last = (firstLineIndent, width, result.size.height, result.firstLineHeight, result.lines, string.isEmpty)
        lastLineRects = result.lineRects
        return (result.size, result.lineHeight)
    }

    private var last: (indent: CGFloat, width: CGFloat, height: CGFloat, firstLineHeight: CGFloat, lines: Int, empty: Bool)
        = (0, 0, 0, 0, 0, true)
    private var lastLineRects: [CGRect] = []

    /// Positions the text inside the panel and shapes the scrim. `cover` is selected
    /// text (in this view's coordinates) that the scrim must hide.
    func arrange(textOrigin: CGPoint, cover: CGRect?) {
        text.frame = CGRect(origin: textOrigin, size: CGSize(width: last.width, height: last.height))
        scrim.frame = bounds
        scrim.fill = Self.backdrop(for: textColor)
        scrim.shape = Self.shape(textOrigin: textOrigin, lineRects: lastLineRects, cover: cover)
        scrim.needsDisplay = true

        let wantsScrim = last.lines >= 2 || (cover != nil && !last.empty)
        if wantsScrim != isScrimVisible {
            isScrimVisible = wantsScrim
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.25
                scrim.animator().alphaValue = wantsScrim ? 1 : 0
            }
        }
    }

    /// The page's own background, inferred from its text colour: dark text means a light
    /// page and vice versa. Unknown colours follow the system appearance.
    private static func backdrop(for text: NSColor) -> NSColor {
        let rgb = text.usingColorSpace(.sRGB)
        let luminance = rgb.map { 0.2126 * $0.redComponent + 0.7152 * $0.greenComponent + 0.0722 * $0.blueComponent } ?? 0.5
        if text == .systemGray || (0.35...0.65).contains(luminance) {
            var color = NSColor.textBackgroundColor
            NSApp.effectiveAppearance.performAsCurrentDrawingAppearance {
                color = NSColor.textBackgroundColor.usingColorSpace(.sRGB) ?? .white
            }
            return color.withAlphaComponent(0.96)
        }
        return luminance < 0.5 ? NSColor(white: 1, alpha: 0.96) : NSColor(white: 0.12, alpha: 0.96)
    }

    /// The ghost text's outline: each line's own extent, padded and merged, so the
    /// backdrop hugs the words (like a text highlight) instead of the whole field.
    /// Also covers any selected text being replaced.
    private static func shape(textOrigin: CGPoint, lineRects: [CGRect], cover: CGRect?) -> NSBezierPath {
        let pad = padding - 3   // leave room inside the panel for the shadow
        let radius: CGFloat = 7
        let path = NSBezierPath()
        let boxes = lineRects.enumerated().map { index, line -> CGRect in
            let top: CGFloat = index == 0 ? pad : 0
            let bottom: CGFloat = index == lineRects.count - 1 ? pad : 0
            // A first line that continues after existing text starts right at the caret,
            // so the backdrop never covers the character before it.
            let left: CGFloat = index == 0 && line.minX > 1 ? 1 : pad
            return CGRect(x: textOrigin.x + line.minX - left, y: textOrigin.y + line.minY - top,
                          width: line.width + left + pad, height: line.height + top + bottom)
        }
        for (index, box) in boxes.enumerated() {
            path.append(NSBezierPath(roundedRect: box, xRadius: radius, yRadius: radius))
            // Join consecutive lines where they overlap so there's no seam between them.
            if index + 1 < boxes.count {
                let next = boxes[index + 1]
                let left = max(box.minX, next.minX), right = min(box.maxX, next.maxX)
                if right > left {
                    path.append(NSBezierPath(rect: CGRect(x: left, y: box.maxY - radius, width: right - left,
                                                          height: next.minY - box.maxY + 2 * radius)))
                }
            }
        }
        if let cover { path.append(NSBezierPath(roundedRect: cover, xRadius: 4, yRadius: 4)) }
        path.windingRule = .nonZero
        return path
    }
}

/// Fills the scrim's outline in the page's background colour, with a soft shadow.
final class ScrimView: NSView {
    var fill: NSColor = .white
    var shape = NSBezierPath()

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.18)
        shadow.shadowBlurRadius = 6
        shadow.shadowOffset = NSSize(width: 0, height: -1)
        shadow.set()
        fill.setFill()
        shape.fill()
        NSGraphicsContext.restoreGraphicsState()
    }
}

/// Draws ghost text with TextKit so it wraps like the document: the first
/// line starts at the caret, later lines at the left edge of the text.
final class GhostTextView: NSView {
    private let storage = NSTextStorage()
    private let layoutManager = NSLayoutManager()
    private let container = NSTextContainer()

    override init(frame: NSRect) {
        super.init(frame: frame)
        container.lineFragmentPadding = 0
        layoutManager.addTextContainer(container)
        storage.addLayoutManager(layoutManager)
        setAccessibilityElement(false)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    func update(text: String, font: NSFont, color: NSColor, firstLineIndent: CGFloat, width: CGFloat)
        -> (size: CGSize, lineHeight: CGFloat, lines: Int, firstLineHeight: CGFloat, lineRects: [CGRect]) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.firstLineHeadIndent = firstLineIndent
        paragraph.lineBreakMode = .byWordWrapping
        storage.setAttributedString(NSAttributedString(string: text, attributes: [
            .font: font, .foregroundColor: color, .paragraphStyle: paragraph,
        ]))
        container.size = CGSize(width: width, height: .greatestFiniteMagnitude)
        layoutManager.ensureLayout(for: container)
        let used = layoutManager.usedRect(for: container)
        let lineHeight = layoutManager.defaultLineHeight(for: font)
        var lines = 0
        var lineRects: [CGRect] = []
        var firstLineHeight = lineHeight
        let glyphs = layoutManager.glyphRange(for: container)
        var index = glyphs.location
        while index < NSMaxRange(glyphs) {
            var range = NSRange()
            let rect = layoutManager.lineFragmentRect(forGlyphAt: index, effectiveRange: &range)
            let used = layoutManager.lineFragmentUsedRect(forGlyphAt: index, effectiveRange: nil)
            lineRects.append(CGRect(x: used.minX, y: rect.minY, width: used.width, height: rect.height))
            if lines == 0 { firstLineHeight = rect.height }
            lines += 1
            index = NSMaxRange(range)
        }
        needsDisplay = true
        return (CGSize(width: width, height: ceil(used.height)), lineHeight, max(lines, text.isEmpty ? 0 : 1), firstLineHeight, lineRects)
    }

    override func draw(_ dirtyRect: NSRect) {
        layoutManager.drawGlyphs(forGlyphRange: layoutManager.glyphRange(for: container), at: .zero)
    }
}

final class OverlayHostingView: NSHostingView<OverlayView> {
    var onSizeChange: (() -> Void)?

    override func invalidateIntrinsicContentSize() {
        super.invalidateIntrinsicContentSize()
        DispatchQueue.main.async { [weak self] in self?.onSizeChange?() }
    }
}

// MARK: - SwiftUI content

struct OverlayView: View {
    @ObservedObject var model: OverlayModel

    var body: some View {
        bubble
            .fixedSize(horizontal: false, vertical: true)
            .padding(OverlayController.margin)
    }

    @ViewBuilder
    private var bubble: some View {
        switch model.phase {
        case .listening, .finishing:
            VStack(alignment: .leading, spacing: 6) {
                if model.placement == .inline {
                    // Compact status chip; the transcript itself is drawn inline in the document.
                    HStack(spacing: 8) {
                        indicator.frame(width: 20, height: 16)
                        if model.phase == .finishing {
                            Text(model.busyLabel ?? "Finishing…").font(.system(size: 13)).foregroundStyle(.secondary)
                        } else if model.showHint {
                            HintRow(insertLabel: "Insert", showPolish: model.canPolish)
                        } else {
                            Text(model.engineLoading ? "Loading model…" : "Listening").font(.system(size: 13)).foregroundStyle(.secondary)
                        }
                    }
                } else {
                    HStack(alignment: .top, spacing: 8) {
                        // Centre the indicator on the first line of text.
                        indicator.frame(width: 20, height: ceil(NSFont.systemFont(ofSize: model.fontSize).boundingRectForFont.height))
                        transcript
                    }
                    if let busy = model.busyLabel, model.phase == .finishing {
                        Text(busy).font(.system(size: 13)).foregroundStyle(.secondary)
                    } else if model.showHint && model.phase == .listening {
                        HintRow(insertLabel: "Insert", showPolish: model.canPolish)
                    }
                }
            }
            .padding(.horizontal, model.placement == .inline ? 8 : 10)
            .padding(.vertical, model.placement == .inline ? 5 : 7)
            .glassBubble()
            .accessibilityElement(children: .combine)
            .accessibilityLabel(model.text.isEmpty ? "Listening" : model.text)

        case let .message(symbol, text, isError):
            Label {
                Text(text).font(.system(size: 13, weight: .medium)).foregroundStyle(.primary)
            } icon: {
                Image(systemName: symbol)
                    .foregroundStyle(isError ? Color.orange : Color.accentColor)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .glassBubble()
        }
    }

    @ViewBuilder
    private var indicator: some View {
        if model.phase == .finishing {
            ProgressView().controlSize(.small)
        } else {
            LevelMeter(level: model.level)
        }
    }

    private var transcript: some View {
        let placeholder = model.engineLoading ? "Loading model…" : "Listening…"
        let display = model.text.isEmpty ? placeholder : model.text
        return Text(display)
            .font(.system(size: model.fontSize))
            .foregroundStyle(model.text.isEmpty ? .secondary : .primary)
            .lineLimit(4)
            .truncationMode(.head)
            .frame(width: textWidth(display), alignment: .leading)
            .animation(nil, value: model.text)
    }

    /// Hug short text; wrap longer text at the maximum width.
    private func textWidth(_ text: String) -> CGFloat {
        let font = NSFont.systemFont(ofSize: model.fontSize)
        let width = (text as NSString).size(withAttributes: [.font: font]).width
        return min(model.maxTextWidth, ceil(width) + 2)
    }
}

/// Keyboard hint shown while listening.
private struct HintRow: View {
    let insertLabel: String
    var showPolish = false

    var body: some View {
        HStack(spacing: 10) {
            HStack(spacing: 4) { KeyCap("⇪"); Text(insertLabel) }
            if showPolish {
                HStack(spacing: 4) { KeyCap("tab"); Text("Polish") }
            }
            HStack(spacing: 4) { KeyCap("esc"); Text("Cancel") }
        }
        .font(.system(size: 13))
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .fixedSize()
    }
}

struct KeyCap: View {
    let label: String
    init(_ label: String) { self.label = label }

    var body: some View {
        Text(label)
            .font(.system(size: 12, weight: .semibold, design: .rounded))
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(RoundedRectangle(cornerRadius: 4, style: .continuous).fill(.quaternary))
            .overlay(RoundedRectangle(cornerRadius: 4, style: .continuous).strokeBorder(.tertiary, lineWidth: 0.5))
    }
}

/// A compact five-bar meter driven by the microphone level.
struct LevelMeter: View {
    let level: Float
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private let weights: [CGFloat] = [0.45, 0.8, 1.0, 0.7, 0.4]

    var body: some View {
        HStack(alignment: .center, spacing: 2) {
            ForEach(weights.indices, id: \.self) { i in
                Capsule()
                    .fill(Color.accentColor)
                    .frame(width: 2.5, height: barHeight(weights[i]))
            }
        }
        .frame(width: 20, height: 16)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.08), value: level)
        .accessibilityHidden(true)
    }

    private func barHeight(_ weight: CGFloat) -> CGFloat {
        let l = reduceMotion ? 0.3 : CGFloat(level)
        return max(3, 16 * weight * min(1, 0.25 + l))
    }
}

extension View {
    @ViewBuilder
    func glassBubble() -> some View {
        if #available(macOS 26.0, *) {
            self.glassEffect(.regular, in: .rect(cornerRadius: 12))
        } else {
            self
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.separator, lineWidth: 0.5))
                .shadow(color: .black.opacity(0.18), radius: 10, y: 3)
        }
    }
}
