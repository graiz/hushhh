import Foundation

enum EngineKind: String, CaseIterable, Identifiable {
    case qvac
    case whisper

    var id: String { rawValue }

    var title: String {
        switch self {
        case .qvac: "QVAC TranscribePsy"
        case .whisper: "Whisper"
        }
    }

    var summary: String {
        switch self {
        case .qvac: "Fastest and most accurate. English, Spanish, French, German, Italian, Portuguese, Dutch and Polish."
        case .whisper: "OpenAI Whisper on the Neural Engine. Supports 99 languages; pick a size that suits your Mac."
        }
    }
}

enum WhisperModel: String, CaseIterable, Identifiable {
    case tinyEn = "openai_whisper-tiny.en"
    case baseEn = "openai_whisper-base.en"
    case smallEn = "openai_whisper-small.en_217MB"
    case base = "openai_whisper-base"
    case turbo = "openai_whisper-large-v3-v20240930_turbo_632MB"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .tinyEn: "Tiny (English)"
        case .baseEn: "Base (English)"
        case .smallEn: "Small (English)"
        case .base: "Base (Multilingual)"
        case .turbo: "Large v3 Turbo (Multilingual)"
        }
    }

    var sizeLabel: String {
        switch self {
        case .tinyEn: "75 MB"
        case .baseEn, .base: "145 MB"
        case .smallEn: "217 MB"
        case .turbo: "632 MB"
        }
    }

    var isEnglishOnly: Bool { rawValue.contains(".en") }
}

enum InsertionMethod: String, CaseIterable, Identifiable {
    case paste
    case type

    var id: String { rawValue }

    var title: String {
        switch self {
        case .paste: "Paste"
        case .type: "Type Characters"
        }
    }
}

/// User preferences, persisted to UserDefaults.
@MainActor
final class Preferences: ObservableObject {
    static let shared = Preferences()
    private let defaults = UserDefaults.standard

    @Published var engine: EngineKind { didSet { defaults.set(engine.rawValue, forKey: "engine") } }
    @Published var whisperModel: WhisperModel { didSet { defaults.set(whisperModel.rawValue, forKey: "whisperModel") } }
    @Published var insertion: InsertionMethod { didSet { defaults.set(insertion.rawValue, forKey: "insertion") } }
    @Published var playSounds: Bool { didSet { defaults.set(playSounds, forKey: "playSounds") } }
    @Published var smartSpacing: Bool { didSet { defaults.set(smartSpacing, forKey: "smartSpacing") } }
    @Published var holdToTalk: Bool { didSet { defaults.set(holdToTalk, forKey: "holdToTalk") } }
    @Published var useGPU: Bool { didSet { defaults.set(useGPU, forKey: "useGPU") } }
    @Published var showHints: Bool { didSet { defaults.set(showHints, forKey: "showHints") } }
    /// Type words into the field once they've been stable for `commitDelay` seconds.
    @Published var liveTyping: Bool { didSet { defaults.set(liveTyping, forKey: "liveTyping") } }
    @Published var commitDelay: Double { didSet { defaults.set(commitDelay, forKey: "commitDelay") } }
    /// Tab during dictation sends the text to Claude Haiku for clean-up.
    @Published var polishEnabled: Bool { didSet { defaults.set(polishEnabled, forKey: "polishWithClaude") } }
    /// Which model cleans up text. Base URL and model are remembered per provider.
    @Published var polishProvider: PolishProvider {
        didSet {
            defaults.set(polishProvider.rawValue, forKey: "polishProvider")
            polishBaseURL = defaults.string(forKey: "polishBaseURL.\(polishProvider.rawValue)") ?? polishProvider.defaultBaseURL
            polishModel = defaults.string(forKey: "polishModel.\(polishProvider.rawValue)") ?? polishProvider.defaultModel
        }
    }
    @Published var polishBaseURL: String { didSet { defaults.set(polishBaseURL, forKey: "polishBaseURL.\(polishProvider.rawValue)") } }
    @Published var polishModel: String { didSet { defaults.set(polishModel, forKey: "polishModel.\(polishProvider.rawValue)") } }
    /// Writes ~/Library/Logs/Hushhh/focus.log (caret positions only) for troubleshooting.
    @Published var diagnosticLog: Bool { didSet { defaults.set(diagnosticLog, forKey: "diagnosticLog") } }
    @Published var hasCompletedOnboarding: Bool { didSet { defaults.set(hasCompletedOnboarding, forKey: "hasCompletedOnboarding") } }

    private init() {
        defaults.register(defaults: [
            "engine": EngineKind.qvac.rawValue,
            "whisperModel": WhisperModel.baseEn.rawValue,
            "insertion": InsertionMethod.paste.rawValue,
            "playSounds": true,
            "smartSpacing": true,
            "holdToTalk": false,
            "useGPU": true,
            "showHints": true,
            "liveTyping": false,
            "commitDelay": 3.0,
            "polishWithClaude": false,
            "diagnosticLog": false,
            "hasCompletedOnboarding": false,
        ])
        engine = EngineKind(rawValue: defaults.string(forKey: "engine") ?? "") ?? .qvac
        whisperModel = WhisperModel(rawValue: defaults.string(forKey: "whisperModel") ?? "") ?? .baseEn
        insertion = InsertionMethod(rawValue: defaults.string(forKey: "insertion") ?? "") ?? .paste
        playSounds = defaults.bool(forKey: "playSounds")
        smartSpacing = defaults.bool(forKey: "smartSpacing")
        holdToTalk = defaults.bool(forKey: "holdToTalk")
        useGPU = defaults.bool(forKey: "useGPU")
        showHints = defaults.bool(forKey: "showHints")
        // Ghost text until accept is now the default; switch earlier installs over once.
        if !defaults.bool(forKey: "migratedGhostDefault") {
            defaults.set(false, forKey: "liveTyping")
            defaults.set(true, forKey: "migratedGhostDefault")
        }
        liveTyping = defaults.bool(forKey: "liveTyping")
        commitDelay = defaults.double(forKey: "commitDelay")
        // Polish sends text off the Mac, so new installs start with it off. Installs that
        // already relied on the old default keep it on.
        // (Check the saved settings only: registered defaults would answer for a missing key.)
        let store = UserDefaults.standard
        let saved = Bundle.main.bundleIdentifier.flatMap { store.persistentDomain(forName: $0) } ?? [:]
        if saved["polishWithClaude"] == nil, saved["hasCompletedOnboarding"] as? Bool == true {
            defaults.set(true, forKey: "polishWithClaude")
        }
        polishEnabled = defaults.bool(forKey: "polishWithClaude")
        let provider = PolishProvider(rawValue: defaults.string(forKey: "polishProvider") ?? "") ?? .claudeCode
        polishProvider = provider
        polishBaseURL = defaults.string(forKey: "polishBaseURL.\(provider.rawValue)") ?? provider.defaultBaseURL
        polishModel = defaults.string(forKey: "polishModel.\(provider.rawValue)") ?? provider.defaultModel
        diagnosticLog = defaults.bool(forKey: "diagnosticLog")
        hasCompletedOnboarding = defaults.bool(forKey: "hasCompletedOnboarding")
    }
}
