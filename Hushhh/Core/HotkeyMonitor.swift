import AppKit
import Carbon.HIToolbox

/// Remaps Caps Lock to F18 for this login session so pressing it never toggles
/// the caps state, then restores the person's original key mapping on quit,
/// including when the app is terminated by a signal.
///
/// If Hushhh is force-quit (SIGKILL) the remap stays until logout or the next
/// launch. To undo it by hand: `hidutil property --set '{"UserKeyMapping":[]}'`.
enum CapsLockRemapper {
    private static let capsLock: UInt64 = 0x7_0000_0039
    private static let f18: UInt64 = 0x7_0000_006D
    private static let src = "HIDKeyboardModifierMappingSrc"
    private static let dst = "HIDKeyboardModifierMappingDst"
    private static let savedKey = "originalUserKeyMapping"

    /// True while our Caps Lock → F18 mapping is applied.
    private(set) static var isActive = false
    private static var signalSources: [DispatchSourceSignal] = []

    /// Applies the remap. Returns false, leaving the keyboard untouched, if the
    /// current mapping can't be read or Caps Lock is already remapped by something else.
    @discardableResult
    static func enable() -> Bool {
        guard !isActive else { return true }
        guard let current = currentMappings() else {
            NSLog("[Hushhh] Couldn’t read the current key mapping; leaving Caps Lock alone.")
            return false
        }
        let defaults = UserDefaults.standard
        let leftover = current.contains(where: isOurs)
        // A leftover entry means a previous run didn't get to restore: use what it saved.
        let original = leftover
            ? (defaults.array(forKey: savedKey) as? [[String: UInt64]] ?? current.filter { !isOurs($0) })
            : current
        if !leftover, original.contains(where: { $0[src] == capsLock }) {
            // Karabiner, System Settings or another tool already owns Caps Lock.
            NSLog("[Hushhh] Caps Lock is already remapped; not changing it.")
            return false
        }
        defaults.set(original, forKey: savedKey)
        guard apply(original.filter { $0[src] != capsLock } + [[src: capsLock, dst: f18]]) else {
            NSLog("[Hushhh] Couldn’t apply the Caps Lock remap.")
            return false
        }
        isActive = true
        installSignalHandlers()
        return true
    }

    static func disable() {
        guard isActive else { return }
        let defaults = UserDefaults.standard
        let original = defaults.array(forKey: savedKey) as? [[String: UInt64]] ?? []
        if apply(original) {
            defaults.removeObject(forKey: savedKey)
            isActive = false
        }
    }

    private static func isOurs(_ entry: [String: UInt64]) -> Bool {
        entry[src] == capsLock && entry[dst] == f18
    }

    /// Restore the mapping when the app is asked to stop (Terminal Ctrl-C, `kill`,
    /// logout), not only on a normal quit.
    private static func installSignalHandlers() {
        guard signalSources.isEmpty else { return }
        for sig in [SIGTERM, SIGINT, SIGHUP] {
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            source.setEventHandler {
                disable()
                exit(0)
            }
            source.resume()
            signalSources.append(source)
        }
    }

    /// The current mappings, or nil if they can't be read reliably.
    private static func currentMappings() -> [[String: UInt64]]? {
        guard let result = run(["property", "--get", "UserKeyMapping"]), result.status == 0 else { return nil }
        let output = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
        // No mappings prints "(null)" or an empty list "( )".
        if output == "(null)" || output.replacingOccurrences(of: " ", with: "").replacingOccurrences(of: "\n", with: "") == "()" {
            return []
        }
        // Otherwise an old-style plist: ( { HIDKeyboardModifierMappingDst = 1; HIDKeyboardModifierMappingSrc = 2; } )
        var entries: [[String: UInt64]] = []
        let blocks = output.components(separatedBy: "}").filter { $0.contains("HIDKeyboardModifierMapping") }
        for block in blocks {
            var entry: [String: UInt64] = [:]
            for key in [src, dst] {
                if let range = block.range(of: #"\#(key) = (\d+);"#, options: .regularExpression) {
                    entry[key] = UInt64(block[range].filter(\.isNumber))
                }
            }
            // Anything we can't parse (e.g. extra fields) means we can't safely restore it.
            guard entry.count == 2 else { return nil }
            entries.append(entry)
        }
        return entries
    }

