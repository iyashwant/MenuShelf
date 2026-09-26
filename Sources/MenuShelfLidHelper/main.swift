//
//  main.swift
//  MenuShelfLidHelper
//
//  Tiny UNSANDBOXED companion that performs the privileged half of
//  CaffeineShelf's "keep awake with lid closed" feature on MenuShelf's behalf.
//
//  Why this exists
//  ---------------
//  IOKit power assertions cannot override clamshell (lid-close) sleep — only the
//  kernel `SleepDisabled` flag does, and that is set with `pmset disablesleep`,
//  which needs root. MenuShelf.app is sandboxed, and the App Sandbox blocks every
//  route to root, as measured directly:
//
//    * `Process` -> /usr/bin/sudo            : EPERM at exec (setuid binary)
//    * `do shell script … with admin privs`  : error -60005, no dialog shown
//    * writing to own Application Scripts dir: permission denied
//
//  So the grant is useless to the sandboxed app even once installed — the *toggle*
//  needs an out-of-sandbox process too, not just the one-time setup.
//
//  A child spawned with posix_spawn inherits the sandbox, but an .app launched
//  through LaunchServices does not: it gets the sandbox its OWN signature asks
//  for. This bundle is signed with no sandbox entitlement, so MenuShelf reaches
//  root by asking NSWorkspace to launch it. Amphetamine solves the same problem
//  with NSUserAppleScriptTask, which forces a separately downloaded installer,
//  because a sandboxed app cannot place the script in Application Scripts itself.
//  Bundling this helper keeps setup entirely inside MenuShelf.
//
//  Protocol
//  --------
//  The command CANNOT travel in argv: LaunchServices silently discards launch
//  arguments when the requesting process is sandboxed (verified — the same
//  `open -n … --args` that works from a shell delivers an argv of length 1 when
//  the requester is MenuShelf). A sandboxed app is not permitted to inject argv
//  into another process, and NSWorkspace.OpenConfiguration.arguments is dropped
//  for the same reason, with no error reported.
//
//  It cannot travel through a file either. The only place a sandboxed MenuShelf
//  may write is its own container, and an outside process reading in there is
//  precisely what kTCCServiceSystemPolicyAppData guards — macOS then prompts
//  "MenuShelf would like to access data from other apps" on EVERY toggle, which
//  is both alarming and wrong for what this does.
//
//  So the two sides rendezvous on named pasteboards, which cross the sandbox
//  boundary in both directions with no entitlement, no file system, and no TCC:
//
//    app.menushelf.lid.request   {"action":"setup|on|off|revoke","token":…}  ← MenuShelf
//    app.menushelf.lid.result    {"token":…,"status":…,"message":…}          ← us
//
//  MenuShelf writes a request, launches this helper with no arguments, and polls
//  the result board for its token. We claim the request by clearing it the moment
//  we read it, so a second instance can never run the same action twice.
//
//  Passing an action in argv still works when invoked directly from a terminal,
//  which keeps the helper testable in isolation:
//
//    MenuShelfLidHelper --off --result /tmp/verdict.json
//

import AppKit
import Foundation

// MARK: - Shared constants

/// Must stay identical to `CaffeineShelfLidControl.sudoersPath`.
let sudoersPath = "/etc/sudoers.d/menushelf-disablesleep"

/// Rendezvous boards. Must stay identical to the names in
/// `CaffeineShelfLidControl`.
let requestPasteboard = NSPasteboard.Name("app.menushelf.lid.request")
let resultPasteboard = NSPasteboard.Name("app.menushelf.lid.result")

/// `osascript` exit code when the user dismisses the authorization sheet.
let userCancelledExitCode: Int32 = 128

// MARK: - Result reporting

enum Status: String {
    case ok
    case cancelled
    case grantMissing
    case failed
}

/// Write the verdict and exit. Written atomically so a caller polling for the
/// file never observes a torn read.
func finish(_ status: Status, _ message: String = "") -> Never {
    writeVerdict(status, message, to: resultPath)
    exit(status == .ok ? 0 : 1)
}

func writeVerdict(_ status: Status, _ message: String, to path: String?) {
    guard let path,
          let data = try? JSONSerialization.data(
            withJSONObject: ["status": status.rawValue, "message": message]
          ) else { return }
    try? data.write(to: URL(fileURLWithPath: path), options: .atomic)
}

// MARK: - Process helper

func run(_ path: String, _ arguments: [String]) -> (status: Int32, out: String, err: String) {
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

    // Drain before waiting so a large write can never deadlock the pipe.
    let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
    let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()

    return (
        process.terminationStatus,
        String(data: outData, encoding: .utf8) ?? "",
        String(data: errData, encoding: .utf8) ?? ""
    )
}

/// Run `shellCommand` as root behind one native authorization sheet (Touch ID or
/// password). Returns the `osascript` exit status so the caller can tell a
/// cancellation (128) apart from a real failure.
func runAsAdmin(_ shellCommand: String) -> Int32 {
    let escaped = shellCommand
        .replacingOccurrences(of: "\\", with: "\\\\")
        .replacingOccurrences(of: "\"", with: "\\\"")
    let appleScript = "do shell script \"\(escaped)\" with administrator privileges"
    return run("/usr/bin/osascript", ["-e", appleScript]).status
}

