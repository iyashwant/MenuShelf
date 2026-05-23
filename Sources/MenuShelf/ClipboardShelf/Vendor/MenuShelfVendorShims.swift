//
//  MenuShelfVendorShims.swift
//  MenuShelf — Clipboard Shelf vendor shims
//
//  Lightweight stand-ins for Maccy upstream dependencies that MenuShelf
//  deliberately does not vendor (Sparkle, Settings (sindresorhus),
//  LaunchAtLogin-Modern, SwiftHEXColors, swift-log). Each shim mirrors just
//  enough surface area for the vendored Maccy core to compile and run
//  without pulling in those packages. See `.kiro/specs/clipboard-shelf/`
//  Requirement 8.8 / Task 5.
//
//  `NSColor(hexString:)` is provided natively on macOS 26+, so the
//  SwiftHEXColors shim has been removed. `LaunchAtLogin` and `Sparkle`
//  references were removed at the source-strip step rather than shimmed.
//  Only the swift-log `Logger` API is retained because vendored files
//  use it directly.
//

import Foundation

// MARK: - swift-log shim

/// Minimal `Logger` stand-in that adapts the small subset of swift-log API
/// used by the vendored Maccy core (`Logger(label:).info(_:)`) onto
/// MenuShelf's existing `DiagnosticsLogger`. Verbose-level log routing is
/// unchanged from MenuShelf semantics — entries always go through
/// `DiagnosticsLogger.shared.log(_:)`.
struct Logger {
    let label: String

    init(label: String) {
        self.label = label
    }

    func info(_ message: @autoclosure () -> String) {
        DiagnosticsLogger.shared.log("[\(label)] \(message())")
    }

    func debug(_ message: @autoclosure () -> String) {
        DiagnosticsLogger.shared.log("[\(label)] \(message())")
    }

    func warning(_ message: @autoclosure () -> String) {
        DiagnosticsLogger.shared.log("[\(label)] WARNING: \(message())")
    }

    func error(_ message: @autoclosure () -> String) {
        DiagnosticsLogger.shared.log("[\(label)] ERROR: \(message())")
    }
}
