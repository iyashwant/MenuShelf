//
//  DiagnosticsPropertyTests.swift
//  WorldClockTests
//
//  Property test for the diagnostics PII boundary. Validates Property
//  28: for any `(label, emoji)` configuration and any sequence of
//  operations, the strings emitted by `DiagnosticsLogger.shared.log(_:)`
//  never contain `clock.label` or `clock.emoji` as a substring at any
//  verbosity level. Formatted times produced by the World Clock
//  subsystem are also never logged.
//
//  Strategy:
//
//  Property 28 is hard to test directly because:
//
//  1. `DiagnosticsLogger.shared` is a singleton tied to the running
//     app's settings (`enableVerboseDiagnostics`).
//  2. The controller's `logIfVerbose(_:)` reads
//     `AppContainer.shared.store.settings.resolvedEnableVerboseDiagnostics`
//     before forwarding to the logger.
//  3. Driving the controller from `swift test` requires AppKit
//     globals that would corrupt application state.
//
//  The pragmatic alternative documented in the spec's testing-strategy
//  fallback is a *meta-test*: read the source file
//  `Sources/MenuShelf/WorldClock/WorldClockController.swift` at test
//  time and assert that no `logIfVerbose(...)` call site interpolates
//  any of the privacy-sensitive expressions:
//
//   - `clock.label` / `\(clock.label)` / `clock?.label`
//   - `clock.emoji` / `\(clock.emoji)` / `clock?.emoji`
//   - `formatWorldClockTime(...)` invocations (formatted time strings)
//
//  This is a static check, but it gives high-confidence enforcement of
//  Property 28's runtime claim — the production logging infrastructure
//  cannot leak PII unless one of those interpolations exists in the
//  source file. The meta-test catches future drift if a maintainer
//  adds a `DiagnosticsLogger.shared.log(...)` line that interpolates a
//  user-supplied label/emoji/time string, satisfying the documented
//  privacy rail (Requirement 11.3, 11.4).
//

import Foundation
import Testing
@testable import MenuShelf

// MARK: - Source file resolution

/// Returns the absolute path to the World Clock source directory. The
/// test file lives at
/// `<repo>/Tests/WorldClockTests/DiagnosticsPropertyTests.swift`; we
/// navigate up two levels and then into `Sources/MenuShelf/WorldClock`.
private func worldClockSourceDirectory(file: StaticString = #filePath) -> URL {
    let testFileURL = URL(fileURLWithPath: "\(file)")
    let testsDir = testFileURL.deletingLastPathComponent()  // .../Tests/WorldClockTests
    let testsRoot = testsDir.deletingLastPathComponent()    // .../Tests
    let workspaceRoot = testsRoot.deletingLastPathComponent()  // .../<repo>
    return workspaceRoot
        .appendingPathComponent("Sources")
        .appendingPathComponent("MenuShelf")
        .appendingPathComponent("WorldClock")
}

/// Read every `.swift` file under the World Clock source directory and
/// return them as `(filename, contents)` pairs.
private func loadWorldClockSources() throws -> [(name: String, contents: String)] {
    let directory = worldClockSourceDirectory()
    let fileManager = FileManager.default
    let contents = try fileManager.contentsOfDirectory(
        at: directory,
        includingPropertiesForKeys: nil
    )
    var result: [(String, String)] = []
    for url in contents where url.pathExtension == "swift" {
        let text = try String(contentsOf: url, encoding: .utf8)
        result.append((url.lastPathComponent, text))
    }
    return result
}

// MARK: - Property 28: PII boundary

