import AppKit
import Foundation

// MARK: - Public types

struct AppleScriptCompileError: Equatable, Sendable {
    let message: String
    let line: Int?
    let range: NSRange?
    let isTimeout: Bool
    let isOversized: Bool
    let isEmpty: Bool

    static func oversized(charCount: Int) -> AppleScriptCompileError {
        AppleScriptCompileError(
            message: "Source is too large (\(charCount) characters). Maximum is 100,000.",
            line: nil,
            range: nil,
            isTimeout: false,
            isOversized: true,
            isEmpty: false
        )
    }

    static var empty: AppleScriptCompileError {
        AppleScriptCompileError(
            message: "Source is empty.",
            line: nil,
            range: nil,
            isTimeout: false,
            isOversized: false,
            isEmpty: true
        )
    }

    static var timeout: AppleScriptCompileError {
        AppleScriptCompileError(
            message: "Compilation timed out after 5 seconds.",
            line: nil,
            range: nil,
            isTimeout: true,
            isOversized: false,
            isEmpty: false
        )
    }
}

enum CompileOutcome: Sendable {
    case success
    case failure(AppleScriptCompileError)
}

struct AppleScriptExecutionError: Equatable, Sendable {
    let message: String
    let errorNumber: Int
    let appName: String?
    let isPermissionFamily: Bool
    let rawDictionary: [String: String]
}

enum RunOutcome: Sendable {
    case success(stringValue: String, durationMs: Int)
    case compileFailed(AppleScriptCompileError)
    case executionFailed(AppleScriptExecutionError)
    case timedOut(elapsedMs: Int)
}

// MARK: - Service

