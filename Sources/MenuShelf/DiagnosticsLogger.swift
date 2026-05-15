import Foundation
import AppKit

final class DiagnosticsLogger {
    static let shared = DiagnosticsLogger()

    let logURL: URL
    private let sessionMarkerURL: URL
    private let formatter: ISO8601DateFormatter
    private let queue = DispatchQueue(label: "com.menushelf.diagnostics", qos: .utility)
    private var isEnabled = false
    private var hasRegisteredHandlers = false
    private let sessionID = UUID().uuidString.prefix(8).description

    private init() {
        let supportURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first!
            .appendingPathComponent("MenuShelf", isDirectory: true)

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

    func beginSession(settings: AppSettings) {
        guard isEnabled else { return }
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
        guard isEnabled else { return }
        log("=== SESSION END \(sessionID) ===")
        // Remove clean-session marker so next launch knows we shut down cleanly
        try? FileManager.default.removeItem(at: sessionMarkerURL)
    }

    func log(_ message: String) {
        guard isEnabled else { return }
        let line = "[\(formatter.string(from: Date()))] \(message)\n"
        queue.async { [weak self] in
            _ = self?.writeLine(line)
        }
    }

    func logSync(_ message: String) {
        guard isEnabled else { return }
        let line = "[\(formatter.string(from: Date()))] \(message)\n"
        _ = writeLine(line)
    }

    func logCrash(signal: Int32, description: String) {
        // Always attempt to write crash info even if diagnostics aren't fully enabled
        let line = "[\(formatter.string(from: Date()))] 💥 CRASH DETECTED — Signal \(signal) (\(description)) — Session \(sessionID)\n"
        _ = writeLine(line)
        // Try to capture backtrace
        let symbols = Thread.callStackSymbols.prefix(20).joined(separator: "\n")
        _ = writeLine("[\(formatter.string(from: Date()))] Backtrace (top 20):\n\(symbols)\n")
        // Clean up marker so next launch knows it crashed
        try? FileManager.default.removeItem(at: sessionMarkerURL)
    }

    func clear() {
        queue.async { [weak self] in
            guard let self else { return }
            try? FileManager.default.removeItem(at: logURL)
        }
    }

    private func writeLine(_ line: String) -> Bool {
        guard let data = line.data(using: .utf8) else { return false }
        if FileManager.default.fileExists(atPath: logURL.path),
           let handle = try? FileHandle(forWritingTo: logURL) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
            return true
        } else {
            try? data.write(to: logURL, options: [.atomic])
            return true
        }
    }

    private func registerCrashHandlers() {
        guard !hasRegisteredHandlers else { return }
        hasRegisteredHandlers = true

        let signals: [Int32] = [SIGABRT, SIGILL, SIGSEGV, SIGBUS, SIGTRAP, SIGFPE, SIGTERM]
        for sig in signals {
            signal(sig) { sigNum in
                let name: String
                switch sigNum {
                case SIGABRT: name = "SIGABRT"
                case SIGILL: name = "SIGILL"
                case SIGSEGV: name = "SIGSEGV"
                case SIGBUS: name = "SIGBUS"
                case SIGTRAP: name = "SIGTRAP"
                case SIGFPE: name = "SIGFPE"
                case SIGTERM: name = "SIGTERM"
                default: name = "UNKNOWN(\(sigNum))"
                }
                DiagnosticsLogger.shared.logCrash(signal: sigNum, description: name)
                // Re-raise with default handler so the system still generates a crash report
                signal(sigNum, SIG_DFL)
                raise(sigNum)
            }
        }

        NSSetUncaughtExceptionHandler { exception in
            DiagnosticsLogger.shared.logCrash(
                signal: 0,
                description: "Uncaught NSException: \(exception.name.rawValue) — \(exception.reason ?? "no reason")"
            )
        }
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
