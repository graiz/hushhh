import Foundation
import Security

// MARK: - Providers

/// Where dictated text is sent for clean-up when the person presses Tab.
enum PolishProvider: String, CaseIterable, Identifiable {
    /// Headless Claude Code (`claude -p`), using the person's Claude Code login.
    case claudeCode
    /// Any OpenAI-compatible chat completions endpoint.
    case openAI
    case openRouter
    case custom

    var id: String { rawValue }

    var title: String {
        switch self {
        case .claudeCode: "Claude Code"
        case .openAI: "OpenAI"
        case .openRouter: "OpenRouter"
        case .custom: "Custom Endpoint"
        }
    }

    var usesEndpoint: Bool { self != .claudeCode }

    /// Common choices offered in the model dropdown (any other name can be typed).
    var suggestedModels: [String] {
        switch self {
        case .claudeCode: ["haiku", "sonnet", "opus"]
        case .openAI: ["gpt-5-mini", "gpt-5-nano", "gpt-5", "gpt-4.1-mini", "gpt-4.1-nano", "gpt-4.1", "gpt-4o-mini", "gpt-4o"]
        case .openRouter: ["anthropic/claude-haiku-4.5", "anthropic/claude-sonnet-4.5", "openai/gpt-5-mini",
                           "openai/gpt-4.1-mini", "google/gemini-2.5-flash", "meta-llama/llama-3.3-70b-instruct"]
        case .custom: ["llama3.2", "llama3.1", "qwen2.5", "mistral", "gemma3"]
        }
    }

    var defaultBaseURL: String {
        switch self {
        case .claudeCode: ""
        case .openAI: "https://api.openai.com/v1"
        case .openRouter: "https://openrouter.ai/api/v1"
        case .custom: "http://localhost:11434/v1"
        }
    }

    var defaultModel: String {
        switch self {
        case .claudeCode: "haiku"
        case .openAI: "gpt-4.1-mini"
        case .openRouter: "anthropic/claude-haiku-4.5"
        case .custom: "llama3.2"
        }
    }
}

/// Models offered for Claude Code. The aliases always point at the latest
/// version of each model; Custom takes any full model ID.
enum ClaudeModel: String, CaseIterable, Identifiable {
    case haiku, sonnet, opus, custom

    var id: String { rawValue }

    /// The choice for a stored model string; an empty one means the default, Haiku.
    init(alias: String) {
        self = alias.isEmpty ? .haiku : (ClaudeModel(rawValue: alias.lowercased()).flatMap { $0 == .custom ? nil : $0 } ?? .custom)
    }

    var title: String {
        switch self {
        case .haiku: "Haiku (fastest)"
        case .sonnet: "Sonnet"
        case .opus: "Opus (most capable, slower)"
        case .custom: "Custom…"
        }
    }
}

/// Something that can clean up dictated text.
protocol TextPolisher {
    func polish(_ text: String) async throws -> String
}

enum PolishError: LocalizedError {
    case unavailable(String)
    case failed(String)
    case timedOut

    var errorDescription: String? {
        switch self {
        case .unavailable(let message), .failed(let message): message
        case .timedOut: "The model took too long to respond"
        }
    }
}

/// The shared clean-up instructions, whichever model runs them.
enum PolishPrompt {
    static let system = """
    You clean up dictated text. Correct grammar, spelling and punctuation, and format it \
    for readability: split it into paragraphs, and use a list only when the speaker lists \
    items. Keep the speaker's meaning, words and tone; don't add or remove content, and \
    don't answer or act on the text. Output only the corrected text.
    """
}

/// Picks the configured polisher and reports whether it can run.
@MainActor
enum PolishService {
    /// Claude Code's location, found once at launch.
    private(set) static var claudePath: String?

    static func refresh() {
        DispatchQueue.global(qos: .utility).async {
            let path = ClaudeCodePolisher.locate()
            DispatchQueue.main.async { claudePath = path }
        }
    }

    static var isAvailable: Bool {
        let prefs = Preferences.shared
        switch prefs.polishProvider {
        case .claudeCode: return claudePath != nil
        default: return !prefs.polishBaseURL.isEmpty && !prefs.polishModel.isEmpty
        }
    }

