import SwiftUI

/// First-run setup: what Hushhh does, permissions, and a model download.
struct OnboardingView: View {
    @EnvironmentObject private var prefs: Preferences
    @EnvironmentObject private var models: ModelStore
    @EnvironmentObject private var permissions: Permissions
    let onFinish: () -> Void

    enum Step: Int, CaseIterable { case welcome, permissions, model, done }
    @State private var step: Step = .welcome

    var body: some View {
        VStack(spacing: 0) {
            Group {
                switch step {
                case .welcome: welcome
                case .permissions: permissionsStep
                case .model: modelStep
                case .done: done
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.horizontal, 40)
            .padding(.top, 36)

            Divider()
            footer
                .padding(.horizontal, 20)
                .padding(.vertical, 14)
        }
        .frame(width: 560, height: 480)
        // The transparent titlebar would otherwise push the content down and clip the footer.
        .ignoresSafeArea(.container, edges: .top)
    }

    // MARK: Steps

    private var welcome: some View {
        VStack(spacing: 16) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 96, height: 96)
                .accessibilityHidden(true)
            Text("Welcome to Hushhh")
                .font(.largeTitle.weight(.semibold))
            Text("Dictate into any app. Press Caps Lock and speak, and your words appear in the field as you talk. Press Caps Lock again when you’re done.")
                .font(.title3)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 24) {
                Feature(symbol: "lock.shield", title: "Private", detail: "Runs on this Mac")
                Feature(symbol: "bolt", title: "Live", detail: "Text fills in as you talk")
                Feature(symbol: "keyboard", title: "Anywhere", detail: "Works in any text field")
            }
            .padding(.top, 8)
            Spacer(minLength: 0)
        }
    }

    private var permissionsStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            StepHeader(title: "Allow Access",
                       subtitle: "Hushhh needs two permissions. Audio is processed only on this Mac and is never saved.")
            VStack(spacing: 0) {
                PermissionRow(symbol: "mic.fill", title: "Microphone",
                              detail: "To hear you while you dictate.",
                              status: permissions.microphone, action: permissions.requestMicrophone, tiled: true)
                    .padding(12)
                Divider().padding(.leading, 52)
                PermissionRow(symbol: "accessibility", title: "Accessibility",
                              detail: "To detect Caps Lock, find the text cursor and insert text.",
                              status: permissions.accessibility, action: permissions.requestAccessibility, tiled: true)
                    .padding(12)
            }
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.background.secondary))
            if permissions.accessibility != .granted {
                Text("In System Settings, turn on Hushhh under Privacy & Security › Accessibility. This window updates automatically.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
    }

    private var modelStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            StepHeader(title: "Choose a Speech Engine",
                       subtitle: "Both run entirely on your Mac. You can switch at any time in Settings.")
            EngineCard(kind: .qvac, detail: "\(ModelStore.qvacSizeLabel) · 8 languages", badge: "Recommended",
                       isSelected: prefs.engine == .qvac, status: models.status(.qvac)) {
                prefs.engine = .qvac
            } onDownload: {
                prefs.engine = .qvac
                models.download(.qvac)
            }
            EngineCard(kind: .whisper, detail: "\(prefs.whisperModel.title) · \(prefs.whisperModel.sizeLabel)", badge: nil,
                       isSelected: prefs.engine == .whisper, status: models.status(.whisper(prefs.whisperModel))) {
                prefs.engine = .whisper
            } onDownload: {
                prefs.engine = .whisper
                models.download(.whisper(prefs.whisperModel))
            }
            Spacer(minLength: 0)
        }
    }

    private var done: some View {
        VStack(spacing: 18) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 56))
                .foregroundStyle(.green)
                .accessibilityHidden(true)
            Text("You’re All Set")
                .font(.largeTitle.weight(.semibold))
            VStack(alignment: .leading, spacing: 12) {
                Instruction(key: .text("⇪"), text: "Click into any text field and press Caps Lock to start.")
                Instruction(key: .symbol("waveform"), text: "Speak naturally. Your words fill in as grey text, then settle into the field.")
                Instruction(key: .text("⇪"), text: "Press Caps Lock again when you’re done.")
                Instruction(key: .text("esc"), text: "Press Esc to cancel and remove what was typed.")
                Instruction(key: .text("tab"), text: "Optionally, turn on Polish in Settings and press Tab to have a language model tidy up the text.")
            }
            .padding(.top, 4)
            Text("Hushhh lives in the menu bar. While it’s running, Caps Lock is used for dictation.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }

    // MARK: Footer

    private var footer: some View {
        HStack {
            HStack(spacing: 6) {
                ForEach(Step.allCases, id: \.self) { s in
                    Circle()
                        .fill(s == step ? Color.accentColor : Color.secondary.opacity(0.35))
                        .frame(width: 6, height: 6)
                }
            }
            .accessibilityElement()
            .accessibilityLabel("Step \(step.rawValue + 1) of \(Step.allCases.count)")
            Spacer()
            if step == .model && !canContinue {
                Text("Download a model to continue")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            if step != .welcome && step != .done {
                Button("Back") { move(-1) }
            }
            if (step == .permissions && !permissions.allGranted) || (step == .model && !canContinue) {
                Button("Skip for Now") { move(1) }
            }
            Button(primaryTitle) {
                if step == .done { onFinish() } else { move(1) }
            }
            .keyboardShortcut(.defaultAction)
            .disabled(!canContinue)
        }
        .controlSize(.large)
    }

    private var primaryTitle: String {
        switch step {
        case .welcome: "Get Started"
        case .done: "Done"
        default: "Continue"
        }
    }

    private var canContinue: Bool {
        switch step {
        case .permissions: permissions.allGranted
        case .model: models.isInstalled(prefs.engine == .qvac ? .qvac : .whisper(prefs.whisperModel))
        default: true
        }
    }

    private func move(_ delta: Int) {
        guard let next = Step(rawValue: step.rawValue + delta) else { return }
        withAnimation(.easeInOut(duration: 0.2)) { step = next }
    }
}

// MARK: - Pieces

private struct StepHeader: View {
    let title: String
    let subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.title.weight(.semibold))
            Text(subtitle).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct Feature: View {
    let symbol: String
    let title: String
    let detail: String

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: symbol)
                .font(.system(size: 22))
                .foregroundStyle(Color.accentColor)
                .frame(height: 26)
            Text(title).font(.headline)
            Text(detail).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .frame(width: 130)
        .accessibilityElement(children: .combine)
    }
}

