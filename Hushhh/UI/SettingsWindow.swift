import AppKit
import SwiftUI
import ServiceManagement

enum SettingsTab: Int, CaseIterable {
    case general, models, polish, permissions

    var title: String {
        switch self {
        case .general: "General"
        case .models: "Models"
        case .polish: "Polish"
        case .permissions: "Permissions"
        }
    }

    var symbol: String {
        switch self {
        case .general: "gearshape"
        case .models: "waveform"
        case .polish: "wand.and.stars"
        case .permissions: "hand.raised"
        }
    }
}

/// A standard macOS Settings window with toolbar tabs.
@MainActor
final class SettingsWindowController: NSWindowController {
    private let tabs = NSTabViewController()

    init() {
        tabs.tabStyle = .toolbar
        for tab in SettingsTab.allCases {
            let root: AnyView = switch tab {
            case .general: AnyView(GeneralSettings())
            case .models: AnyView(ModelSettings())
            case .polish: AnyView(PolishSettings())
            case .permissions: AnyView(PermissionSettings())
            }
            let host = NSHostingController(rootView: root
                .environmentObject(Preferences.shared)
                .environmentObject(ModelStore.shared)
                .environmentObject(Permissions.shared)
                .environmentObject(DictationController.shared))
            host.sizingOptions = .preferredContentSize
            host.title = tab.title  // the window title follows the selected tab
            let item = NSTabViewItem(viewController: host)
            item.label = tab.title
            item.image = NSImage(systemSymbolName: tab.symbol, accessibilityDescription: tab.title)
            tabs.addTabViewItem(item)
        }
        let window = NSWindow(contentViewController: tabs)
        window.styleMask = [.titled, .closable]
        window.toolbarStyle = .preference
        window.isReleasedWhenClosed = false
        super.init(window: window)
    }

    required init?(coder: NSCoder) { fatalError() }

    func show(tab: SettingsTab) {
        tabs.selectedTabViewItemIndex = tab.rawValue
        if window?.isVisible != true { window?.center() }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

// MARK: - General

struct GeneralSettings: View {
    @EnvironmentObject private var prefs: Preferences
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginError: String?

    var body: some View {
        Form {
            Section {
                LabeledContent("Dictation key") { KeyCap("⇪ Caps Lock") }
                Toggle("Hold to talk", isOn: $prefs.holdToTalk)
            } footer: {
                SettingsFooter("Press Caps Lock once to start dictating and again when you’re done. Press Esc to cancel and remove what was typed. With Hold to talk, you can also hold Caps Lock while speaking and release it to finish.")
            }

            Section {
                Toggle("Type words as you speak", isOn: $prefs.liveTyping)
                if prefs.liveTyping {
                    LabeledContent("Wait before typing") {
                        HStack {
                            Slider(value: $prefs.commitDelay, in: 1...6, step: 0.5)
                                .frame(width: 160)
                                .accessibilityValue("\(prefs.commitDelay, specifier: "%.1f") seconds")
                            Text("\(prefs.commitDelay, specifier: "%.1f") s")
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                                .frame(width: 44, alignment: .trailing)
                                .accessibilityHidden(true)
                        }
                    }
                }
            } header: {
                Text("Live Typing")
            } footer: {
                SettingsFooter(prefs.liveTyping
                     ? "Recent words appear as grey ghost text while Hushhh settles on them, then they’re typed into the field. A longer wait gives more accurate text. Esc and Tab replace typed text only in apps that let Hushhh select it."
                     : "Your words appear as grey ghost text and nothing is typed until you press Caps Lock (or Tab to polish). Esc leaves the document untouched.")
            }

            Section {
                Picker("Insert method", selection: $prefs.insertion) {
                    ForEach(InsertionMethod.allCases) { Text($0.title).tag($0) }
                }
                Toggle("Add a space before dictated text when needed", isOn: $prefs.smartSpacing)
            } header: {
                Text("Inserting Text")
            } footer: {
                SettingsFooter((prefs.liveTyping ? "Used when Live Typing is off. " : "")
                    + (prefs.insertion == .paste
                       ? "Pasting is fastest and works in most apps. Your clipboard is restored afterward."
                       : "Typing works in apps that block pasting, but is slower for long passages."))
            }

            Section("Feedback") {
                Toggle("Play sounds", isOn: $prefs.playSounds)
                Toggle("Show keyboard hints while listening", isOn: $prefs.showHints)
            }

            Section {
                Toggle("Write a diagnostic log", isOn: $prefs.diagnosticLog)
            } header: {
                Text("Troubleshooting")
            } footer: {
                SettingsFooter("Records where apps report the text cursor (positions, field sizes and font names, never your text) to ~/Library/Logs/Hushhh/focus.log, to help fix ghost-text placement.")
            }

            Section {
                Toggle("Open at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, enabled in
                        do {
                            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                        } catch {
                            launchAtLogin = SMAppService.mainApp.status == .enabled
                            loginError = error.localizedDescription
                        }
                    }
            }
        }
        .formStyle(.grouped)
        .frame(width: 500)
        .fixedSize(horizontal: false, vertical: true)
        .alert("Couldn’t Change Open at Login", isPresented: Binding(get: { loginError != nil }, set: { if !$0 { loginError = nil } })) {
            Button("OK") { loginError = nil }
        } message: {
            Text(loginError ?? "")
        }
    }
}

/// Explanatory text under a settings section.
struct SettingsFooter: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.footnote)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: - Models

struct ModelSettings: View {
    @EnvironmentObject private var prefs: Preferences
    @EnvironmentObject private var models: ModelStore
    @EnvironmentObject private var dictation: DictationController

