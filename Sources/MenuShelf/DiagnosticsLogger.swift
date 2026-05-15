import Foundation
import AppKit
import Darwin

final class DiagnosticsLogger {
    static let shared = DiagnosticsLogger()

    let logURL: URL
    private let sessionMarkerURL: URL
    private let formatter: ISO8601DateFormatter
    private let queue = DispatchQueue(label: "com.menushelf.diagnostics", qos: .utility)
    private var isEnabled = false
    private var hasRegisteredHandlers = false
    private let sessionID = UUID().uuidString.prefix(8).description

    /// Pre-opened file descriptor for use from signal handlers.
    /// `write(2)` is async-signal-safe; `FileHandle`/`FileManager` are not.
    private var crashLogFD: Int32 = -1

    /// Long-lived handle reused across `writeLine(_:)` calls so we don't pay
    /// the open/seek/close cost on every diagnostic line (which can be many
    /// per menu interaction when verbose diagnostics is on). All access goes
    /// through `queue` so it's safe to mutate without additional locking.
    private var writeHandle: FileHandle?

    private init() {
        let resolvedSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        let supportURL = resolvedSupport.appendingPathComponent("MenuShelf", isDirectory: true)

        try? FileManager.default.createDirectory(at: supportURL, withIntermediateDirectories: true)
        logURL = supportURL.appendingPathComponent("diagnostics.log")
        sessionMarkerURL = supportURL.appendingPathComponent(".last_session_clean")

        formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        // Check if previous session crashed (no clean marker)
        let previousCrashed = !FileManager.default.fileExists(atPath: sessionMarkerURL.path)
        if previousCrashed {
            // Write retroactive crash notice before we overwrite the marker
            _ = self.writeLine("[\(formatter.string(from: Date()))] ⚠️ PREVIOUS SESSION UNCLEAN — app crashed or was force-quit (no clean-shutdown marker found)\n")
        }

        // Create fresh marker; it will be deleted on graceful termination
        try? Data().write(to: sessionMarkerURL, options: [.atomic])
    }

    func setEnabled(_ enabled: Bool) {
        queue.sync { isEnabled = enabled }
        if enabled {
            log("Verbose diagnostics enabled")
            registerCrashHandlers()
        }
    }

    /// Returns the current enabled state in a thread-safe way.
    private func enabled() -> Bool {
        queue.sync { isEnabled }
    }

    func beginSession(settings: AppSettings) {
        guard enabled() else { return }
        let info = ProcessInfo.processInfo
        log("=== SESSION BEGIN \(sessionID) ===")
        log("App version: \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] ?? "unknown")")
        log("Build: \(Bundle.main.infoDictionary?["CFBundleVersion"] ?? "unknown")")
        log("macOS: \(info.operatingSystemVersionString)")
        log("Device: \(info.machineHardwareName)")
        log("ProcessID: \(info.processIdentifier)")
        log("Settings schema: \(settings.schemaVersion)")
        log("MenuViews: \(settings.resolvedMenuViews.count), Folders: \(settings.folders.count)")
        log("Bundle path: \(Bundle.main.bundlePath)")
        log("Log file: \(logURL.path)")
    }

    func endSession() {
        guard enabled() else { return }
        log("=== SESSION END \(sessionID) ===")
        // Drain any pending async writes, then close the long-lived handle so
        // it doesn't survive into the next process if the logger is reused.
        queue.sync {
            try? writeHandle?.close()
            writeHandle = nil
        }
        // Remove clean-session marker so next launch knows we shut down cleanly
        try? FileManager.default.removeItem(at: sessionMarkerURL)
    }

    func log(_ message: String) {
        guard enabled() else { return }
        let line = "[\(formatter.string(from: Date()))] \(message)\n"
        queue.async { [weak self] in
            _ = self?.writeLine(line)
        }
    }

    func logSync(_ message: String) {
        guard enabled() else { return }
        let line = "[\(formatter.string(from: Date()))] \(message)\n"
        _ = writeLine(line)
    }

    func logCrash(signal: Int32, description: String) {
        // Non-signal context (e.g., NSException handler). Safe to use Foundation.
        let line = "[\(formatter.string(from: Date()))] 💥 CRASH — Signal \(signal) (\(description)) — Session \(sessionID)\n"
        _ = writeLine(line)
    }

