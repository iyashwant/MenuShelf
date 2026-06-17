//
//  CaffeineShelfLidControl.swift
//  MenuShelf
//
//  The privileged "keep awake with the lid closed" mechanism, modeled on the
//  Sleepless app. IOKit power assertions cannot override clamshell (lid-close)
//  sleep — the only thing that does is the kernel `SleepDisabled` flag, set via
//  `pmset disablesleep`, which requires root.
//
//  To run it without prompting on every toggle, a one-time native admin
//  authorization installs a tightly-scoped sudoers drop-in at
//  `/etc/sudoers.d/menushelf-disablesleep` that allows ONLY the two exact
//  `pmset disablesleep 0|1` commands passwordless. After that, toggling is a
//  silent `sudo -n pmset …`.
//
//  All functions here shell out and block, so callers must invoke them off the
//  main thread (e.g. from `Task.detached`). The type is a namespace of static
//  functions with no shared mutable state, so it is safe to call concurrently.
//

import Foundation

enum CaffeineShelfLidControl {
    /// Path of the sudoers drop-in that grants the passwordless toggle.
    static let sudoersPath = "/etc/sudoers.d/menushelf-disablesleep"

    enum ToggleResult: Equatable {
        case ok
        case grantMissing
        case failed(String)
    }

    // MARK: - Toggle

    /// Set the kernel `disablesleep` flag via the passwordless grant. Returns
    /// `.grantMissing` when the sudoers grant isn't installed (so the caller can
    /// trigger the one-time install), or `.failed` on any other error.
    static func setDisableSleep(_ on: Bool) -> ToggleResult {
        let (status, _, err) = run(
            "/usr/bin/sudo",
            ["-n", "/usr/bin/pmset", "-a", "disablesleep", on ? "1" : "0"]
        )
        if status == 0 { return .ok }

        let lowered = err.lowercased()
        if lowered.contains("a password is required")
            || lowered.contains("not allowed")
            || lowered.contains("may not run")
            || lowered.contains("a terminal is required") {
            return .grantMissing
        }
        return .failed(err.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// True when the passwordless grant is present. Uses `sudo -n -l <cmd>`,
    /// which checks the policy without running anything and without prompting.
    static func isGrantInstalled() -> Bool {
        let (status, _, _) = run(
            "/usr/bin/sudo",
            ["-n", "-l", "/usr/bin/pmset", "-a", "disablesleep", "0"]
        )
        return status == 0
    }

    /// Read the current `SleepDisabled` value from `pmset -g` (no root needed).
    /// Returns `true` when lid/idle sleep is currently disabled.
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

    /// Install the scoped sudoers grant for `username`, showing the native macOS
    /// admin authorization sheet (Touch ID / password). The privileged work runs
    /// as root: write to a temp file, validate with `visudo -cf`, then install
    /// `root:wheel 0440` to `sudoersPath`. Returns `true` on success, `false` if
    /// the user cancels or validation fails.
    static func installGrant(username: String) -> Bool {
        guard isValidUsername(username) else { return false }

        // username is validated to [A-Za-z0-9._-]+, so it cannot break out of the
        // single-quoted echo argument below.
        let line = "\(username) ALL=(root) NOPASSWD: "
            + "/usr/bin/pmset -a disablesleep 0, /usr/bin/pmset -a disablesleep 1"
        let shell = [
            "t=\"$(/usr/bin/mktemp)\" || exit 1",
            "/bin/echo '\(line)' > \"$t\"",
            "if /usr/sbin/visudo -cf \"$t\" >/dev/null 2>&1; then "
                + "/usr/bin/install -m 0440 -o root -g wheel \"$t\" \(sudoersPath); rc=$?; "
                + "else rc=1; fi",
            "/bin/rm -f \"$t\"",
            "exit $rc",
        ].joined(separator: "; ")

        return runOsascriptAsAdmin(shell)
    }

    /// Remove the sudoers grant, showing the native admin authorization sheet.
    /// Callers must clear `disablesleep` to 0 BEFORE removing the grant, since
    /// the reset needs the grant to run.
    static func removeGrant() -> Bool {
        runOsascriptAsAdmin("/bin/rm -f \(sudoersPath)")
    }

    // MARK: - Helpers

    private static func runOsascriptAsAdmin(_ shellCommand: String) -> Bool {
        let escaped = shellCommand
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let appleScript = "do shell script \"\(escaped)\" with administrator privileges"
        let (status, _, _) = run("/usr/bin/osascript", ["-e", appleScript])
        return status == 0
    }

    private static func isValidUsername(_ name: String) -> Bool {
        guard !name.isEmpty else { return false }
        let allowed = CharacterSet(
            charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-"
        )
        return name.unicodeScalars.allSatisfy { allowed.contains($0) }
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
