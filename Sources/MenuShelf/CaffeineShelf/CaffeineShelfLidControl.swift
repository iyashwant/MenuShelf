//
//  CaffeineShelfLidControl.swift
//  MenuShelf
//
//  The privileged "keep awake with the lid closed" mechanism. IOKit power
//  assertions cannot override clamshell (lid-close) sleep — the only thing that
//  does is the kernel `SleepDisabled` flag, set via `pmset disablesleep`, which
//  requires root.
//
//  MenuShelf is sandboxed, and the App Sandbox blocks every route to root:
//  `Process` refuses to exec setuid `/usr/bin/sudo` (EPERM), and
//  `do shell script … with administrator privileges` fails instantly with -60005
//  without ever showing a sheet. That is true even after the sudoers grant is
//  installed, so BOTH the one-time setup and every subsequent toggle have to
//  happen outside the sandbox.
//
//  A posix_spawn child inherits our sandbox, but an .app launched through
//  LaunchServices gets the sandbox its own signature asks for. So all privileged
//  work is delegated to the nested, deliberately unsandboxed
//  `Contents/Helpers/MenuShelfLidHelper.app`, launched with NSWorkspace. This
//  file is only the client side of that protocol.
//
//  The two read-only queries stay in-process because the sandbox permits them:
//  `pmset -g` runs fine, and a *targeted* existence check inside /etc/sudoers.d
//  succeeds even though listing the directory does not.
//
//  Every function here blocks while the helper runs, so callers must invoke them
//  off the main thread (e.g. from `Task.detached`). The type is a namespace of
//  static functions with no shared mutable state, so it is safe to call
//  concurrently.
//

import AppKit
import Foundation

enum CaffeineShelfLidControl {
    /// Path of the sudoers drop-in that grants the passwordless toggle. Must stay
    /// identical to `sudoersPath` in the helper.
    static let sudoersPath = "/etc/sudoers.d/menushelf-disablesleep"

    enum ToggleResult: Equatable {
        case ok
        case grantMissing
        case failed(String)
    }

    // MARK: - Toggle

    /// Set the kernel `disablesleep` flag through the helper. Returns
    /// `.grantMissing` when the sudoers grant isn't installed (so the caller can
    /// trigger the one-time install), or `.failed` on any other error.
    ///
    /// The default timeout looks generous for a path that shows no UI — the
    /// helper only runs `sudo -n`, which cannot block on a prompt — but the cost
    /// is launching the helper, not running it. A warm launch round-trips in
    /// under 4s; the first launch after MenuShelf is rebuilt (and the helper
    /// therefore re-signed) can take far longer while Gatekeeper assesses the new
    /// signature. Timing out early there would report a spurious failure and
    /// switch the setting back off.
    static func setDisableSleep(_ on: Bool, timeout: TimeInterval = 90) -> ToggleResult {
        switch runHelper(on ? "on" : "off", timeout: timeout) {
        case .ok:
            return .ok
        case .cancelled:
            // The toggle path shows no authorization sheet, so a cancellation
            // here can only mean the helper died before reporting.
            return .failed("The helper exited before completing.")
        case .grantMissing:
            return .grantMissing
        case .failed(let message):
            return .failed(message)
        }
    }

    /// True when the passwordless grant is present.
    ///
    /// This is a plain existence check rather than `sudo -n -l <cmd>`, which is
    /// what it used to be: `sudo -l` answers from policy alone and returns success
    /// for any account matching a broad rule such as `%admin ALL=(ALL) ALL`, so on
    /// an ordinary admin Mac it reported the grant as installed when it was not.
    /// The drop-in is 0440 root:wheel and therefore unreadable, but /etc/sudoers.d
    /// is 0755, so probing one known path works — including from the sandbox.
    static func isGrantInstalled() -> Bool {
        FileManager.default.fileExists(atPath: sudoersPath)
    }

    /// Read the current `SleepDisabled` value from `pmset -g` (no root needed, and
    /// permitted inside the sandbox). Returns `true` when lid/idle sleep is
    /// currently disabled. `pmset` omits the key entirely until something sets it,
    /// so "absent" correctly reads as `false`.
    static func readSleepDisabled() -> Bool {
        let (status, out, _) = run("/usr/bin/pmset", ["-g"])
        guard status == 0 else { return false }
        for line in out.split(separator: "\n")
        where line.range(of: "SleepDisabled", options: .caseInsensitive) != nil {
            let tokens = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            if let last = tokens.last { return last == "1" }
        }
        return false
    }

    // MARK: - Grant install / remove (interactive admin auth)

    /// Install the scoped sudoers grant, showing the native macOS admin
    /// authorization sheet (Touch ID / password) once. Returns `true` on success,
    /// `false` if the user cancels or validation fails.
    ///
    /// The timeout is generous because the user has to authenticate; the helper
    /// itself never blocks indefinitely.
    static func installGrant() -> Bool {
        runHelper("setup", timeout: 180) == .ok
    }

