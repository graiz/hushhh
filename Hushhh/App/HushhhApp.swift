import SwiftUI
import AppKit

@main
struct HushhhApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var dictation = DictationController.shared
    @StateObject private var prefs = Preferences.shared

    var body: some Scene {
        MenuBarExtra {
            MenuBarContent()
                .environmentObject(dictation)
                .environmentObject(prefs)
                .environmentObject(ModelStore.shared)
                .environmentObject(Permissions.shared)
        } label: {
            Image(systemName: menuBarSymbol)
                .accessibilityLabel(menuBarLabel)
        }
        .menuBarExtraStyle(.menu)
    }

    @StateObject private var permissions = Permissions.shared

    private var menuBarSymbol: String {
        if permissions.accessibility != .granted && dictation.state == .idle { return "waveform.badge.exclamationmark" }
        return switch dictation.state {
        case .listening: "waveform.circle.fill"
        case .starting, .finishing: "ellipsis.circle"
        case .idle: "waveform"
        }
    }

    private var menuBarLabel: String {
        switch dictation.state {
        case .listening: "Hushhh, listening"
        case .starting, .finishing: "Hushhh, working"
        case .idle: permissions.accessibility == .granted ? "Hushhh" : "Hushhh, needs Accessibility access"
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    static private(set) weak var shared: AppDelegate?

    private var settingsController: SettingsWindowController?
    private var onboardingWindow: NSWindow?

    /// Developer diagnostics (see README) only run with HUSHHH_DEV=1 in the environment.
    private static let developerMode = ProcessInfo.processInfo.environment["HUSHHH_DEV"] == "1"

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppDelegate.shared = self
        if Self.developerMode, runDeveloperCommand() { return }
        MainActor.assumeIsolated {
            DictationController.shared.activate()
            if !Preferences.shared.hasCompletedOnboarding || !Permissions.shared.allGranted {
                showOnboarding()
            }
        }
    }

    /// Returns true if a developer command took over the launch.
    private func runDeveloperCommand() -> Bool {
        if let index = CommandLine.arguments.firstIndex(of: "--transcribe"), index + 1 < CommandLine.arguments.count {
            Diagnostics.transcribe(file: CommandLine.arguments[index + 1])
            return true
        }
        if let index = CommandLine.arguments.firstIndex(of: "--probe-focus"), index + 1 < CommandLine.arguments.count {
            MainActor.assumeIsolated { Diagnostics.probeFocus(log: CommandLine.arguments[index + 1]) }
            return true
        }
        if let index = CommandLine.arguments.firstIndex(of: "--polish"), index + 1 < CommandLine.arguments.count {
            let text = CommandLine.arguments[index + 1]
            Task { @MainActor in
                PolishService.refresh()
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                let start = Date()
                do {
                    let result = try await PolishService.current().polish(text)
                    print(String(format: "polished in %.1fs:\n%@", Date().timeIntervalSince(start), result))
                } catch {
                    print("polish failed (available=\(PolishService.isAvailable)): \(error.localizedDescription)")
                }
                exit(0)
            }
            return true
        }
        if CommandLine.arguments.contains("--align-test") {
            MainActor.assumeIsolated { Diagnostics.alignTest() }
            return true
        }
        if CommandLine.arguments.contains("--demo-overlay") {
            MainActor.assumeIsolated { Diagnostics.demoOverlay() }
            return true
        }
        if let index = CommandLine.arguments.firstIndex(of: "--open-settings") {
            let name = index + 1 < CommandLine.arguments.count ? CommandLine.arguments[index + 1] : ""
            MainActor.assumeIsolated {
                DictationController.shared.activate()
                showSettings(tab: SettingsTab.allCases.first { $0.title.lowercased() == name.lowercased() } ?? .general)
            }
            return true
        }
        return false
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Developer commands never remapped Caps Lock, so there's nothing to restore.
        let developerArgs = ["--transcribe", "--probe-focus", "--polish", "--align-test", "--demo-overlay"]
        guard !(Self.developerMode && developerArgs.contains(where: CommandLine.arguments.contains)) else { return }
        MainActor.assumeIsolated {
            DictationController.shared.deactivate()
        }
    }

    @MainActor
    func showSettings(tab: SettingsTab = .general) {
        if settingsController == nil { settingsController = SettingsWindowController() }
        settingsController?.show(tab: tab)
    }

    @MainActor
    func showOnboarding() {
        if onboardingWindow == nil {
            let view = OnboardingView(onFinish: { [weak self] in
                Preferences.shared.hasCompletedOnboarding = true
                self?.onboardingWindow?.close()
            })
            .environmentObject(Preferences.shared)
            .environmentObject(ModelStore.shared)
            .environmentObject(Permissions.shared)

            let window = NSWindow(contentViewController: NSHostingController(rootView: view))
            window.styleMask = [.titled, .closable, .fullSizeContentView]
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.isMovableByWindowBackground = true
            window.isReleasedWhenClosed = false
            window.title = "Welcome to Hushhh"
            window.center()
            onboardingWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        onboardingWindow?.makeKeyAndOrderFront(nil)
    }
}