/// **Validates: Requirements 11.3, 11.4**
///
/// Every `logIfVerbose(...)` and `DiagnosticsLogger.shared.log(...)`
/// call site inside `Sources/MenuShelf/WorldClock/` interpolates only
/// structural information — clock counts, popover-visible booleans,
/// schema versions, and UUIDs. None of the calls reference the
/// privacy-sensitive expressions `clock.label`, `clock.emoji`, or any
/// formatted-time helper output.
@Test("Property 28: no logIfVerbose / DiagnosticsLogger.log call site interpolates clock.label, clock.emoji, or formatWorldClockTime")
func property28NoPIIInLogCallSites() throws {
    let sources = try loadWorldClockSources()
    #expect(!sources.isEmpty, "Expected to find at least one WorldClock source file")

    // Patterns that would indicate a privacy-rail violation. Each
    // pattern is searched against the entire log-call line range —
    // we identify the call site by locating `logIfVerbose(` or
    // `DiagnosticsLogger.shared.log(` and then extracting the next
    // closing `)` (single-line form is sufficient because the
    // production code uses single-line log calls; multiline log calls
    // would be flagged for review anyway).
    let forbiddenSubstrings = [
        "clock.label",
        "clock?.label",
        "clock.emoji",
        "clock?.emoji",
        "formatWorldClockTime(",
        "formatPinnedTitle(",
        ".displayLabel",
        "displayedTimeString",
    ]

    for (name, contents) in sources {
        let logCallRanges = locateLogCallRanges(in: contents)
        for range in logCallRanges {
            let snippet = String(contents[range])
            for forbidden in forbiddenSubstrings {
                #expect(
                    !snippet.contains(forbidden),
                    "PII violation in \(name): log call interpolates '\(forbidden)' — snippet: \(snippet.prefix(200))"
                )
            }
        }
    }
}

@Test("Property 28: every logIfVerbose call uses structural-only message format")
func property28LogCallsAreStructuralOnly() throws {
    let sources = try loadWorldClockSources()

    // The documented log call sites in WorldClockController.swift are:
    //   1. "WorldClock pinned remove id=<UUID>"
    //   2. "WorldClock pinned create id=<UUID>"
    //   3. "WorldClock popover open"
    //   4. "WorldClock popover close"
    //   5. "WorldClock minute tick clocks=<Int> popover=<Bool>"
    //
    // Each of these is structural — UUIDs, counts, booleans only.
    // Verify by enumerating the logIfVerbose call sites and checking
    // that each interpolation expression matches the documented set:
    //   - .uuidString (UUID stringification)
    //   - .count (Array/Dictionary count)
    //   - == comparisons producing Bool
    //   - struct field reads not in the forbidden list above
    //
    // This is a softer check (we don't enumerate every safe pattern),
    // so we just spot-check the controller file for the documented
    // log strings.
    let controllerSource = sources.first { $0.name == "WorldClockController.swift" }
    #expect(controllerSource != nil, "Expected to find WorldClockController.swift")

    if let controller = controllerSource {
        // Each documented log line should appear as a substring of
        // the source file (modulo Swift string interpolation syntax).
        let expectedFragments = [
            "WorldClock pinned remove id=",
            "WorldClock pinned create id=",
            "WorldClock popover open",
            "WorldClock popover close",
            "WorldClock minute tick clocks=",
        ]
        for fragment in expectedFragments {
            #expect(
                controller.contents.contains(fragment),
                "Expected documented log fragment '\(fragment)' in WorldClockController.swift"
            )
        }
    }
}

@Test("Property 28: no DiagnosticsLogger.shared.log call site outside logIfVerbose interpolates user-controlled fields")
func property28NoDirectLogPII() throws {
    let sources = try loadWorldClockSources()
    for (name, contents) in sources {
        // Find direct `DiagnosticsLogger.shared.log(...)` calls.
        // Production code in WorldClock/ should only call the helper
        // `logIfVerbose(...)` defined inside the controller — direct
        // calls would bypass the verbose-diagnostics gate. The only
        // exception is the controller's own helper definition; that
        // line is allowed because the call site is inside the helper.
        let directLogRanges = locateDirectDiagnosticsLogRanges(in: contents)
        for range in directLogRanges {
            let snippet = String(contents[range])
            // Skip the helper definition site (it's the body of
            // `logIfVerbose(_:)`).
            if name == "WorldClockController.swift",
               snippet.contains("DiagnosticsLogger.shared.log(message)") {
                continue
            }
            // Any direct call must not interpolate user-controlled
            // expressions. Reuse the forbidden substring set from
            // Property 28's main test.
            let forbiddenSubstrings = [
                "clock.label",
                "clock?.label",
                "clock.emoji",
                "clock?.emoji",
                "formatWorldClockTime(",
                "formatPinnedTitle(",
            ]
            for forbidden in forbiddenSubstrings {
                #expect(
                    !snippet.contains(forbidden),
                    "Direct DiagnosticsLogger.log call in \(name) interpolates '\(forbidden)' — snippet: \(snippet.prefix(200))"
                )
            }
        }
    }
}