    /// Remove the sudoers grant, showing the native admin authorization sheet.
    /// Callers must clear `disablesleep` to 0 BEFORE removing the grant, since
    /// the reset needs the grant to run.
    static func removeGrant() -> Bool {
        runHelper("revoke", timeout: 180) == .ok
    }

    // MARK: - Helper invocation

    /// Where the nested helper lives inside MenuShelf.app.
    private static var helperURL: URL? {
        let url = Bundle.main.bundleURL
            .appendingPathComponent("Contents/Helpers/MenuShelfLidHelper.app")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    private enum HelperOutcome: Equatable {
        case ok
        case cancelled
        case grantMissing
        case failed(String)
    }

    /// Rendezvous boards. Must stay identical to the names in the helper.
    private static let requestPasteboard = NSPasteboard.Name("app.menushelf.lid.request")
    private static let resultPasteboard = NSPasteboard.Name("app.menushelf.lid.result")

    /// Ask the helper to perform `action` and wait for its verdict.
    ///
    /// Neither direction can use the obvious channels. Launch arguments are
    /// discarded outright when the requesting process is sandboxed — silently,
    /// with an apparently successful launch. A file drop fails differently: the
    /// only directory we may write to is our own container, and an outside
    /// process reading in there trips kTCCServiceSystemPolicyAppData, so macOS
    /// prompts "MenuShelf would like to access data from other apps" on every
    /// single toggle. Named pasteboards cross the boundary in both directions
    /// with no entitlement, no file system, and no TCC.
    @discardableResult
    private static func runHelper(_ action: String, timeout: TimeInterval) -> HelperOutcome {
        guard let helperURL else {
            return .failed("The lid helper is missing from the MenuShelf app bundle.")
        }

        // Tag the request so a leftover verdict from an earlier toggle can never
        // be mistaken for this one's.
        let token = UUID().uuidString
        guard let payload = try? JSONSerialization.data(
                withJSONObject: ["action": action, "token": token]
              ),
              let request = String(data: payload, encoding: .utf8) else {
            return .failed("Could not encode the helper request.")
        }

        let resultBoard = NSPasteboard(name: resultPasteboard)
        resultBoard.clearContents()

        let requestBoard = NSPasteboard(name: requestPasteboard)
        requestBoard.clearContents()
        guard requestBoard.setString(request, forType: .string) else {
            return .failed("Could not post the helper request.")
        }

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        // Without this, LaunchServices activates a still-running previous
        // instance instead of starting one that will read our new request.
        configuration.createsNewApplicationInstance = true
        configuration.addsToRecentItems = false

        let launchError = LockedBox<Error?>(nil)
        let launched = DispatchSemaphore(value: 0)
        NSWorkspace.shared.openApplication(at: helperURL, configuration: configuration) { _, error in
            launchError.value = error
            launched.signal()
        }

        // Same reasoning as the verdict timeout: a cold Gatekeeper assessment can
        // hold this callback for tens of seconds after a rebuild.
        guard launched.wait(timeout: .now() + 90) == .success else {
            return .failed("The lid helper did not start.")
        }
        if let error = launchError.value {
            return .failed(error.localizedDescription)
        }

        return awaitVerdict(token: token, timeout: timeout)
    }

    /// Poll the result board until our token shows up. Polling keeps this
    /// synchronous for the off-main-thread callers, and the interval is coarse
    /// enough that the wait costs nothing measurable.
    private static func awaitVerdict(token: String, timeout: TimeInterval) -> HelperOutcome {
        let board = NSPasteboard(name: resultPasteboard)
        let deadline = Date().addingTimeInterval(timeout)

        while Date() < deadline {
            if let raw = board.string(forType: .string),
               let data = raw.data(using: .utf8),
               let object = try? JSONSerialization.jsonObject(with: data) as? [String: String],
               object["token"] == token,
               let status = object["status"] {
                let message = object["message"] ?? ""
                switch status {
                case "ok": return .ok
                case "cancelled": return .cancelled
                case "grantMissing": return .grantMissing
                default: return .failed(message.isEmpty ? "The lid helper reported a failure." : message)
                }
            }
            Thread.sleep(forTimeInterval: 0.1)
        }
        return .failed("The lid helper timed out.")
    }

    /// Run a process to completion, returning its exit status and captured
    /// stdout/stderr. Output is drained before `waitUntilExit()` to avoid a pipe
    /// deadlock; the commands here produce only small output.
    private static func run(_ path: String, _ arguments: [String]) -> (status: Int32, out: String, err: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        do {
            try process.run()
        } catch {
            return (-1, "", "\(error)")
        }

        let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        return (
            process.terminationStatus,
            String(data: outData, encoding: .utf8) ?? "",
            String(data: errData, encoding: .utf8) ?? ""
        )
    }
}

/// Minimal mutable box for handing a value back from the `openApplication`
/// completion, which runs on an arbitrary queue.
private final class LockedBox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: T

    init(_ value: T) { stored = value }

    var value: T {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}