    /// Async-signal-safe crash logger taking a compile-time StaticString.
    fileprivate func logCrashStatic(signal: Int32, name: StaticString) {
        name.withUTF8Buffer { utf8 in
            crashLogWriteSignalSafeBytes(signal: signal, bytes: utf8.baseAddress, count: utf8.count)
        }
    }

    func clear() {
        queue.async { [weak self] in
            guard let self else { return }
            try? self.writeHandle?.close()
            self.writeHandle = nil
            try? FileManager.default.removeItem(at: logURL)
        }
    }

    private func writeLine(_ line: String) -> Bool {
        guard let data = line.data(using: .utf8) else { return false }

        // Lazily open and reuse one handle. If the file is missing (first run, or
        // user deleted it externally), create it and re-open. Failures fall back
        // to a one-shot atomic write so a single bad write never silently drops
        // logs forever.
        if writeHandle == nil {
            if !FileManager.default.fileExists(atPath: logURL.path) {
                try? Data().write(to: logURL, options: [.atomic])
            }
            writeHandle = try? FileHandle(forWritingTo: logURL)
            _ = try? writeHandle?.seekToEnd()
        }

        if let handle = writeHandle {
            do {
                try handle.write(contentsOf: data)
                return true
            } catch {
                // Re-acquire on next write; the file may have been rotated or
                // deleted. Fall through to the atomic-write fallback below.
                try? handle.close()
                writeHandle = nil
            }
        }

        try? data.write(to: logURL, options: [.atomic])
        return true
    }

    private func registerCrashHandlers() {
        guard !hasRegisteredHandlers else { return }
        hasRegisteredHandlers = true

        // Pre-open the log fd so the signal handler can write without calling
        // any non-async-signal-safe APIs.
        if crashLogFD < 0 {
            let path = logURL.path
            // O_WRONLY | O_CREAT | O_APPEND, mode 0644
            crashLogFD = path.withCString { open($0, O_WRONLY | O_CREAT | O_APPEND, 0o644) }
        }

        let signals: [Int32] = [SIGABRT, SIGILL, SIGSEGV, SIGBUS, SIGTRAP, SIGFPE, SIGTERM]
        for sig in signals {
            signal(sig) { sigNum in
                let name: StaticString
                switch sigNum {
                case SIGABRT: name = "SIGABRT"
                case SIGILL:  name = "SIGILL"
                case SIGSEGV: name = "SIGSEGV"
                case SIGBUS:  name = "SIGBUS"
                case SIGTRAP: name = "SIGTRAP"
                case SIGFPE:  name = "SIGFPE"
                case SIGTERM: name = "SIGTERM"
                default:      name = "UNKNOWN"
                }
                DiagnosticsLogger.shared.logCrashStatic(signal: sigNum, name: name)
                // Re-raise with default handler so the system still generates a crash report.
                signal(sigNum, SIG_DFL)
                raise(sigNum)
            }
        }

        NSSetUncaughtExceptionHandler { exception in
            // NSException handlers run on a normal thread, not in a signal context,
            // so it's safe to use full Foundation here.
            let line = "💥 Uncaught NSException: \(exception.name.rawValue) — \(exception.reason ?? "no reason")\n"
            _ = DiagnosticsLogger.shared.writeLine(line)
        }
    }