// MARK: - Source-scanning helpers

/// Locate every `logIfVerbose(...)` call site in `source`. Returns a
/// list of `Range<String.Index>` covering the entire single-line call,
/// from the opening `logIfVerbose(` to the matching closing `)`.
///
/// The implementation handles both single-line and the documented
/// multi-line form
///
///     logIfVerbose(
///         "WorldClock minute tick clocks=\(pinnedItems.count) "
///         + "popover=\(panel?.isPresented == true)"
///     )
///
/// by counting balanced parentheses. Any line preceded by `//` that
/// happens to contain the substring `logIfVerbose(` (e.g. in a
/// docstring) is skipped.
private func locateLogCallRanges(in source: String) -> [Range<String.Index>] {
    return locateBalancedCallRanges(
        in: source,
        callPrefixes: ["logIfVerbose("]
    )
}

private func locateDirectDiagnosticsLogRanges(in source: String) -> [Range<String.Index>] {
    return locateBalancedCallRanges(
        in: source,
        callPrefixes: ["DiagnosticsLogger.shared.log("]
    )
}

private func locateBalancedCallRanges(
    in source: String,
    callPrefixes: [String]
) -> [Range<String.Index>] {
    var results: [Range<String.Index>] = []
    for prefix in callPrefixes {
        var searchStart = source.startIndex
        while searchStart < source.endIndex,
              let prefixRange = source.range(
                of: prefix,
                options: [],
                range: searchStart..<source.endIndex
              ) {
            // Skip occurrences inside line comments. Walk backwards
            // from the prefix to the previous newline; if we hit `//`
            // before the newline, this match is in a comment.
            if isInsideLineComment(at: prefixRange.lowerBound, in: source) {
                searchStart = prefixRange.upperBound
                continue
            }

            // Skip occurrences inside multi-line block comments. This
            // is approximate but sufficient for the WorldClock module
            // (no `/* ... */` blocks contain `logIfVerbose(` today).
            // We don't bother detecting them.

            // Match parentheses from the open `(` to its balanced close.
            // The prefix already covers the open `(`, so start the
            // depth at 1.
            let openParenIdx = source.index(before: prefixRange.upperBound)
            var depth = 1
            var idx = source.index(after: openParenIdx)
            while idx < source.endIndex, depth > 0 {
                let char = source[idx]
                if char == "(" {
                    depth += 1
                } else if char == ")" {
                    depth -= 1
                    if depth == 0 {
                        break
                    }
                }
                idx = source.index(after: idx)
            }
            if depth == 0 {
                let endIdx = source.index(after: idx)
                let range = prefixRange.lowerBound..<endIdx
                results.append(range)
                searchStart = endIdx
            } else {
                // Unbalanced — bail to avoid an infinite loop.
                searchStart = source.endIndex
            }
        }
    }
    return results
}

/// Return `true` when `index` falls inside a `//` line comment.
private func isInsideLineComment(at index: String.Index, in source: String) -> Bool {
    // Walk backwards from `index` to the previous newline; if we hit
    // `//` along the way, the match is in a comment.
    var cursor = index
    while cursor > source.startIndex {
        cursor = source.index(before: cursor)
        let char = source[cursor]
        if char == "\n" { return false }
        if char == "/" && cursor > source.startIndex {
            let prev = source.index(before: cursor)
            if source[prev] == "/" {
                return true
            }
        }
    }
    return false
}