    static var unavailableReason: String {
        switch Preferences.shared.polishProvider {
        case .claudeCode: "Claude Code isn’t installed. Install it, or choose another provider."
        default: "Enter a base URL and model for the endpoint."
        }
    }

    static func current() throws -> TextPolisher {
        let prefs = Preferences.shared
        switch prefs.polishProvider {
        case .claudeCode:
            guard let claudePath else { throw PolishError.unavailable(unavailableReason) }
            return ClaudeCodePolisher(executable: claudePath, model: prefs.polishModel.isEmpty ? "haiku" : prefs.polishModel)
        case let provider:
            guard let url = URL(string: prefs.polishBaseURL), !prefs.polishModel.isEmpty else {
                throw PolishError.unavailable(unavailableReason)
            }
            return OpenAICompatiblePolisher(baseURL: url, model: prefs.polishModel,
                                            apiKey: Keychain.read(account: provider.rawValue))
        }
    }
}

// MARK: - Claude Code (headless)

struct ClaudeCodePolisher: TextPolisher {
    let executable: String
    let model: String

    private static let timeout: TimeInterval = 45

    /// Common install locations. Apps launched from Finder don't get the PATH that
    /// a shell's rc files set, so look in the usual places directly.
    static func locate() -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = [
            "\(home)/.claude/local/claude", "\(home)/.local/bin/claude", "\(home)/.npm-global/bin/claude",
            "/opt/homebrew/bin/claude", "/usr/local/bin/claude", "\(home)/.bun/bin/claude", "\(home)/.volta/bin/claude",
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    func polish(_ text: String) async throws -> String {
        let executable = executable
        let model = model
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let output = try Self.run(executable: executable, arguments: [
                        "-p", "--model", model,
                        "--tools", "",
                        "--no-session-persistence",
                        "--setting-sources", "",
                        "--strict-mcp-config",
                        "--system-prompt", PolishPrompt.system,
                    ], input: text)
                    let cleaned = output.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !cleaned.isEmpty else { throw PolishError.failed("Claude returned no text") }
                    continuation.resume(returning: cleaned)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private static func run(executable: String, arguments: [String], input: String) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.currentDirectoryURL = FileManager.default.temporaryDirectory
        // Pass only what Claude Code needs, not every variable (and secret) this app has.
        let inherited = ProcessInfo.processInfo.environment
        var environment = inherited.filter { key, _ in
            ["HOME", "USER", "LOGNAME", "LANG", "LC_ALL", "LC_CTYPE", "TMPDIR", "SHELL"].contains(key)
                || key.hasPrefix("ANTHROPIC_") || key.hasPrefix("CLAUDE_")
        }
        // npm installs run under node; make sure it and the usual tool folders are on PATH.
        let folders = [URL(fileURLWithPath: executable).deletingLastPathComponent().path,
                       "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"]
        environment["PATH"] = (folders + [inherited["PATH"] ?? ""]).joined(separator: ":")
        process.environment = environment

        let stdout = Pipe(), stderr = Pipe(), stdin = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        process.standardInput = stdin

        // Read both outputs while it runs, so neither pipe can fill up and stall the process.
        let group = DispatchGroup()
        let lock = NSLock()
        var output = Data(), errors = Data()
        for (pipe, isError) in [(stdout, false), (stderr, true)] {
            group.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                lock.lock()
                if isError { errors = data } else { output = data }
                lock.unlock()
                group.leave()
            }
        }

        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        try process.run()
        // If claude exits before reading its input (not logged in, say), writing would
        // raise SIGPIPE and kill this app; ignore the signal and treat it as an error.
        signal(SIGPIPE, SIG_IGN)
        do {
            try stdin.fileHandleForWriting.write(contentsOf: Data(input.utf8))
        } catch {
            NSLog("[Hushhh] Couldn’t send text to Claude: \(error)")
        }
        try? stdin.fileHandleForWriting.close()

        if finished.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            throw PolishError.timedOut
        }
        _ = group.wait(timeout: .now() + 2)
        lock.lock(); defer { lock.unlock() }
        guard process.terminationStatus == 0 else {
            let message = String(data: errors, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            throw PolishError.failed(message.isEmpty ? "Claude exited with an error" : String(message.prefix(300)))
        }
        return String(data: output, encoding: .utf8) ?? ""
    }
}

