import AppKit
import Combine

/// Runs a dictation session: Caps Lock starts listening, the live transcript
/// appears as ghost text by the caret, and Caps Lock again inserts it.
@MainActor
final class DictationController: ObservableObject {
    static let shared = DictationController()

    enum State: Equatable { case idle, starting, listening, finishing }

    enum EngineState: Equatable {
        case needsModel
        case loading
        case ready
        case failed(String)
    }

    @Published private(set) var state: State = .idle {
        didSet {
            guard state == .idle, oldValue != .idle else { return }
            // Every session ends here. Release on the next turn so the insert or paste that
            // follows `state = .idle` (it posts its keys synchronously) lands first.
            DispatchQueue.main.async { [weak self] in
                if self?.state == .idle { FocusContext.releaseAccessibility() }
            }
        }
    }
    @Published private(set) var engineState: EngineState = .needsModel

    private let prefs = Preferences.shared
    private let models = ModelStore.shared
    private let overlay = OverlayController()
    private let hotkeys = HotkeyMonitor()

    private var engine: SpeechEngine?
    private var engineKey: String?
    private var engineLoad: Task<SpeechEngine, Error>?

    private var recorder: AudioRecorder?
    private var live: LiveTranscriber?
    private var focus: FocusContext?
    /// Inline ghost text placement for this session. The mode is decided once at
    /// the start so the overlay doesn't jump between inline and bubble.
    private var sessionInline: FocusContext.InlineStyle?
    /// Identifies the current microphone start attempt, so a late or timed-out one is ignored.
    private var startToken: UUID?
    /// True while a microphone start is still blocked inside Core Audio.
    private var audioStartPending = false
    /// Core Audio calls can block for a long time if the audio service is stuck,
    /// so they never run on the main thread.
    private static let audioQueue = DispatchQueue(label: "com.graizlabs.hushhh.audio", qos: .userInitiated)
    private static let micStartTimeout: TimeInterval = 3
    private var pressStartedSession: Date?
    private var maxDurationWork: DispatchWorkItem?
    private var cancellables = Set<AnyCancellable>()
    private var hotkeyRetry: Timer?

    private static let maxDuration: TimeInterval = 5 * 60
    private static let holdThreshold: TimeInterval = 0.45

    private init() {
        hotkeys.onTriggerDown = { [weak self] in self?.triggerDown() }
        hotkeys.onTriggerUp = { [weak self] in self?.triggerUp() }
        hotkeys.onEscape = { [weak self] in self?.escape() ?? false }
        hotkeys.onTab = { [weak self] in self?.tabPressed() ?? false }

        // Reload the engine whenever the choice of engine or model changes.
        Publishers.Merge4(
            prefs.$engine.map { _ in () },
            prefs.$whisperModel.map { _ in () },
            prefs.$useGPU.map { _ in () },
            NotificationCenter.default.publisher(for: .modelsDidChange).map { _ in () }
        )
        .debounce(for: .milliseconds(200), scheduler: RunLoop.main)
        .sink { [weak self] in self?.prepareEngine() }
        .store(in: &cancellables)

        prefs.$showHints.sink { [weak self] in self?.overlay.model.showHint = $0 }.store(in: &cancellables)
    }

    // MARK: Lifecycle

    func activate() {
        PolishService.refresh()
        CapsLockRemapper.enable()
        startHotkeys()
        prepareEngine()
    }

    func deactivate() {
        hotkeys.stop()
        CapsLockRemapper.disable()
        // Quitting mid-session skips the usual end-of-session release.
        FocusContext.releaseAccessibility()
    }