private struct Instruction: View {
    enum Key {
        case text(String)
        case symbol(String)
    }

    let key: Key
    let text: String

    var body: some View {
        HStack(spacing: 12) {
            Group {
                switch key {
                case .text(let label): Text(label).font(.system(size: 14, weight: .semibold, design: .rounded))
                case .symbol(let name): Image(systemName: name).font(.system(size: 14, weight: .semibold))
                }
            }
            .padding(.horizontal, 6)
            .frame(minWidth: 36, minHeight: 28)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(.quaternary))
            .accessibilityHidden(true)
            Text(text)
        }
        .accessibilityElement(children: .combine)
    }
}

private struct EngineCard: View {
    let kind: EngineKind
    let detail: String
    let badge: String?
    let isSelected: Bool
    let status: ModelStatus
    let onSelect: () -> Void
    let onDownload: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            // The card itself selects the engine; the trailing control downloads it.
            Button(action: onSelect) {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 18))
                        .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                    VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(kind.title).font(.headline)
                    if let badge {
                        Text(badge)
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Capsule().fill(Color.accentColor.opacity(0.15)))
                            .foregroundStyle(Color.accentColor)
                    }
                }
                Text(kind.summary).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Text(detail).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 8)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(isSelected ? [.isSelected] : [])
            .accessibilityHint("Selects \(kind.title) as the speech engine")
            trailing.frame(minWidth: 96, alignment: .trailing)
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.background.secondary))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .strokeBorder(isSelected ? Color.accentColor : Color.clear, lineWidth: 1.5))
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private var trailing: some View {
        switch status {
        case .installed:
            Label("Ready", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
        case .downloading(let fraction):
            VStack(alignment: .trailing, spacing: 4) {
                ProgressView(value: fraction).frame(width: 96)
                Text("\(Int(fraction * 100))%").font(.caption).monospacedDigit().foregroundStyle(.secondary)
            }
        case .notInstalled:
            Button("Download", action: onDownload)
        case .failed:
            Button("Try Again", action: onDownload)
        }
    }
}