    private static func apply(_ mappings: [[String: UInt64]]) -> Bool {
        let items = mappings.map {
            String(format: #"{"HIDKeyboardModifierMappingSrc":0x%llX,"HIDKeyboardModifierMappingDst":0x%llX}"#,
                   $0[src] ?? 0, $0[dst] ?? 0)
        }
        return run(["property", "--set", #"{"UserKeyMapping":[\#(items.joined(separator: ","))]}"#])?.status == 0
    }

    private static func run(_ arguments: [String]) -> (status: Int32, output: String)? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/hidutil")
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
        } catch {
            NSLog("[Hushhh] hidutil failed: \(error)")
            return nil
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(data: data, encoding: .utf8) ?? "")
    }
}

/// Watches the keyboard through a session event tap. Requires Accessibility.
final class HotkeyMonitor {
    var onTriggerDown: (() -> Void)?
    var onTriggerUp: (() -> Void)?
    /// Return true to swallow the Escape key (only while dictating).
    var onEscape: (() -> Bool)?
    /// Return true to swallow the Tab key (polish, only while dictating).
    var onTab: (() -> Bool)?
    private var swallowingTab = false

    private var tap: CFMachPort?
    private var source: CFRunLoopSource?

    var isRunning: Bool { tap != nil }

    @discardableResult
    func start() -> Bool {
        guard tap == nil else { return true }
        let mask = (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.keyUp.rawValue) | (1 << CGEventType.flagsChanged.rawValue)
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap,
                                          place: .headInsertEventTap,
                                          options: .defaultTap,
                                          eventsOfInterest: CGEventMask(mask),
                                          callback: hotkeyTapCallback,
                                          userInfo: refcon) else { return false }
        self.tap = tap
        source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        return true
    }

    func stop() {
        swallowingTab = false
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        tap = nil
        source = nil
    }

    fileprivate func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        let keyCode = Int(event.getIntegerValueField(.keyboardEventKeycode))
        let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0

        switch (type, keyCode) {
        // Handlers run after the callback returns: a slow handler inside an
        // event tap freezes keyboard input and gets the tap disabled.
        // F18 is only ours while Caps Lock is remapped to it; a real F18 key passes through.
        case (.keyDown, kVK_F18) where CapsLockRemapper.isActive:
            if !isRepeat { DispatchQueue.main.async { self.onTriggerDown?() } }
            return nil
        case (.keyUp, kVK_F18) where CapsLockRemapper.isActive:
            DispatchQueue.main.async { self.onTriggerUp?() }
            return nil
        case (.flagsChanged, kVK_CapsLock):
            // Fallback when the remap isn't active: treat each toggle as a tap.
            DispatchQueue.main.async {
                self.onTriggerDown?()
                self.onTriggerUp?()
            }
            return Unmanaged.passUnretained(event)
        case (.keyDown, kVK_Escape):
            if onEscape?() == true { return nil }
        case (.keyUp, kVK_Escape):
            break
        case (.keyDown, kVK_Tab):
            if !isRepeat, event.flags.intersection([.maskCommand, .maskAlternate, .maskControl, .maskShift]).isEmpty,
               onTab?() == true {
                swallowingTab = true
                return nil
            }
            // Holding Tab repeats; only swallow repeats of a press we took. A fresh press
            // that we didn't take clears any state left from a missed key-up.
            if isRepeat && swallowingTab { return nil }
            swallowingTab = false
        case (.keyUp, kVK_Tab):
            if swallowingTab {
                swallowingTab = false
                return nil
            }
        default:
            break
        }
        return Unmanaged.passUnretained(event)
    }
}

private func hotkeyTapCallback(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent, refcon: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    guard let refcon else { return Unmanaged.passUnretained(event) }
    let monitor = Unmanaged<HotkeyMonitor>.fromOpaque(refcon).takeUnretainedValue()
    return monitor.handle(type: type, event: event)
}
