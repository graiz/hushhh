import CoreAudio
import Foundation

/// Listens on one microphone, or on several at the start of a dictation, keeping the one
/// that hears the person best (see `MicrophoneChoice`). Every microphone's audio is kept
/// until the choice is made, so nothing said in the meantime is lost.
final class MicrophoneGroup {
    /// Called on an audio thread, in order, with the chosen microphone's audio from its start.
    var onSamples: (([Float]) -> Void)?
    /// RMS level, 0…1, called on an audio thread: the loudest microphone until one is chosen.
    var onLevel: ((Float) -> Void)?
    /// Called once on an audio thread when one of several microphones is chosen, with
    /// the microphones that were listening.
    var onChoice: ((MicrophoneChoice.Choice, [AudioDeviceID?]) -> Void)?

    /// Which microphones to listen on, preferred first; nil is the system default input.
    /// Asked in `start`, off the main thread, since Core Audio can block.
    private let resolve: () -> [AudioDeviceID?]
    private var devices: [AudioDeviceID?] = [nil]
    private let lock = NSLock()
    private var recorders: [Int: AudioRecorder] = [:]
    private var meters: [MicrophoneChoice.Meter] = []
    private var buffers: [[Float]] = []
    private var levels: [Float] = []
    private var chosen: Int?
    private var stopped = false

    init(devices: @escaping () -> [AudioDeviceID?]) {
        resolve = devices
    }

    /// Starts the first microphone, and the others in the background (Bluetooth can take
    /// a second). If a lone microphone that isn't the default can't start (it was
    /// unplugged), the default input is used instead.
    func start() throws {
        let resolved = resolve()
        let devices = resolved.isEmpty ? [nil] : resolved
        lock.withLock {
            self.devices = devices
            meters = Array(repeating: MicrophoneChoice.Meter(), count: devices.count)
            buffers = Array(repeating: [], count: devices.count)
            levels = Array(repeating: 0, count: devices.count)
            chosen = devices.count == 1 ? 0 : nil
        }
        var first = recorder(0)
        do {
            try first.start()
        } catch where devices.count == 1 && devices[0] != nil {
            first = AudioRecorder()
            first.onSamples = { [weak self] in self?.received($0, from: 0) }
            first.onLevel = { [weak self] in self?.level($0, from: 0) }
            try first.start()
        }
        lock.withLock { recorders[0] = first }
        guard devices.count > 1 else { return }
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            for index in devices.indices.dropFirst() {
                guard lock.withLock({ !stopped && chosen == nil }) else { return }
                let other = recorder(index)
                guard (try? other.start()) != nil else { continue }
                let keep = lock.withLock {
                    guard !stopped, chosen == nil else { return false }
                    recorders[index] = other
                    return true
                }
                if !keep { other.stop() }
            }
        }
    }

    func stop() {
        let all = lock.withLock {
            stopped = true
            defer { recorders = [:] }
            return Array(recorders.values)
        }
        all.forEach { $0.stop() }
    }

    private func recorder(_ index: Int) -> AudioRecorder {
        let recorder = AudioRecorder(device: devices[index])
        recorder.onSamples = { [weak self] in self?.received($0, from: index) }
        recorder.onLevel = { [weak self] in self?.level($0, from: index) }
        return recorder
    }

    private func received(_ samples: [Float], from index: Int) {
        lock.lock()
        guard !stopped else { lock.unlock(); return }
        if let chosen {
            lock.unlock()
            if chosen == index { onSamples?(samples) }
            return
        }
        meters[index].add(samples)
        buffers[index] += samples
        guard let choice = MicrophoneChoice.choose(meters) else { lock.unlock(); return }
        let pick = choice.index
        chosen = pick
        FocusLog.write("microphone chose \(pick) of \(devices.count) confident=\(choice.isConfident) levels="
            + meters.map { String(format: "%.5f", $0.recentRMS ?? -1) }.joined(separator: ","))
        let heard = buffers[pick]
        buffers = []
        let others = recorders.filter { $0.key != pick }.map(\.value)
        recorders = recorders.filter { $0.key == pick }
        lock.unlock()

        // Later audio from the chosen microphone arrives on this same thread, after this.
        onSamples?(heard)
        onChoice?(choice, devices)
        // Not from inside an audio callback.
        DispatchQueue.global(qos: .utility).async { others.forEach { $0.stop() } }
    }

    private func level(_ level: Float, from index: Int) {
        lock.lock()
        let shown: Float?
        if let chosen {
            shown = chosen == index ? level : nil
        } else {
            levels[index] = level
            shown = levels.max()
        }
        lock.unlock()
        if let shown { onLevel?(shown) }
    }
}