    /// Async-signal-safe writer. Uses only `write(2)` to a pre-opened fd —
    /// no malloc, no locks, no Foundation. Bytes can be a non-NUL-terminated buffer.
    private func crashLogWriteSignalSafeBytes(signal: Int32, bytes: UnsafePointer<UInt8>?, count: Int) {
        let fd = crashLogFD
        guard fd >= 0 else { return }

        // Stack-allocated fixed buffer; no heap allocations.
        var stack = (UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0),
                     UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0),
                     UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0),
                     UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0),
                     UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0),
                     UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0),
                     UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0),
                     UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0),
                     UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0),
                     UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0),
                     UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0),
                     UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0))
        let capacity = 96

        let written: Int = withUnsafeMutablePointer(to: &stack) { tuplePtr -> Int in
            tuplePtr.withMemoryRebound(to: UInt8.self, capacity: capacity) { rawPtr -> Int in
                let ptr = UnsafeMutableBufferPointer(start: rawPtr, count: capacity)
                var i = 0
                // Prefix: "\n[CRASH sig="
                let prefix: StaticString = "\n[CRASH sig="
                prefix.withUTF8Buffer { utf8 in
                    var j = 0
                    while j < utf8.count && i < ptr.count {
                        ptr[i] = utf8[j]; i += 1; j += 1
                    }
                }
                i += writeInt(Int(signal), into: ptr, offset: i)
                if i < ptr.count { ptr[i] = UInt8(ascii: " "); i += 1 }
                if let bytes {
                    var j = 0
                    while j < count && i < ptr.count - 1 {
                        ptr[i] = bytes[j]; i += 1; j += 1
                    }
                }
                if i < ptr.count { ptr[i] = UInt8(ascii: "\n"); i += 1 }
                _ = write(fd, rawPtr, i)
                return i
            }
        }
        _ = written
    }

    /// Write a base-10 integer into `buf` starting at `offset`. Returns bytes written.
    /// Stack-only — safe to call from a signal handler.
    private func writeInt(_ value: Int, into buf: UnsafeMutableBufferPointer<UInt8>, offset: Int) -> Int {
        var n = value
        var negative = false
        if n < 0 { negative = true; n = -n }
        // 20 digits is enough for Int64.
        var d0: UInt8 = 0, d1: UInt8 = 0, d2: UInt8 = 0, d3: UInt8 = 0, d4: UInt8 = 0
        var d5: UInt8 = 0, d6: UInt8 = 0, d7: UInt8 = 0, d8: UInt8 = 0, d9: UInt8 = 0
        var d10: UInt8 = 0, d11: UInt8 = 0, d12: UInt8 = 0, d13: UInt8 = 0, d14: UInt8 = 0
        var d15: UInt8 = 0, d16: UInt8 = 0, d17: UInt8 = 0, d18: UInt8 = 0, d19: UInt8 = 0
        var count = 0
        if n == 0 {
            d0 = UInt8(ascii: "0"); count = 1
        } else {
            while n > 0 && count < 20 {
                let digit = UInt8(ascii: "0") + UInt8(n % 10)
                switch count {
                case 0: d0 = digit
                case 1: d1 = digit
                case 2: d2 = digit
                case 3: d3 = digit
                case 4: d4 = digit
                case 5: d5 = digit
                case 6: d6 = digit
                case 7: d7 = digit
                case 8: d8 = digit
                case 9: d9 = digit
                case 10: d10 = digit
                case 11: d11 = digit
                case 12: d12 = digit
                case 13: d13 = digit
                case 14: d14 = digit
                case 15: d15 = digit
                case 16: d16 = digit
                case 17: d17 = digit
                case 18: d18 = digit
                default: d19 = digit
                }
                n /= 10
                count += 1
            }
        }
        var written = 0
        if negative, offset + written < buf.count {
            buf[offset + written] = UInt8(ascii: "-")
            written += 1
        }
        for k in stride(from: count - 1, through: 0, by: -1) where offset + written < buf.count {
            let byte: UInt8
            switch k {
            case 0: byte = d0
            case 1: byte = d1
            case 2: byte = d2
            case 3: byte = d3
            case 4: byte = d4
            case 5: byte = d5
            case 6: byte = d6
            case 7: byte = d7
            case 8: byte = d8
            case 9: byte = d9
            case 10: byte = d10
            case 11: byte = d11
            case 12: byte = d12
            case 13: byte = d13
            case 14: byte = d14
            case 15: byte = d15
            case 16: byte = d16
            case 17: byte = d17
            case 18: byte = d18
            default: byte = d19
            }
            buf[offset + written] = byte
            written += 1
        }
        return written
    }
}

private extension ProcessInfo {
    var machineHardwareName: String {
        var sysinfo = utsname()
        uname(&sysinfo)
        return withUnsafePointer(to: &sysinfo.machine) { ptr in
            ptr.withMemoryRebound(to: CChar.self, capacity: 1) { charPtr in
                String(cString: charPtr)
            }
        }
    }
}
