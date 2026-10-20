import AVFoundation
import AppKit

/// `Hushhh --transcribe file.wav [--engine qvac|whisper] [--download]`
/// Runs the selected engine over a file through the same live pipeline
/// used for dictation, prints partials and the final text, then quits.
enum Diagnostics {
    static func transcribe(file: String) {
        Task { @MainActor in
            let args = CommandLine.arguments
            let prefs = Preferences.shared
            if let i = args.firstIndex(of: "--engine"), i + 1 < args.count, let kind = EngineKind(rawValue: args[i + 1]) {
                prefs.engine = kind
            }
            let store = ModelStore.shared
            let id: ModelID = prefs.engine == .qvac ? .qvac : .whisper(prefs.whisperModel)
            if !store.isInstalled(id), args.contains("--download") {
                print("Downloading \(id)…")
                store.download(id)
                while case .downloading = store.status(id) { try? await Task.sleep(nanoseconds: 200_000_000) }
                print("Download status: \(store.status(id))")
            }

            let engine: SpeechEngine
            switch prefs.engine {
            case .qvac: engine = QVACEngine(modelURL: ModelStore.qvacModelURL, useGPU: prefs.useGPU)
            case .whisper:
                guard let folder = store.whisperFolder(prefs.whisperModel) else { print("Model not installed"); exit(1) }
                engine = WhisperEngine(model: prefs.whisperModel, folder: folder)
            }

            let start = Date()
            do { try await engine.load() } catch { print("Load failed: \(error)"); exit(1) }
            print(String(format: "Loaded %@ in %.2fs", engine.displayName, Date().timeIntervalSince(start)))

            guard let samples = loadSamples(file) else { print("Couldn’t read \(file)"); exit(1) }
            let live = LiveTranscriber(engineProvider: { engine })
            var tracker = CommitTracker(delay: prefs.commitDelay)
            var typed: [String] = []
            let began = Date()
            live.onPartial = { text in
                let (settled, pending) = tracker.update(text)
                typed += settled
                let t = String(format: "%5.1fs", Date().timeIntervalSince(began))
                print("\(t)  typed: \(typed.joined(separator: " "))  ‹ghost: \(pending.joined(separator: " "))›")
            }
            live.start()
            // Feed the audio in real time, 100 ms at a time, like the microphone does.
            let chunk = 1600
            var offset = 0
            while offset < samples.count {
                let slice = Array(samples[offset..<min(offset + chunk, samples.count)])
                let rms = (slice.reduce(0) { $0 + $1 * $1 } / Float(slice.count)).squareRoot()
                live.append(slice, level: min(1, rms * 12))
                offset += chunk
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
            let t = Date()
            let text = await live.finish()
            print(String(format: "final (%.2fs after end of audio): %@", Date().timeIntervalSince(t), text))
            print("document: \((typed + tracker.remainder(of: text)).joined(separator: " "))")
            exit(0)
        }
    }

    /// `Hushhh --demo-overlay` cycles the overlay through its states for visual review.
    @MainActor
    static func demoOverlay() {
        let overlay = OverlayController()
        let screen = NSScreen.main!.visibleFrame
        let caret = CGRect(x: screen.minX + 300, y: screen.maxY - 300, width: 1, height: 18)
        let steps: [(TimeInterval, () -> Void)] = [
            (0, { overlay.model.engineLoading = false; overlay.model.level = 0.4
                  overlay.show(anchor: .inline(.init(caret: caret, font: NSFont(name: "Helvetica", size: 12), color: .black,
                                                     lineStartX: caret.minX - 230, rightEdgeX: caret.minX + 200, singleLine: false))) }),
            (1.5, { overlay.model.text = " then the text box is"; overlay.model.level = 0.8; overlay.layout() }),
            (3.0, { overlay.model.text = " then the text box is filled in with grey ghost text that wraps onto the next line just like the document does."; overlay.layout() }),
            (4.5, { overlay.model.phase = .finishing; overlay.layout() }),
            (6.0, { overlay.hide() }),
            (6.5, { overlay.model.phase = .listening; overlay.model.text = "Pill placement when no text field is focused."; overlay.show(anchor: .screen) }),
            (8.0, { overlay.flash(symbol: "doc.on.clipboard", text: "No text field selected — copied to clipboard") }),
            (10.5, { exit(0) }),
        ]
        for (delay, step) in steps {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: step)
        }
    }