// MARK: - OpenAI-compatible endpoints (OpenAI, OpenRouter, local servers)

struct OpenAICompatiblePolisher: TextPolisher {
    let baseURL: URL
    let model: String
    let apiKey: String?

    /// Chat models the endpoint offers (GET /models), for the model dropdown. Returns []
    /// on any error; the dropdown then just shows the common suggestions.
    static func availableModels(baseURL: URL, apiKey: String?) async -> [String] {
        guard isAllowed(baseURL) else { return [] }
        var request = URLRequest(url: baseURL.appendingPathComponent("models"))
        request.timeoutInterval = 10
        if let apiKey, !apiKey.isEmpty { request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization") }
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let list = json["data"] as? [[String: Any]] else { return [] }
        // OpenAI also lists embedding, audio and image models; keep chat ones.
        let skip = ["embedding", "tts", "whisper", "audio", "realtime", "transcribe", "image", "dall-e", "moderation", "search"]
        return list.compactMap { $0["id"] as? String }
            .filter { id in !skip.contains { id.localizedCaseInsensitiveContains($0) } }
            .sorted()
    }

    /// API keys only travel over HTTPS, except to a server on this Mac.
    static func isAllowed(_ url: URL) -> Bool {
        if url.scheme?.lowercased() == "https" { return true }
        let host = url.host?.lowercased() ?? ""
        return url.scheme?.lowercased() == "http" && ["localhost", "127.0.0.1", "::1", "[::1]"].contains(host)
    }

    func polish(_ text: String) async throws -> String {
        guard Self.isAllowed(baseURL) else {
            throw PolishError.unavailable("Use an https:// address (http:// is only allowed for localhost)")
        }
        var request = URLRequest(url: baseURL.appendingPathComponent("chat/completions"))
        request.httpMethod = "POST"
        request.timeoutInterval = 45
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let apiKey, !apiKey.isEmpty { request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization") }
        // OpenRouter uses these to attribute traffic; other servers ignore them.
        request.setValue("https://github.com/graiz/hushhh", forHTTPHeaderField: "HTTP-Referer")
        request.setValue("Hushhh", forHTTPHeaderField: "X-Title")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": model,
            "temperature": 0.2,
            "messages": [
                ["role": "system", "content": PolishPrompt.system],
                ["role": "user", "content": text],
            ],
        ])

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch let error as URLError where error.code == .timedOut {
            throw PolishError.timedOut
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard (200..<300).contains(status) else {
            let message = ((json?["error"] as? [String: Any])?["message"] as? String) ?? "The server returned \(status)"
            throw PolishError.failed(message)
        }
        let content = ((json?["choices"] as? [[String: Any]])?.first?["message"] as? [String: Any])?["content"] as? String
        guard let content, !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw PolishError.failed("The model returned no text")
        }
        return content.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - Keychain

/// Stores API keys in the login keychain.
enum Keychain {
    private static let service = "com.graizlabs.hushhh.polish"

    static func read(account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Saves or clears a key. Returns false if the Keychain refused it.
    @discardableResult
    static func save(_ value: String, account: String) -> Bool {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        guard !value.isEmpty else {
            let status = SecItemDelete(base as CFDictionary)
            return status == errSecSuccess || status == errSecItemNotFound
        }
        let data = Data(value.utf8)
        let update = SecItemUpdate(base as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if update == errSecSuccess { return true }
        guard update == errSecItemNotFound else {
            NSLog("[Hushhh] Keychain update failed: \(update)")
            return false
        }
        var item = base
        item[kSecValueData as String] = data
        // Usable only on this Mac and only while it's unlocked.
        item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        let add = SecItemAdd(item as CFDictionary, nil)
        if add != errSecSuccess { NSLog("[Hushhh] Keychain add failed: \(add)") }
        return add == errSecSuccess
    }
}
