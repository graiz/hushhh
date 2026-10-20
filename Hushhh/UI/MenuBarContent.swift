import SwiftUI

struct MenuBarContent: View {
    @EnvironmentObject private var dictation: DictationController
    @EnvironmentObject private var prefs: Preferences
    @EnvironmentObject private var models: ModelStore
    @EnvironmentObject private var permissions: Permissions

    var body: some View {
        Text(statusLine)

        if permissions.accessibility != .granted {
            Button("Grant Accessibility Access…") { permissions.requestAccessibility() }
        }

        Button(dictation.state == .listening ? "Finish Dictation" : "Start Dictation") {
            dictation.toggle()
        }
        .disabled(dictation.state == .finishing || dictation.state == .starting)

        Divider()

        Picker("Speech Engine", selection: $prefs.engine) {
            ForEach(EngineKind.allCases) { kind in
                Text(kind.title).tag(kind)
            }
        }

        if prefs.engine == .whisper {
            Picker("Whisper Model", selection: $prefs.whisperModel) {
                ForEach(WhisperModel.allCases) { model in
                    Text(models.isInstalled(.whisper(model)) ? model.title : "\(model.title) — Not Downloaded")
                        .tag(model)
                }
            }
        }

        if !permissions.allGranted {
            Divider()
            Button("Finish Setting Up Hushhh…") { AppDelegate.shared?.showOnboarding() }
        }

        Divider()

        Button("Settings…") { AppDelegate.shared?.showSettings() }
            .keyboardShortcut(",")

        Button("Quit Hushhh") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }

    private var statusLine: String {
        if permissions.accessibility != .granted { return "Needs Accessibility Access" }
        switch dictation.state {
        case .starting: return "Starting Microphone…"
        case .listening: return "Listening…"
        case .finishing: return "Transcribing…"
        case .idle: break
        }
        switch dictation.engineState {
        case .needsModel: return "No Speech Model Downloaded"
        case .loading: return "Loading \(dictation.activeEngineName)…"
        case .failed: return "Model Failed to Load"
        case .ready: return "Ready — Press ⇪ Caps Lock to Dictate"
        }
    }
}