    var body: some View {
        Form {
            Section {
                Picker("Speech engine", selection: $prefs.engine) {
                    ForEach(EngineKind.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.radioGroup)
                LabeledContent("Status") { EngineStatusLabel(state: dictation.engineState) }
            } footer: {
                SettingsFooter(prefs.engine.summary + " Everything runs on this Mac; audio never leaves your device.")
            }

            if prefs.engine == .qvac {
                Section("QVAC TranscribePsy") {
                    ModelRow(title: "TranscribePsy 250M", detail: "GGUF · \(ModelStore.qvacSizeLabel)", id: .qvac,
                             isSelected: prefs.engine == .qvac && models.isInstalled(.qvac), onSelect: { prefs.engine = .qvac })
                    Toggle("Use the GPU (Metal)", isOn: $prefs.useGPU)
                }
            } else {
                Section("Whisper Models") {
                    ForEach(WhisperModel.allCases) { model in
                        ModelRow(title: model.title,
                                 detail: model.sizeLabel,
                                 id: .whisper(model),
                                 isSelected: prefs.whisperModel == model,
                                 onSelect: { prefs.whisperModel = model })
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 500)
        .fixedSize(horizontal: false, vertical: true)
    }
}

struct EngineStatusLabel: View {
    let state: DictationController.EngineState

    var body: some View {
        switch state {
        case .ready:
            Label("Ready", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
        case .loading:
            HStack(spacing: 6) { ProgressView().controlSize(.small); Text("Loading…") }
        case .needsModel:
            Label("Download a model below", systemImage: "arrow.down.circle").foregroundStyle(.secondary)
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange).lineLimit(2)
        }
    }
}

/// One downloadable model with its install state.
struct ModelRow: View {
    @EnvironmentObject private var models: ModelStore
    let title: String
    let detail: String
    let id: ModelID
    let isSelected: Bool
    let onSelect: () -> Void
    @State private var confirmDelete = false

    var body: some View {
        HStack(spacing: 10) {
            // The whole row selects the model; the trailing control manages the download.
            Button(action: onSelect) {
                HStack(spacing: 10) {
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                        .font(.system(size: 15))
                    VStack(alignment: .leading, spacing: 1) {
                        Text(title)
                        Text(subtitle)
                            .font(.caption)
                            .foregroundStyle(isFailed ? Color.orange : Color.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(isSelected ? [.isSelected] : [])
            trailing
        }
        .confirmationDialog("Delete \(title)?", isPresented: $confirmDelete) {
            Button("Delete", role: .destructive) { models.delete(id) }
        } message: {
            Text("You can download it again at any time.")
        }
    }

    private var isFailed: Bool {
        if case .failed = models.status(id) { return true }
        return false
    }

    private var subtitle: String {
        switch models.status(id) {
        case .installed: detail
        case .notInstalled: "\(detail) · Not downloaded"
        case .downloading: "\(detail) · Downloading…"
        case .failed(let message): "Download failed: \(message)"
        }
    }

    @ViewBuilder
    private var trailing: some View {
        switch models.status(id) {
        case .installed:
            Button("Delete…") { confirmDelete = true }
        case .downloading(let fraction):
            HStack(spacing: 8) {
                ProgressView(value: fraction).frame(width: 100)
                Text("\(Int(fraction * 100))%")
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(width: 34, alignment: .trailing)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Downloading, \(Int(fraction * 100)) percent")
        case .notInstalled:
            Button("Download") { models.download(id); onSelect() }
        case .failed:
            Button("Try Again") { models.download(id) }
        }
    }
}

// MARK: - Polish

struct PolishSettings: View {
    @EnvironmentObject private var prefs: Preferences
    @State private var apiKey = ""
    @State private var keyError: String?
    @FocusState private var keyFieldFocused: Bool
    @State private var testState: TestState = .idle
    /// Custom is shown while the person types a model ID, even before it's valid.
    @State private var customModel = false

    enum TestState: Equatable {
        case idle, running
        case passed(String)
        case failed(String)
    }

    var body: some View {
        Form {
            Section {
                Toggle("Press Tab to polish dictation", isOn: $prefs.polishEnabled)
            } footer: {
                SettingsFooter("While dictating, press Tab to finish and have a language model correct grammar, spelling and punctuation and add paragraphs. Handy for longer emails. Speech recognition always stays on this Mac; only the text you polish is sent to the provider below.")
            }

            Section {
                Picker("Provider", selection: $prefs.polishProvider) {
                    ForEach(PolishProvider.allCases) { Text($0.title).tag($0) }
                }
                if prefs.polishProvider.usesEndpoint {
                    TextField("Base URL", text: $prefs.polishBaseURL, prompt: Text(prefs.polishProvider.defaultBaseURL))
                    TextField("Model", text: $prefs.polishModel, prompt: Text(prefs.polishProvider.defaultModel))
                    SecureField("API key", text: $apiKey, prompt: Text(prefs.polishProvider == .custom ? "Optional" : "Required"))
                        .focused($keyFieldFocused)
                        .onSubmit { saveKey() }
                        .onChange(of: keyFieldFocused) { _, focused in if !focused { saveKey() } }
                    if let keyError {
                        Text(keyError).font(.caption).foregroundStyle(.orange)
                    }
                    if let url = URL(string: prefs.polishBaseURL), !prefs.polishBaseURL.isEmpty, !OpenAICompatiblePolisher.isAllowed(url) {
                        Label("Use https:// — http:// is only allowed for a server on this Mac.", systemImage: "exclamationmark.triangle.fill")
                            .font(.caption).foregroundStyle(.orange)
                    }
                } else {
                    Picker("Model", selection: claudeModelChoice) {
                        ForEach(ClaudeModel.allCases) { model in
                            Text(model.title).tag(model)
                        }
                    }
                    if customModel {
                        TextField("Model ID", text: $prefs.polishModel, prompt: Text("claude-sonnet-5-5"))
                    }
                    LabeledContent("Status") {
                        if PolishService.isAvailable {
                            Label("Installed", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                        } else {
                            Label("Not found", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                        }
                    }
                }
                LabeledContent("") {
                    HStack(spacing: 8) {
                        testResult
                        Button("Test") { runTest() }
                            .disabled(testState == .running || !PolishService.isAvailable)
                    }
                }
            } header: {
                Text("Language Model")
            } footer: {
                SettingsFooter(footer)
            }
        }
        .formStyle(.grouped)
        .frame(width: 500)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear {
            loadKey()
            customModel = prefs.polishProvider == .claudeCode && ClaudeModel(alias: prefs.polishModel) == .custom
        }
        .onChange(of: prefs.polishProvider) { _, provider in
            customModel = provider == .claudeCode && ClaudeModel(alias: prefs.polishModel) == .custom
            loadKey()
            testState = .idle
        }
    }

    /// Maps the stored model string to a picker choice; anything unrecognised is Custom.
    private var claudeModelChoice: Binding<ClaudeModel> {
        Binding(
            get: { customModel ? .custom : ClaudeModel(alias: prefs.polishModel) },
            set: { choice in
                customModel = choice == .custom
                if choice != .custom { prefs.polishModel = choice.rawValue }
            }
        )
    }

    private var footer: String {
        switch prefs.polishProvider {
        case .claudeCode:
            "Runs Claude Code headless (claude -p) with your Claude Code login, no tools and no saved session. The text is sent to Anthropic."
        case .openAI:
            "Uses the OpenAI chat completions API. Your key is stored in the macOS Keychain. The text is sent to OpenAI."
        case .openRouter:
            "Uses OpenRouter, which can route to many models. Your key is stored in the macOS Keychain. The text is sent to OpenRouter and the model’s provider."
        case .custom:
            "Any OpenAI-compatible server, including local ones such as Ollama or LM Studio. A local server keeps your text on this Mac."
        }
    }

    @ViewBuilder
    private var testResult: some View {
        switch testState {
        case .idle: EmptyView()
        case .running: ProgressView().controlSize(.small)
        case .passed(let sample):
            Label(sample, systemImage: "checkmark.circle.fill").foregroundStyle(.green).lineLimit(1).truncationMode(.tail)
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange).lineLimit(2)
        }
    }

    private func saveKey() {
        keyError = Keychain.save(apiKey, account: prefs.polishProvider.rawValue)
            ? nil : "Couldn’t save the key to the Keychain."
    }

    private func loadKey() {
        apiKey = prefs.polishProvider.usesEndpoint ? (Keychain.read(account: prefs.polishProvider.rawValue) ?? "") : ""
    }

    private func runTest() {
        saveKey()
        testState = .running
        Task {
            do {
                let result = try await PolishService.current().polish("hello this is a test of the polish feature can you hear me")
                testState = .passed(result)
            } catch {
                testState = .failed(error.localizedDescription)
            }
        }
    }
}

// MARK: - Permissions

struct PermissionSettings: View {
    @EnvironmentObject private var permissions: Permissions

    var body: some View {
        Form {
            Section {
                PermissionRow(symbol: "mic.fill",
                              title: "Microphone",
                              detail: "To hear you while you dictate.",
                              status: permissions.microphone,
                              action: permissions.requestMicrophone)
                PermissionRow(symbol: "accessibility",
                              title: "Accessibility",
                              detail: "To detect Caps Lock, find the text cursor and insert text.",
                              status: permissions.accessibility,
                              action: permissions.requestAccessibility)
            } footer: {
                SettingsFooter("While Hushhh is running, Caps Lock is reserved for dictation. Quitting Hushhh restores it.")
            }
        }
        .formStyle(.grouped)
        .frame(width: 500)
        .fixedSize(horizontal: false, vertical: true)
    }
}

struct PermissionRow: View {
    let symbol: String
    let title: String
    let detail: String
    let status: Permissions.Status
    let action: () -> Void
    /// Onboarding shows a coloured tile; Settings uses a plain symbol like System Settings rows.
    var tiled = false

    var body: some View {
        HStack(spacing: 12) {
            Group {
                if tiled {
                    Image(systemName: symbol)
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(.white)
                        .frame(width: 28, height: 28)
                        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color.accentColor.gradient))
                } else {
                    Image(systemName: symbol)
                        .font(.system(size: 15))
                        .foregroundStyle(.secondary)
                        .frame(width: 22)
                }
            }
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if status == .granted {
                Label("Allowed", systemImage: "checkmark.circle.fill")
                    .labelStyle(.titleAndIcon)
                    .foregroundStyle(.green)
            } else {
                Button(status == .notDetermined ? "Allow…" : "Open Settings…", action: action)
            }
        }
    }
}