    /// `Hushhh --probe-focus <log>`: activates TextEdit, moves the caret to the end of the
    /// front document, logs what Accessibility reports, and draws sample ghost text.
    @MainActor
    static func probeFocus(log: String) {
        var lines: [String] = []
        func note(_ s: String) { lines.append(s); try? lines.joined(separator: "\n").write(toFile: log, atomically: true, encoding: .utf8) }
        let overlay = OverlayController()
        let args = CommandLine.arguments
        let bundle = args.firstIndex(of: "--bundle").map { args[$0 + 1] } ?? "com.apple.TextEdit"
        guard let textEdit = NSRunningApplication.runningApplications(withBundleIdentifier: bundle).first else {
            note("\(bundle) isn't running"); exit(1)
        }
        let pid = textEdit.processIdentifier
        FocusContext.enableAccessibility(pid: pid)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            let app = AXUIElementCreateApplication(pid)
            var value: CFTypeRef?
            AXUIElementCopyAttributeValue(app, kAXFocusedUIElementAttribute as CFString, &value)
            guard let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { note("no focused element"); exit(1) }
            var element = value as! AXUIElement
            var focusedRole: CFTypeRef?
            AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &focusedRole)
            if !FocusContext.textRoles.contains((focusedRole as? String) ?? ""), let area = findTextArea(in: element) {
                // Like clicking into the document body.
                note("focused \(String(describing: focusedRole)); focusing descendant text area")
                AXUIElementSetAttributeValue(area, kAXFocusedAttribute as CFString, kCFBooleanTrue)
                element = area
            }
            var text: CFTypeRef?
            AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &text)
            let length = ((text as? String) ?? "" as String).utf16.count
            if let i = args.firstIndex(of: "--select"), i + 1 < args.count, let n = Int(args[i + 1]) {
                var sel = CFRange(location: max(0, length - n), length: min(n, length))
                AXUIElementSetAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, AXValueCreate(.cfRange, &sel)!)
            } else if args.contains("--move-caret") {
                var end = CFRange(location: length, length: 0)
                AXUIElementSetAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, AXValueCreate(.cfRange, &end)!)
            }
            var names: CFArray?
            AXUIElementCopyAttributeNames(element, &names)
            note("attributes: \((names as? [String]) ?? [])")
            var params: CFArray?
            AXUIElementCopyParameterizedAttributeNames(element, &params)
            note("parameterized: \((params as? [String]) ?? [])")
            var markerRange: CFTypeRef?
            let markerStatus = AXUIElementCopyAttributeValue(element, "AXSelectedTextMarkerRange" as CFString, &markerRange)
            note("AXSelectedTextMarkerRange status=\(markerStatus.rawValue) present=\(markerRange != nil)")
            if let markerRange {
                var boundsValue: CFTypeRef?
                let st = AXUIElementCopyParameterizedAttributeValue(element, "AXBoundsForTextMarkerRange" as CFString, markerRange, &boundsValue)
                var rect = CGRect.zero
                if let boundsValue, CFGetTypeID(boundsValue) == AXValueGetTypeID() { AXValueGetValue(boundsValue as! AXValue, .cgRect, &rect) }
                note("AXBoundsForTextMarkerRange status=\(st.rawValue) rect=\(rect)")
                var startMarker: CFTypeRef?
                AXUIElementCopyParameterizedAttributeValue(element, "AXStartTextMarkerForTextMarkerRange" as CFString, markerRange, &startMarker)
                note("start marker present=\(startMarker != nil)")
                if let startMarker {
                    var prev: CFTypeRef?
                    AXUIElementCopyParameterizedAttributeValue(element, "AXPreviousTextMarkerForTextMarker" as CFString, startMarker, &prev)
                    if let prev {
                        var pair: CFTypeRef?
                        AXUIElementCopyParameterizedAttributeValue(element, "AXTextMarkerRangeForUnorderedTextMarkers" as CFString, [prev, startMarker] as CFArray, &pair)
                        if let pair {
                            var b: CFTypeRef?
                            let st2 = AXUIElementCopyParameterizedAttributeValue(element, "AXBoundsForTextMarkerRange" as CFString, pair, &b)
                            var r = CGRect.zero
                            if let b, CFGetTypeID(b) == AXValueGetTypeID() { AXValueGetValue(b as! AXValue, .cgRect, &r) }
                            var str: CFTypeRef?
                            AXUIElementCopyParameterizedAttributeValue(element, "AXStringForTextMarkerRange" as CFString, pair, &str)
                            note("prev-char marker bounds status=\(st2.rawValue) rect=\(r) string=\(String(describing: str))")
                        }
                    }
                }
            }
            if args.contains("--find-caret-class") {
                var window: CFTypeRef?
                AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &window)
                var visited = 0
                @MainActor func walk(_ node: AXUIElement, _ depth: Int) {
                    guard depth < 40, visited < 20_000 else { return }
                    visited += 1
                    var classes: CFTypeRef?
                    AXUIElementCopyAttributeValue(node, "AXDOMClassList" as CFString, &classes)
                    var f: CFTypeRef?
                    AXUIElementCopyAttributeValue(node, "AXFrame" as CFString, &f)
                    var r = CGRect.zero
                    if let f, CFGetTypeID(f) == AXValueGetTypeID() { AXValueGetValue(f as! AXValue, .cgRect, &r) }
                    let list = (classes as? [String]) ?? []
                    var roleRef: CFTypeRef?
                    AXUIElementCopyAttributeValue(node, kAXRoleAttribute as CFString, &roleRef)
                    if list.contains(where: { $0.contains("cursor") || $0.contains("caret") })
                        || (r.width > 0 && r.width <= 3 && r.height >= 8 && r.height <= 80 && r.minX > 0) {
                        note("caret-like element role=\(String(describing: roleRef)) classes=\(list) frame=\(r)")
                    }
                    var kids: CFTypeRef?
                    AXUIElementCopyAttributeValue(node, kAXChildrenAttribute as CFString, &kids)
                    for k in (kids as? [AXUIElement]) ?? [] { walk(k, depth + 1) }
                }
                if let window { walk(window as! AXUIElement, 0) }
                note("visited \(visited) nodes")
            }
            var frameValue: CFTypeRef?
            AXUIElementCopyAttributeValue(element, "AXFrame" as CFString, &frameValue)
            note("AXFrame: \(String(describing: frameValue))")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                let range = FocusContext.selectedRange(element) ?? CFRange()
                var role: CFTypeRef?
                AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &role)
                note("app: \(bundle)  role: \(String(describing: role))")
                note("text: \(String(((text as? String) ?? "").suffix(60)).debugDescription)")
                note("selected range: \(range.location),\(range.length)")
                note("primary screen: \(NSScreen.screens[0].frame)  screens: \(NSScreen.screens.map(\.frame))")
                note("raw AX bounds(loc,0):   \(String(describing: FocusContext.bounds(element, for: CFRange(location: range.location, length: 0))))")
                if range.location > 0 {
                    note("raw AX bounds(loc-1,1): \(String(describing: FocusContext.bounds(element, for: CFRange(location: range.location - 1, length: 1))))")
                }
                if range.location > 0 || length > 0 {
                    var probe = CFRange(location: range.location > 0 ? range.location - 1 : length - 1, length: 1)
                    var attributed: CFTypeRef?
                    AXUIElementCopyParameterizedAttributeValue(element, kAXAttributedStringForRangeParameterizedAttribute as CFString,
                                                               AXValueCreate(.cfRange, &probe)!, &attributed)
                    if let a = attributed as? NSAttributedString, a.length > 0 {
                        note("raw text attributes: \(a.attributes(at: 0, effectiveRange: nil))")
                    }
                }
                let ctx = FocusContext.capture(pid: pid)
                note("caret (cocoa): \(String(describing: ctx.caretRect)) source: \(ctx.caretSource.rawValue)")
                note("element frame (cocoa): \(String(describing: ctx.elementFrame))")
                if let i = ctx.inline {
                    note("inline: lineStartX \(i.lineStartX) rightEdgeX \(i.rightEdgeX) font \(String(describing: i.font)) color \(String(describing: i.color))")
                    overlay.model.text = " This is a test of the ghost text alignment, long enough to wrap onto another line."
                    overlay.show(anchor: .inline(i))
                } else {
                    note("inline: nil (preceding \(String(describing: ctx.precedingCharacter)))")
                }
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) { exit(0) }
    }

    /// `Hushhh --align-test --bundle <id> --split <n> --phase prepare|draw`
    /// prepare: puts the caret at character n of the focused field and prints where
    ///          Hushhh thinks it is (top-left screen points) plus the rest of the line.
    /// draw:    draws that rest of the line as red ghost text where Hushhh would place it,
    ///          so a screenshot can be compared with the real text underneath.
    @MainActor
    static func alignTest() {
        let args = CommandLine.arguments
        func arg(_ name: String) -> String? { args.firstIndex(of: name).flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil } }
        let bundle = arg("--bundle") ?? "com.apple.TextEdit"
        var split = Int(arg("--split") ?? "") ?? 0
        let phase = arg("--phase") ?? "prepare"
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundle).first else {
            print("error: \(bundle) isn't running"); exit(1)
        }
        let pid = app.processIdentifier
        FocusContext.enableAccessibility(pid: pid)
        let root = AXUIElementCreateApplication(pid)
        var focused: CFTypeRef?
        AXUIElementCopyAttributeValue(root, kAXFocusedUIElementAttribute as CFString, &focused)
        guard let focused, CFGetTypeID(focused) == AXUIElementGetTypeID() else { print("error: no focused element"); exit(1) }
        let element = focused as! AXUIElement
        var valueRef: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &valueRef)
        let value = (valueRef as? String) ?? ""
        let ns = value as NSString
        // --find "text": split right after the last occurrence of that text.
        if let needle = arg("--find") {
            let found = ns.range(of: needle, options: .backwards)
            if found.location != NSNotFound { split = NSMaxRange(found) }
        }
        let lineEnd = ns.rangeOfCharacter(from: .newlines, options: [], range: NSRange(location: min(split, ns.length), length: ns.length - min(split, ns.length))).location
        let rest = ns.substring(with: NSRange(location: min(split, ns.length), length: (lineEnd == NSNotFound ? ns.length : lineEnd) - min(split, ns.length)))
            .replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression)

        if phase == "prepare", !args.contains("--no-move") {
            var caretRange = CFRange(location: split, length: 0)
            AXUIElementSetAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, AXValueCreate(.cfRange, &caretRange)!)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            let context = FocusContext.capture(pid: pid, forceInline: true)
            guard let style = context.inline else {
                print("error: no inline placement (source \(context.caretSource.rawValue), caret \(String(describing: context.caretRect)))")
                exit(2)
            }
            let primary = NSScreen.screens[0].frame.height
            let c = style.caret
            print(String(format: "caret %.1f %.1f %.1f %.1f", c.minX, primary - c.maxY, c.width, c.height))
            print("source \(context.caretSource.rawValue) font \(style.font?.fontName ?? "nil") \(style.font.map { String(format: "%.2f", $0.pointSize) } ?? "")")
            // --ghost "text": draw this instead of the rest of the line, with the leading
            // space Hushhh would add, and print exactly what to type to compare.
            let shown = arg("--ghost").map { TextInserter.applySmartSpacing($0, after: context.precedingCharacter) } ?? rest
            print("rest \(rest.debugDescription)")
            print("display \(shown)")
            guard phase == "draw" else { exit(0) }
            // --hero: draw exactly what a person sees (grey ghost text, full key hints),
            // for screenshots; otherwise solid red for pixel comparison.
            let hero = args.contains("--hero")
            OverlayController.debugGhostColor = hero ? nil : .systemRed
            let overlay = OverlayController()
            overlay.model.showHint = hero
            overlay.model.canPolish = hero
            overlay.model.level = hero ? 0.55 : 0
            overlay.model.text = shown
            overlay.show(anchor: .inline(style))
            print("drawn")
            DispatchQueue.main.asyncAfter(deadline: .now() + (hero ? 6 : 2.5)) { exit(0) }
        }
    }

    private static func findTextArea(in root: AXUIElement, depth: Int = 0) -> AXUIElement? {
        guard depth < 12 else { return nil }
        var children: CFTypeRef?
        AXUIElementCopyAttributeValue(root, kAXChildrenAttribute as CFString, &children)
        for child in (children as? [AXUIElement]) ?? [] {
            var role: CFTypeRef?
            AXUIElementCopyAttributeValue(child, kAXRoleAttribute as CFString, &role)
            if (role as? String) == kAXTextAreaRole { return child }
            if let found = findTextArea(in: child, depth: depth + 1) { return found }
        }
        return nil
    }

    private static func loadSamples(_ path: String) -> [Float]? {
        guard let file = try? AVAudioFile(forReading: URL(fileURLWithPath: path)),
              let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: file.processingFormat, to: target),
              let input = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)),
              (try? file.read(into: input)) != nil else { return nil }
        let capacity = AVAudioFrameCount(Double(input.frameLength) * 16_000 / file.processingFormat.sampleRate) + 1024
        guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return nil }
        var fed = false
        converter.convert(to: output, error: nil) { _, status in
            if fed { status.pointee = .endOfStream; return nil }
            fed = true
            status.pointee = .haveData
            return input
        }
        return Array(UnsafeBufferPointer(start: output.floatChannelData![0], count: Int(output.frameLength)))
    }
}
