import Foundation

/// Asks the local tmux server where each attached client's cursor is (see `TmuxClients`).
///
/// Asked at most once per dictation session, and only when a terminal shows no caret of
/// its own: a single `stat` of the server socket first, so no process starts when tmux
/// isn't running, then `tmux list-clients` with a 300 ms limit.
enum TmuxQuery {
    private static let candidates = ["/opt/homebrew/bin/tmux", "/usr/local/bin/tmux", "/usr/bin/tmux"]
    private static let timeout: TimeInterval = 0.3

    /// This session's `list-clients` output; `.some(nil)` once asked and unavailable.
    private static var cache: String??

    /// Call when a dictation session starts.
    static func beginSession() { cache = nil }

    /// `list-clients` output for the default server, or nil when tmux isn't running or
    /// doesn't answer in time.
    static func listClients() -> String? {
        if let cached = cache { return cached }
        let output = query()
        cache = .some(output)
        return output
    }

    /// Whether `pid` runs inside the app `appPID`: one of its descendants.
    static func isDescendant(_ pid: Int32, of appPID: pid_t) -> Bool {
        var current = pid
        for _ in 0..<32 {
            guard current > 1 else { return false }
            if current == appPID { return true }
            var info = kinfo_proc()
            var size = MemoryLayout<kinfo_proc>.stride
            var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, current]
            guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return false }
            current = info.kp_eproc.e_ppid
        }
        return false
    }

    private static func query() -> String? {
        let socket = TmuxClients.socketPath(tmpdir: ProcessInfo.processInfo.environment["TMUX_TMPDIR"], uid: getuid())
        var info = stat()
        guard stat(socket, &info) == 0, (info.st_mode & S_IFMT) == S_IFSOCK,
              let binary = candidates.first(where: FileManager.default.isExecutableFile) else { return nil }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = ["-S", socket, "list-clients", "-F", TmuxClients.format]
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        let done = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in done.signal() }
        do { try process.run() } catch { return nil }
        // Read while it runs so a long answer can't fill the pipe and stall it.
        var data = Data()
        let reader = DispatchWorkItem { data = out.fileHandleForReading.readDataToEndOfFile() }
        DispatchQueue.global(qos: .userInitiated).async(execute: reader)
        guard done.wait(timeout: .now() + timeout) == .success else {
            process.terminate()
            return nil
        }
        guard reader.wait(timeout: .now() + 0.05) == .success, process.terminationStatus == 0 else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
