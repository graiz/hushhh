import AppKit
import AVFoundation
import ApplicationServices

/// Tracks the two permissions Hushhh needs: the microphone, and Accessibility
/// (to detect Caps Lock, find the text cursor and insert text).
@MainActor
final class Permissions: ObservableObject {
    static let shared = Permissions()

    enum Status { case granted, denied, notDetermined }

    @Published private(set) var microphone: Status = .notDetermined
    @Published private(set) var accessibility: Status = .notDetermined

    var allGranted: Bool { microphone == .granted && accessibility == .granted }

    private var timer: Timer?

    private init() {
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    func refresh() {
        let mic: Status = switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: .granted
        case .notDetermined: .notDetermined
        default: .denied
        }
        if mic != microphone { microphone = mic }
        let ax: Status = AXIsProcessTrusted() ? .granted : .denied
        if ax != accessibility { accessibility = ax }
    }

    func requestMicrophone() {
        switch microphone {
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { _ in
                Task { @MainActor in self.refresh() }
            }
        default:
            openPrivacyPane("Privacy_Microphone")
        }
    }

    func requestAccessibility() {
        // Shows the system prompt the first time; afterwards it's a no-op, so
        // also take the person straight to the right pane.
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        if !AXIsProcessTrustedWithOptions(options) {
            openPrivacyPane("Privacy_Accessibility")
        }
    }

    func openPrivacyPane(_ anchor: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") {
            NSWorkspace.shared.open(url)
        }
    }
}
