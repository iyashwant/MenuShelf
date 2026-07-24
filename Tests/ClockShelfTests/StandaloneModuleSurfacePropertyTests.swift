//
//  StandaloneModuleSurfacePropertyTests.swift
//  ClockShelfTests
//
//  Locks the two-surface contract for the modules that own a SwiftUI
//  panel (Clipboard Shelf, Clock Shelf, Bookmark Shelf):
//
//    - As its OWN menu bar item, a module opens its own UI directly.
//    - Inside a menu view (mixed with folders and other modules), the
//      module renders as a native `NSMenu` first, with a trailing
//      action that escalates to its own UI.
//
//  The first half of that contract rests on a *negative* structural
//  claim: `StandaloneModuleClickRouter` must never consult
//  `presentationMode`. That field is an in-menu concern only — if the
//  router ever started reading it, setting a module to `.submenu`
//  would silently change what its standalone icon does, collapsing
//  the two surfaces into one.
//
//  A shape-reproduction test cannot establish a "this code does not
//  read X" claim — reproducing the router would only assert a copy.
//  Following the meta-test precedent documented in
//  `DiagnosticsPropertyTests.swift` (Property 28), this reads the
//  router source at test time and asserts the absence of the coupling.
//  Static, but it catches exactly the drift that would break the
//  contract, which a behavioural test here cannot reach without
//  standing up AppKit globals.
//

import Foundation
import Testing
@testable import MenuShelf

// MARK: - Source file resolution

/// Absolute path to `Sources/MenuShelf/StandaloneModules/`. This test
/// file lives at `<repo>/Tests/ClockShelfTests/<name>.swift`, so we
/// navigate up two levels and back down.
private func standaloneModulesSourceDirectory(file: StaticString = #filePath) -> URL {
    let testFileURL = URL(fileURLWithPath: "\(file)")
    let workspaceRoot = testFileURL
        .deletingLastPathComponent()   // .../Tests/ClockShelfTests
        .deletingLastPathComponent()   // .../Tests
        .deletingLastPathComponent()   // .../<repo>
    return workspaceRoot
        .appendingPathComponent("Sources")
        .appendingPathComponent("MenuShelf")
        .appendingPathComponent("StandaloneModules")
}

private func loadClickRouterSource() throws -> String {
    let url = standaloneModulesSourceDirectory()
        .appendingPathComponent("StandaloneModuleClickRouter.swift")
    return try String(contentsOf: url, encoding: .utf8)
}

// MARK: - Standalone surface is mode-independent

/// The standalone status item must open the module's own UI regardless
/// of how the module is configured to render inside menu views.
@Test("StandaloneModuleClickRouter never reads presentationMode")
func standaloneRouterIgnoresPresentationMode() throws {
    let source = try loadClickRouterSource()
    #expect(!source.isEmpty, "Expected to read StandaloneModuleClickRouter.swift")

    // `resolvedPresentationMode` is the accessor every in-menu builder
    // funnels through; `presentationMode` catches direct field reads.
    #expect(
        !source.contains("resolvedPresentationMode"),
        "StandaloneModuleClickRouter must not branch on resolvedPresentationMode — the standalone icon always opens the module's own UI."
    )
    #expect(
        !source.contains("presentationMode"),
        "StandaloneModuleClickRouter must not branch on presentationMode — the standalone icon always opens the module's own UI."
    )
}

/// Branch D of `dispatch(...)` routes each panel-owning module straight
/// at its controller. Pins those call sites so a refactor that swapped
/// one for a menu-building helper would fail here.
@Test("Standalone dispatch routes panel-owning modules at their own controllers")
func standaloneDispatchRoutesToControllers() throws {
    let source = try loadClickRouterSource()

    #expect(source.contains("ClipboardShelfController.shared.togglePopup(anchor: anchorButton)"))
    #expect(source.contains("ClockShelfController.shared.togglePopover(anchor: anchorButton)"))
    #expect(source.contains("BookmarkShelfController.shared.togglePopup(anchor: anchorButton)"))
}

// MARK: - In-menu default

/// The in-menu default is `.submenu` for both mode-carrying,
/// panel-owning modules, so a module dropped into a menu view beside
/// folder rows hovers open like they do rather than presenting as a
/// bare click target.
@Test("Clipboard and Clock default to .submenu inside menu views")
func inMenuDefaultsAreSubmenu() {
    #expect(ClipboardShelfSettings.defaults.resolvedPresentationMode == .submenu)
    #expect(ClockShelfSettings.defaults.resolvedPresentationMode == .submenu)

    // Settings blobs predating the field resolve the same way.
    var clipboard = ClipboardShelfSettings.defaults
    clipboard.presentationMode = nil
    #expect(clipboard.resolvedPresentationMode == .submenu)

    var clock = ClockShelfSettings.defaults
    clock.presentationMode = nil
    #expect(clock.resolvedPresentationMode == .submenu)
}

/// An explicitly persisted `.popover` is a deliberate user choice and
/// must survive — the default change is not retroactive.
@Test("Explicit .popover is preserved, not overridden by the new default")
func explicitPopoverIsPreserved() {
    var clipboard = ClipboardShelfSettings.defaults
    clipboard.presentationMode = .popover
    #expect(clipboard.resolvedPresentationMode == .popover)

    var clock = ClockShelfSettings.defaults
    clock.presentationMode = .popover
    #expect(clock.resolvedPresentationMode == .popover)
}