/// The Mac's audio devices, read when a dictation starts.
enum AudioDevices {
    struct Microphone: Equatable {
        var id: AudioDeviceID
        /// Stays the same across restarts, unlike `id`.
        var uid: String
    }

    /// The default input and the other microphones worth listening on, and a key that
    /// changes whenever that set does.
    static func setup() -> (defaultUID: String?, others: [Microphone], key: String) {
        let defaultUID = defaultDevice(kAudioHardwarePropertyDefaultInputDevice).flatMap(uid)
        let others = otherMicrophones().compactMap { id in uid(id).map { Microphone(id: id, uid: $0) } }
        let key = ([defaultUID ?? "-"] + others.map(\.uid).sorted()).joined(separator: "|")
        return (defaultUID, others, key)
    }

    /// Microphones to listen on besides the default input: built-in, wired and USB ones,
    /// plus a Bluetooth headset only while it's playing the Mac's sound (opening its
    /// microphone switches it to call quality). Virtual devices and iPhones are left out.
    private static func otherMicrophones() -> [AudioDeviceID] {
        let defaultInput = defaultDevice(kAudioHardwarePropertyDefaultInputDevice)
        let defaultOutput = defaultDevice(kAudioHardwarePropertyDefaultOutputDevice)
        return allDevices().filter { device in
            guard device != defaultInput, hasInput(device) else { return false }
            switch transportType(device) {
            case kAudioDeviceTransportTypeBuiltIn, kAudioDeviceTransportTypeUSB, kAudioDeviceTransportTypeFireWire,
                 kAudioDeviceTransportTypeThunderbolt, kAudioDeviceTransportTypePCI, kAudioDeviceTransportTypeHDMI,
                 kAudioDeviceTransportTypeDisplayPort:
                return true
            case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE:
                return device == defaultOutput || (uid(device) != nil && uid(device) == defaultOutput.flatMap(uid))
            default:
                return false
            }
        }
    }

    static func name(_ device: AudioDeviceID) -> String? {
        string(device, kAudioObjectPropertyName)
    }

    private static func uid(_ device: AudioDeviceID) -> String? {
        string(device, kAudioDevicePropertyDeviceUID)
    }

    private static func address(_ selector: AudioObjectPropertySelector,
                                scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    private static func defaultDevice(_ selector: AudioObjectPropertySelector) -> AudioDeviceID? {
        var address = address(selector)
        var device = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device) == noErr,
              device != 0 else { return nil }
        return device
    }

    private static func allDevices() -> [AudioDeviceID] {
        var address = address(kAudioHardwarePropertyDevices)
        var size: UInt32 = 0
        let system = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr else { return [] }
        var devices = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &devices) == noErr else { return [] }
        return devices
    }

    private static func hasInput(_ device: AudioDeviceID) -> Bool {
        var address = address(kAudioDevicePropertyStreams, scope: kAudioObjectPropertyScopeInput)
        var size: UInt32 = 0
        return AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size) == noErr && size > 0
    }

    private static func transportType(_ device: AudioDeviceID) -> UInt32 {
        var address = address(kAudioDevicePropertyTransportType)
        var type: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(device, &address, 0, nil, &size, &type) == noErr ? type : 0
    }

    private static func string(_ device: AudioDeviceID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = address(selector)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr else { return nil }
        return value?.takeRetainedValue() as String?
    }
}