    /// The event tap needs Accessibility; keep trying until it's granted.
    private func startHotkeys() {
        if hotkeys.start() { return }
        hotkeyRetry?.invalidate()
        hotkeyRetry = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] timer in
            Task { @MainActor in
                guard let self else { timer.invalidate(); return }
                if self.hotkeys.start() { timer.invalidate() }
            }
        }
    }

    // MARK: Engine

    var activeModelID: ModelID {
        prefs.engine == .qvac ? .qvac : .whisper(prefs.whisperModel)
    }

    var activeEngineName: String {
        prefs.engine == .qvac ? EngineKind.qvac.title : "Whisper \(prefs.whisperModel.title)"
    }

    private func currentKey() -> String {
        prefs.engine == .qvac ? "qvac-\(prefs.useGPU)" : "whisper-\(prefs.whisperModel.rawValue)"
    }

    /// Loads (or reuses) the engine for the current preferences, in the background.
    func prepareEngine() {
        let key = currentKey()
        if key == engineKey, engineLoad != nil || engine != nil { return }

        engine = nil
        engineLoad?.cancel()
        engineLoad = nil
        engineKey = key

        let newEngine: SpeechEngine
        switch prefs.engine {
        case .qvac:
            guard models.isInstalled(.qvac) else { engineState = .needsModel; engineKey = nil; return }
            newEngine = QVACEngine(modelURL: ModelStore.qvacModelURL, useGPU: prefs.useGPU)
        case .whisper:
            guard let folder = models.whisperFolder(prefs.whisperModel) else { engineState = .needsModel; engineKey = nil; return }
            newEngine = WhisperEngine(model: prefs.whisperModel, folder: folder)
        }

        engineState = .loading
        let load = Task<SpeechEngine, Error> {
            try await newEngine.load()
            return newEngine
        }
        engineLoad = load
        Task {
            do {
                let loaded = try await load.value
                guard self.engineKey == key else { return }
                self.engine = loaded
                self.engineState = .ready
            } catch {
                guard self.engineKey == key else { return }
                self.engineState = .failed(error.localizedDescription)
                self.engineLoad = nil
                self.engineKey = nil
            }
        }
    }

    private func loadedEngine() async throws -> SpeechEngine {
        if let engine { return engine }
        if let engineLoad { return try await engineLoad.value }
        throw NSError(domain: "Hushhh", code: 1, userInfo: [NSLocalizedDescriptionKey: "No speech model is installed."])
    }

    // MARK: Hotkey handling

    private func triggerDown() {
        switch state {
        case .idle:
            pressStartedSession = Date()
            start()
        case .listening:
            accept()
        case .starting, .finishing:
            break
        }
    }

    private func triggerUp() {
        defer { pressStartedSession = nil }
        // Holding Caps Lock works as push-to-talk: releasing it inserts.
        guard prefs.holdToTalk, state == .listening, let started = pressStartedSession,
              Date().timeIntervalSince(started) >= Self.holdThreshold else { return }
        accept()
    }

    /// Called synchronously from the event tap, so it must return immediately.
    private func escape() -> Bool {
        guard state == .listening || state == .starting else { return false }
        DispatchQueue.main.async { [weak self] in self?.cancel() }
        return true
    }

    /// Called synchronously from the event tap, so it must return immediately.
    private func tabPressed() -> Bool {
        guard state == .listening, prefs.polishEnabled, PolishService.isAvailable else { return false }
        DispatchQueue.main.async { [weak self] in self?.polish() }
        return true
    }

    /// Menu bar entry point.
    func toggle() {
        switch state {
        case .idle: start()
        case .listening: accept()
        case .starting, .finishing: break
        }
    }

    // MARK: Session

    private func start() {
        let permissions = Permissions.shared
        permissions.refresh()

        let context = FocusContext.capture()
        focus = context
        // capture() switched accessibility on. Paths that return before a session begins
        // never reach `state = .idle`, so they release here.
        defer { if state == .idle { FocusContext.releaseAccessibility() } }
        if context.isSecure {
            overlay.show(anchor: .screen)
            overlay.flash(symbol: "lock.fill", text: "Hushhh doesn’t dictate into password fields", duration: 2)
            return
        }
        FocusLog.isEnabled = prefs.diagnosticLog
        sessionInline = context.inline
        let app = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "?"
        FocusLog.write("start app=\(app) editable=\(context.isEditable) caret=\(FocusLog.describe(context.caretRect)) frame=\(FocusLog.describe(context.elementFrame)) inline=\(context.inline != nil) source=\(context.caretSource.rawValue) sel=\(context.selection.map { "\($0.location),\($0.length)" } ?? "nil") font=\(context.font?.fontName ?? "nil")")
        let anchor: OverlayController.Anchor = if let inline = context.inline {
            .inline(inline)
        } else if let caret = context.caretRect {
            .caret(caret)
        } else if let frame = context.elementFrame, context.isEditable, FocusContext.isUsable(frame) {
            .element(frame)
        } else if context.isEditable {
            // Canvas editors (Google Slides) expose nothing usable. The person just
            // clicked where they're typing, so show the bubble by the pointer.
            .caret(CGRect(x: NSEvent.mouseLocation.x, y: NSEvent.mouseLocation.y - 10, width: 1, height: 20))
        } else {
            .screen
        }

        if permissions.microphone == .notDetermined {
            // Ask first; starting the microphone while the prompt is up would stall.
            permissions.requestMicrophone()
            overlay.show(anchor: anchor)
            overlay.flash(symbol: "mic", text: "Allow microphone access, then press Caps Lock again", duration: 3)
            return
        }
        if audioStartPending {
            overlay.show(anchor: anchor)
            overlay.flash(symbol: "mic.slash", text: "The microphone isn’t responding. Restart Core Audio or your Mac.", isError: true, duration: 3.5)
            return
        }
        guard permissions.microphone != .denied else {
            overlay.show(anchor: anchor)
            overlay.flash(symbol: "mic.slash", text: "Allow microphone access in System Settings", isError: true, duration: 2.5)
            permissions.requestMicrophone()
            return
        }
        if engineState == .needsModel {
            overlay.show(anchor: anchor)
            overlay.flash(symbol: "arrow.down.circle", text: "Download a speech model to start dictating", isError: true, duration: 2.5)
            AppDelegate.shared?.showSettings(tab: .models)
            return
        }
        if case .failed = engineState { prepareEngine() }

        let live = LiveTranscriber(engineProvider: { [weak self] in
            guard let self else { throw CancellationError() }
            return try await self.loadedEngine()
        })
        live.onPartial = { [weak self] text in
            guard let self, self.state == .listening else { return }
            self.overlay.model.engineLoading = false
            // Inline, show the same leading space that inserting will add.
            self.overlay.model.text = self.sessionInline != nil && !text.isEmpty ? self.spaced(text) : text
            self.overlay.layout()
        }
        live.onError = { [weak self] error in
            guard let self, self.state == .listening else { return }
            self.teardownAudio()
            self.state = .idle
            self.overlay.flash(symbol: "exclamationmark.triangle", text: error.localizedDescription, isError: true, duration: 3)
        }

        let recorder = AudioRecorder()
        recorder.onSamples = { [weak live] samples in live?.append(samples, level: 0) }
        recorder.onLevel = { [weak self, weak live] level in
            live?.append([], level: level)
            DispatchQueue.main.async { self?.overlay.model.level = level }
        }

        state = .starting

        overlay.model.phase = .listening
        overlay.model.text = ""
        overlay.model.level = 0
        overlay.model.engineLoading = engineState != .ready
        overlay.model.busyLabel = nil
        overlay.model.canPolish = prefs.polishEnabled && PolishService.isAvailable
        overlay.show(anchor: anchor)

        // Open the microphone off the main thread; Core Audio can block.
        let token = UUID()
        startToken = token
        audioStartPending = true
        Self.audioQueue.async { [weak self] in
            let result = Result { try recorder.start() }
            DispatchQueue.main.async {
                self?.microphoneStarted(recorder: recorder, live: live, result: result, token: token, anchor: anchor)
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.micStartTimeout) { [weak self] in
            guard let self, self.startToken == token, self.state == .starting else { return }
            self.startToken = nil
            self.state = .idle
            self.overlay.flash(symbol: "mic.slash", text: "The microphone isn’t responding. Restart Core Audio or your Mac.", isError: true, duration: 3.5)
        }
    }

    private func microphoneStarted(recorder: AudioRecorder, live: LiveTranscriber,
                                   result: Result<Void, Error>, token: UUID, anchor: OverlayController.Anchor) {
        audioStartPending = false
        guard startToken == token, state == .starting else {
            // Cancelled or timed out while the microphone was starting.
            if case .success = result { Self.audioQueue.async { recorder.stop() } }
            return
        }
        startToken = nil
        if case .failure(let error) = result {
            state = .idle
            overlay.flash(symbol: "mic.slash", text: error.localizedDescription, isError: true)
            return
        }

        self.recorder = recorder
        self.live = live
        state = .listening
        live.start()
        Sound.play(.start)

        let work = DispatchWorkItem { [weak self] in
            if self?.state == .listening { self?.accept() }
        }
        maxDurationWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.maxDuration, execute: work)
    }

    private func accept() {
        guard state == .listening, let live else { return }
        state = .finishing
        maxDurationWork?.cancel()
        overlay.model.phase = .finishing
        overlay.layout()

        Task {
            // Keep the last syllable that was still in flight when the key was pressed.
            try? await Task.sleep(nanoseconds: 150_000_000)
            self.teardownAudio(keepTranscriber: true)
            let text = await live.finish().trimmingCharacters(in: .whitespacesAndNewlines)
            self.live = nil
            self.finishSession(with: text)
        }
    }

    /// Finishes dictation and replaces the text with a model's cleaned-up version.
    private func polish() {
        guard state == .listening, let live else { return }
        state = .finishing
        maxDurationWork?.cancel()
        overlay.model.phase = .finishing
        overlay.model.busyLabel = "Polishing with \(prefs.polishProvider.title)…"
        overlay.layout()

        Task {
            try? await Task.sleep(nanoseconds: 150_000_000)
            self.teardownAudio(keepTranscriber: true)
            let text = await live.finish().trimmingCharacters(in: .whitespacesAndNewlines)
            self.live = nil
            guard !text.isEmpty else {
                self.overlay.model.busyLabel = nil
                self.finishSession(with: text)
                return
            }
            do {
                var polished = try await PolishService.current().polish(text)
                self.overlay.model.busyLabel = nil
                self.state = .idle
                self.overlay.hide()
                guard let focus = self.focus, focus.isEditable, self.focusUnchanged() else {
                    TextInserter.copyToClipboard(polished)
                    self.overlay.flash(symbol: "doc.on.clipboard", text: "Polished text copied to clipboard", duration: 2.2)
                    return
                }
                let bundle = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? ""
                if FocusContext.terminalBundleIDs.contains(bundle) {
                    // A line break in a terminal would run the command.
                    polished = polished.replacingOccurrences(of: #"\s*\n+\s*"#, with: " ", options: .regularExpression)
                }
                let final = self.prefs.smartSpacing
                    ? TextInserter.applySmartSpacing(polished, after: focus.precedingCharacter) : polished
                // Paste, so paragraph breaks don't press Return (which sends in chat apps).
                TextInserter.insert(final, method: .paste)
                Sound.play(.insert)
            } catch {
                self.overlay.model.busyLabel = nil
                self.finishSession(with: text)
                self.overlay.flash(symbol: "exclamationmark.triangle",
                                   text: "Couldn’t polish: \(error.localizedDescription)", isError: true, duration: 3)
            }
        }
    }

    private func finishSession(with text: String) {
        state = .idle
        guard !text.isEmpty else {
            overlay.flash(symbol: "waveform.slash", text: "No speech detected", duration: 1.2)
            return
        }
        guard let focus, focus.element != nil, focus.isEditable || focus.caretRect != nil else {
            TextInserter.copyToClipboard(text)
            overlay.flash(symbol: "doc.on.clipboard", text: "No text field selected — copied to clipboard", duration: 2.2)
            Sound.play(.insert)
            return
        }
        guard focusUnchanged() else {
            // Never insert into an app the person switched to mid-session.
            TextInserter.copyToClipboard(text)
            overlay.flash(symbol: "doc.on.clipboard", text: "You switched apps — copied to clipboard", duration: 2.2)
            Sound.play(.insert)
            return
        }
        overlay.hide()
        let final = prefs.smartSpacing ? TextInserter.applySmartSpacing(text, after: focus.precedingCharacter) : text
        TextInserter.insert(final, method: prefs.insertion)
        Sound.play(.insert)
    }

    private func cancel() {
        startToken = nil
        maxDurationWork?.cancel()
        teardownAudio()
        state = .idle
        overlay.hide()
        Sound.play(.cancel)
    }

    /// Adds the space needed before `text` given what's already in the document.
    private func spaced(_ text: String) -> String {
        guard prefs.smartSpacing else { return text }
        return TextInserter.applySmartSpacing(text, after: focus?.precedingCharacter)
    }

    private func focusUnchanged() -> Bool {
        NSWorkspace.shared.frontmostApplication?.processIdentifier == focus?.appPID
    }

    private func teardownAudio(keepTranscriber: Bool = false) {
        if let recorder { Self.audioQueue.async { recorder.stop() } }
        recorder = nil
        if !keepTranscriber {
            live?.cancel()
            live = nil
        }
    }
}

/// Subtle system sounds for start, insert and cancel.
enum Sound {
    case start, insert, cancel

    @MainActor
    static func play(_ sound: Sound) {
        guard Preferences.shared.playSounds else { return }
        let name: String = switch sound {
        case .start: "Tink"
        case .insert: "Pop"
        case .cancel: "Bottle"
        }
        let s = NSSound(named: NSSound.Name(name))
        s?.volume = 0.35
        s?.play()
    }
}