// MARK: - Argument parsing

let arguments = Array(CommandLine.arguments.dropFirst())

/// Path the verdict is written to. Read before any `finish(_:)` call can happen.
let resultPath: String? = {
    guard let index = arguments.firstIndex(of: "--result"),
          arguments.index(after: index) < arguments.endIndex else { return nil }
    return arguments[arguments.index(after: index)]
}()

// MARK: - Commands

/// Install the one-time passwordless grant.
///
/// The privileged shell runs as root, so it writes the drop-in directly with no
/// inner `sudo` prompt: stage into a temp file, validate with `visudo -cf`, then
/// install root:wheel 0440. Validating before installing matters — an unparseable
/// file in /etc/sudoers.d breaks `sudo` system-wide.
///
/// The grant names one user and two fully-specified commands. sudoers matches
/// arguments literally and there are no wildcards, so it cannot be widened:
/// `pmset -a sleep 0`, `pmset restoredefaults` and friends all still demand a
/// password. (Amphetamine's equivalent grants `%admin ALL=(ALL)`, which covers
/// every admin account on the machine; this is deliberately tighter.)
func installGrant() -> (Status, String) {
    let username = NSUserName()

    guard isValidUsername(username) else {
        return (.failed, "Could not resolve a usable user name for the grant.")
    }
    guard username != "root" else {
        return (.failed, "Refusing to install a root-owned grant.")
    }

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

    let status = runAsAdmin(shell)
    if status == 0 { return (.ok, "") }
    if status == userCancelledExitCode { return (.cancelled, "Authorization was cancelled.") }
    return (.failed, "The grant could not be installed (osascript exit \(status)).")
}

/// Remove the grant. Callers clear `disablesleep` first, since the reset itself
/// needs the grant to run.
func removeGrant() -> (Status, String) {
    let status = runAsAdmin("/bin/rm -f \(sudoersPath)")
    if status == 0 { return (.ok, "") }
    if status == userCancelledExitCode { return (.cancelled, "Authorization was cancelled.") }
    return (.failed, "The grant could not be removed (osascript exit \(status)).")
}

/// Flip the kernel flag through the passwordless grant. `-n` guarantees this can
/// never block on a password prompt in a process with no terminal.
func setDisableSleep(_ on: Bool) -> (Status, String) {
    let (status, _, err) = run(
        "/usr/bin/sudo",
        ["-n", "/usr/bin/pmset", "-a", "disablesleep", on ? "1" : "0"]
    )
    if status == 0 { return (.ok, "") }

    // sudo refusing for want of a password means the drop-in is absent or was
    // removed behind our back — the one case that warrants re-running setup.
    let lowered = err.lowercased()
    if lowered.contains("a password is required")
        || lowered.contains("not allowed")
        || lowered.contains("may not run")
        || lowered.contains("a terminal is required") {
        return (.grantMissing, "The passwordless grant is not installed.")
    }
    return (.failed, err.trimmingCharacters(in: .whitespacesAndNewlines))
}

/// Run one named action.
func perform(_ action: String) -> (Status, String) {
    switch action {
    case "setup":  return installGrant()
    case "revoke": return removeGrant()
    case "on":     return setDisableSleep(true)
    case "off":    return setDisableSleep(false)
    default:       return (.failed, "Unknown action \"\(action)\".")
    }
}

func isValidUsername(_ name: String) -> Bool {
    guard !name.isEmpty else { return false }
    let allowed = CharacterSet(
        charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-"
    )
    return name.unicodeScalars.allSatisfy { allowed.contains($0) }
}

// MARK: - Request exchange

/// Read the pending request, run it, and publish the verdict.
///
/// The request is claimed by clearing the pasteboard as soon as it is read, so a
/// second instance launched behind us finds nothing and exits instead of running
/// the same action twice.
func processPendingRequest() -> Never {
    let requestBoard = NSPasteboard(name: requestPasteboard)

    guard let raw = requestBoard.string(forType: .string),
          let data = raw.data(using: .utf8),
          let object = try? JSONSerialization.jsonObject(with: data) as? [String: String],
          let action = object["action"],
          let token = object["token"] else {
        exit(1)
    }
    requestBoard.clearContents()

    let (status, message) = perform(action)
    publish(status, message, token: token)
    exit(status == .ok ? 0 : 1)
}

/// Publish the verdict, tagged with the request's token so MenuShelf can tell our
/// answer apart from a leftover one.
func publish(_ status: Status, _ message: String, token: String) {
    let payload = ["token": token, "status": status.rawValue, "message": message]
    guard let data = try? JSONSerialization.data(withJSONObject: payload),
          let string = String(data: data, encoding: .utf8) else { return }
    let board = NSPasteboard(name: resultPasteboard)
    board.clearContents()
    board.setString(string, forType: .string)
}

// MARK: - Dispatch

// Direct invocation (terminal, debugging) still takes the action from argv.
// A LaunchServices launch never carries arguments, so that path falls through to
// the pasteboard request.
let directAction = ["setup", "revoke", "on", "off"].first { arguments.contains("--\($0)") }

if let directAction {
    let (status, message) = perform(directAction)
    finish(status, message)
} else {
    processPendingRequest()
}