/// In-process AppleScript executor. Stateless; safe to share across the app.
/// Never spawns a helper process (sandbox forbids it). Compile + execute run on
/// a private serial queue so the actor itself isn't blocked.
actor AppleScriptService {
    private static let maxSourceChars = 100_000
    private static let compileTimeoutNs: UInt64 = 5_000_000_000
    private let queue = DispatchQueue(label: "com.menushelf.applescript", qos: .userInitiated)

    func compile(source: String) async -> CompileOutcome {
        if source.isEmpty {
            return .failure(.empty)
        }
        if source.count > Self.maxSourceChars {
            return .failure(.oversized(charCount: source.count))
        }

        return await withTimeout(nanoseconds: Self.compileTimeoutNs, onTimeout: .failure(.timeout)) {
            await withCheckedContinuation { continuation in
                self.queue.async {
                    guard let script = NSAppleScript(source: source) else {
                        continuation.resume(returning: .failure(AppleScriptCompileError(
                            message: "Could not initialize NSAppleScript with provided source.",
                            line: nil,
                            range: nil,
                            isTimeout: false,
                            isOversized: false,
                            isEmpty: false
                        )))
                        return
                    }

                    var errorInfo: NSDictionary?
                    if script.compileAndReturnError(&errorInfo) {
                        continuation.resume(returning: .success)
                    } else {
                        continuation.resume(returning: .failure(Self.compileError(from: errorInfo)))
                    }
                }
            }
        }
    }

    /// Run a script. Returns the first of: actual completion, or timeout. The
    /// underlying NSAppleScript cannot be cancelled from outside, so on timeout
    /// we stop awaiting the result; the orphaned task eventually completes and
    /// is logged at verbose level.
    func run(source: String, scriptName: String, timeout: Duration = .seconds(30)) async -> RunOutcome {
        // Compile first so we surface the right error case.
        let compileResult = await compile(source: source)
        if case .failure(let err) = compileResult {
            return .compileFailed(err)
        }

        let timeoutMs = max(0, Int(timeoutMilliseconds(from: timeout)))
        let timeoutNs = UInt64(timeoutMs) * 1_000_000

        let runner: () async -> RunOutcome = {
            await withCheckedContinuation { continuation in
                self.queue.async {
                    let clock = ContinuousClock()
                    let start = clock.now

                    guard let script = NSAppleScript(source: source) else {
                        let error = AppleScriptExecutionError(
                            message: "Could not initialize NSAppleScript at run time.",
                            errorNumber: 0,
                            appName: nil,
                            isPermissionFamily: false,
                            rawDictionary: [:]
                        )
                        continuation.resume(returning: .executionFailed(error))
                        return
                    }

                    var errorInfo: NSDictionary?
                    let descriptor = script.executeAndReturnError(&errorInfo)
                    let elapsed = clock.now - start
                    let elapsedMs = Self.milliseconds(in: elapsed)

                    if let errorInfo {
                        let execError = Self.executionError(from: errorInfo)
                        if execError.isPermissionFamily {
                            // Permission family is reported as executionFailed; the
                            // caller decides which alert to show.
                            continuation.resume(returning: .executionFailed(execError))
                        } else if Self.isCompileFailureAtRunTime(execError) {
                            continuation.resume(returning: .compileFailed(Self.compileError(from: errorInfo)))
                        } else {
                            continuation.resume(returning: .executionFailed(execError))
                        }
                        return
                    }

                    let stringValue = descriptor.stringValue ?? ""
                    continuation.resume(returning: .success(stringValue: stringValue, durationMs: elapsedMs))
                }
            }
        }

        let elapsedClock = ContinuousClock()
        let started = elapsedClock.now

        return await withTimeout(
            nanoseconds: timeoutNs,
            onTimeout: .timedOut(elapsedMs: Self.milliseconds(in: elapsedClock.now - started))
        ) {
            await runner()
        }
    }

    /// Run an AppleScript from a file URL. The script is loaded from disk and
    /// executed directly without compilation (the .scpt bundle is already compiled).
    /// Returns the first of: actual completion, or timeout.
    func runFromFile(bookmark: Data, scriptName: String, timeout: Duration = .seconds(30)) async -> RunOutcome {
        return await withCheckedContinuation { continuation in
            self.queue.async {
                // Resolve the bookmark to access the file
                var isStale = false
                guard let url = try? URL(
                    resolvingBookmarkData: bookmark,
                    options: .withSecurityScope,
                    relativeTo: nil,
                    bookmarkDataIsStale: &isStale
                ) else {
                    let error = AppleScriptExecutionError(
                        message: "Could not resolve script file. The file may have been moved or deleted.",
                        errorNumber: 0,
                        appName: nil,
                        isPermissionFamily: false,
                        rawDictionary: [:]
                    )
                    continuation.resume(returning: .executionFailed(error))
                    return
                }

                guard url.startAccessingSecurityScopedResource() else {
                    let error = AppleScriptExecutionError(
                        message: "Could not access the script file. Permission denied.",
                        errorNumber: 0,
                        appName: nil,
                        isPermissionFamily: false,
                        rawDictionary: [:]
                    )
                    continuation.resume(returning: .executionFailed(error))
                    return
                }

                defer { url.stopAccessingSecurityScopedResource() }

                let clock = ContinuousClock()
                let start = clock.now

                guard let script = NSAppleScript(contentsOf: url, error: nil) else {
                    let error = AppleScriptExecutionError(
                        message: "Could not load AppleScript from file: \(url.lastPathComponent)",
                        errorNumber: 0,
                        appName: nil,
                        isPermissionFamily: false,
                        rawDictionary: [:]
                    )
                    continuation.resume(returning: .executionFailed(error))
                    return
                }

                var errorInfo: NSDictionary?
                let descriptor = script.executeAndReturnError(&errorInfo)
                let elapsed = clock.now - start
                let elapsedMs = Self.milliseconds(in: elapsed)

                if let errorInfo {
                    let execError = Self.executionError(from: errorInfo)
                    if execError.isPermissionFamily {
                        continuation.resume(returning: .executionFailed(execError))
                    } else {
                        continuation.resume(returning: .executionFailed(execError))
                    }
                    return
                }

                let stringValue = descriptor.stringValue ?? ""
                continuation.resume(returning: .success(stringValue: stringValue, durationMs: elapsedMs))
            }
        }
    }

    // MARK: - Helpers

    private func withTimeout<T: Sendable>(
        nanoseconds: UInt64,
        onTimeout: T,
        operation: @escaping @Sendable () async -> T
    ) async -> T {
        await withTaskGroup(of: T.self) { group in
            group.addTask { await operation() }
            group.addTask {
                try? await Task.sleep(nanoseconds: nanoseconds)
                return onTimeout
            }

            let first = await group.next() ?? onTimeout
            group.cancelAll()
            return first
        }
    }

    private func timeoutMilliseconds(from duration: Duration) -> Double {
        let comps = duration.components
        return Double(comps.seconds) * 1000.0 + Double(comps.attoseconds) / 1_000_000_000_000_000.0
    }

    private static func milliseconds(in duration: Duration) -> Int {
        let comps = duration.components
        let seconds = Double(comps.seconds)
        let frac = Double(comps.attoseconds) / 1_000_000_000_000_000_000.0
        return Int((seconds + frac) * 1000.0)
    }

    private static func compileError(from dict: NSDictionary?) -> AppleScriptCompileError {
        let message = (dict?[NSAppleScript.errorMessage] as? String)
            ?? (dict?[NSAppleScript.errorBriefMessage] as? String)
            ?? "AppleScript compile error."

        var line: Int?
        var range: NSRange?
        if let value = dict?[NSAppleScript.errorRange] as? NSValue {
            range = value.rangeValue
        }
        // NSAppleScript surfaces a "OSAScriptErrorLineKey" in some builds; fall
        // back to range location → 1-based line by scanning. We also look up
        // a numeric line directly when present.
        if let n = dict?["OSAScriptErrorLineNumber"] as? NSNumber {
            line = n.intValue
        } else if let n = dict?["NSAppleScriptErrorLine"] as? NSNumber {
            line = n.intValue
        }

        return AppleScriptCompileError(
            message: message,
            line: line,
            range: range,
            isTimeout: false,
            isOversized: false,
            isEmpty: false
        )
    }

    private static func executionError(from dict: NSDictionary) -> AppleScriptExecutionError {
        let message = (dict[NSAppleScript.errorMessage] as? String)
            ?? (dict[NSAppleScript.errorBriefMessage] as? String)
            ?? "AppleScript execution error."

        let number = (dict[NSAppleScript.errorNumber] as? NSNumber)?.intValue ?? 0
        let appName = dict[NSAppleScript.errorAppName] as? String

        let permission = number == -1742 || number == -1743 || number == -1744

        var raw: [String: String] = [:]
        for (key, value) in dict {
            if let key = key as? String {
                raw[key] = String(describing: value)
            }
        }

        let suffixed = "\(message) (error \(number))"

        return AppleScriptExecutionError(
            message: suffixed,
            errorNumber: number,
            appName: appName,
            isPermissionFamily: permission,
            rawDictionary: raw
        )
    }

    /// Some compile-style errors arrive at execution time when the source is
    /// modified between compile() and run(). Heuristic: an error in the
    /// -2700..-2799 OSA-script range without a target app name.
    private static func isCompileFailureAtRunTime(_ error: AppleScriptExecutionError) -> Bool {
        error.appName == nil && error.errorNumber <= -2700 && error.errorNumber >= -2799
    }
}
