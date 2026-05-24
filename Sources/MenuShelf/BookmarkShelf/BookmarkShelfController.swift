//
//  BookmarkShelfController.swift
//  MenuShelf
//
//  Single integration seam between MenuShelf and the Bookmark Shelf
//  module. Owns the floating panel hosting the SwiftUI tree, the
//  `BookmarkShelfStorage` handle (which in turn owns
//  `bookmarks.json`), and the global popup hotkey registration via
//  `KeyboardShortcuts.Name.bookmarkShelfPopup`. Mirrors the shape of
//  `ClipboardShelfController` and `WorldClockController` field-for-
//  field so the three modules behave the same way to the rest of the
//  app.
//

import AppKit
import Foundation
import KeyboardShortcuts

@MainActor
final class BookmarkShelfController {
    static let shared = BookmarkShelfController()

    private init() {}

    // MARK: - Internal state

    /// Floating panel hosting `BookmarkShelfPopupView`. Lazily allocated
    /// in `start(with:)` and reused across open/close cycles so the
    /// SwiftUI tree (and its `@StateObject` state) survives across
    /// dismissals.
    private var panel: BookmarkShelfPanel?

    /// Owner of `bookmarks.json`. Allocated in `start(with:)`; its
    /// `init` runs `load()` so the in-memory tree is hydrated before
    /// any UI surface reads from it.
    private var storage: BookmarkShelfStorage?

    /// Latch protecting `start`/`stop` against re-entry. Mirrors the
    /// equivalent flag on `ClipboardShelfController`.
    private var isRunning = false

    /// Snapshot of the last settings passed through
    /// `apply(settings:)`. Used as the diff base for the next reconcile
    /// pass.
    private var lastAppliedSettings: BookmarkShelfSettings?

    /// One-time guard so a corrupt-`bookmarks.json` toast surfaces only
    /// once per session even when the user keeps re-enabling the
    /// feature in settings.
    private var didReportLoadFailure = false

    /// Monotonic counter used for verbose-diagnostics popup-activation
    /// log lines. Reset on `stop()`.
    private var popupActivationSequence: Int = 0

    // MARK: - Lifecycle

    /// Allocate the storage handle, the floating panel, and register
    /// the popup hotkey. Idempotent — when called on a started
    /// controller it forwards to `apply(settings:)` rather than
    /// reinitialising (Requirement 7.4).
    func start(with settings: BookmarkShelfSettings) {
        guard settings.enableBookmarkShelf else { return }

        guard !isRunning else {
            apply(settings: settings)
            return
        }

        // 1. Open the side-file storage. Its `init` runs `load()` and
        // surfaces a one-time `showError(_:)` on decode failure
        // (Requirement 4.6); the controller does not need to wrap it
        // in a do/catch.
        let storage = BookmarkShelfStorage()
        self.storage = storage

        // 2. Build the floating panel. The panel is non-generic over
        // its content view; the popup state object is allocated
        // inside the panel and returned via `popupState` so
        // `handlePanelClose()` can pop the breadcrumb back-stack on
        // dismissal.
        let identifier = (Bundle.main.bundleIdentifier
            ?? "app.menushelf.MenuShelf") + ".bookmarkShelf"
        let panel = BookmarkShelfPanel(
            contentRect: NSRect(origin: .zero, size: settings.popupSize),
            identifier: identifier,
            storage: storage,
            onClose: { [weak self] in
                Task { @MainActor [weak self] in
                    self?.handlePanelClose()
                }
            }
        )
        self.panel = panel

        // 3. Register the popup hotkey. The user opts in by recording
        // a chord in the settings pane; until then the registration
        // is dormant (Requirement 15.5).
        KeyboardShortcuts.onKeyDown(for: .bookmarkShelfPopup) { [weak self] in
            self?.togglePopup(anchor: nil)
        }

        // 4. Emit a single structural diagnostics line containing only
        // counts (Requirement 7.2 / 19.4). User-supplied node titles
        // and URLs never appear in the log.
        let nodeCount = storage.nodes.count
        let folderCount = storage.nodes.filter { $0.kind == .folder }.count
        DiagnosticsLogger.shared.log(
            "Bookmark Shelf started (nodes=\(nodeCount), folders=\(folderCount))"
        )

        lastAppliedSettings = settings
        isRunning = true
    }

    /// Tear down the panel, the storage handle, and the popup hotkey.
    /// Calls `storage.flushNow()` so any pending debounced save
    /// reaches disk before the handle is released (Requirement 7.5).
    func stop() {
        guard isRunning else { return }
        isRunning = false

        panel?.close()
        panel = nil

        KeyboardShortcuts.disable(.bookmarkShelfPopup)

        storage?.flushNow()
        storage = nil
        lastAppliedSettings = nil

        DiagnosticsLogger.shared.log("Bookmark Shelf stopped")
    }

    /// Push a new settings snapshot through. When `enableBookmarkShelf`
    /// is `false` this collapses to `stop()`. Otherwise the call
    /// diffs against `lastAppliedSettings` and pushes the changed
    /// fields into the live panel and hotkey registration without
    /// rebuilding either.
    func apply(settings: BookmarkShelfSettings) {
        if !settings.enableBookmarkShelf {
            stop()
            return
        }

        if !isRunning {
            start(with: settings)
            return
        }

        let previous = lastAppliedSettings

        // Push a new popup size into the panel so the next open uses
        // it (Requirement 7.8). Comparing CGSize via `!=` works
        // because CGSize is Equatable.
        if previous?.popupSize != settings.popupSize {
            panel?.updateContentSize(settings.popupSize)
        }

        // Re-register the hotkey when the chord changed (or on the
        // first apply call after a fresh start where
        // `lastAppliedSettings == nil`). Drop the previous callback
        // first via `disable(_:)` so the new registration replaces
        // the old without leaking the closure (Requirement 7.9 /
        // 15.4).
        if previous == nil || previous?.popupHotkey != settings.popupHotkey {
            KeyboardShortcuts.disable(.bookmarkShelfPopup)
            KeyboardShortcuts.onKeyDown(for: .bookmarkShelfPopup) { [weak self] in
                self?.togglePopup(anchor: nil)
            }
        }

        lastAppliedSettings = settings
    }

    // MARK: - Popup show/hide

    /// Toggle the popup visibility. `anchor` is the originating status
    /// button when invoked from a click; `nil` when triggered by the
    /// global hotkey (in which case `resolveDefaultAnchor()` picks
    /// the best anchor).
    func togglePopup(anchor: NSStatusBarButton?) {
        guard let panel else { return }
        if panel.isPresented {
            panel.close()
        } else {
            showPopup(anchor: anchor)
        }
    }

    /// Show the popup unconditionally (no toggle).
    func showPopup(anchor: NSStatusBarButton?) {
        guard let panel else { return }
        let resolved = anchor ?? resolveDefaultAnchor()
        panel.openAtAnchor(resolved)
        popupActivationSequence += 1
        logPopupActivation(
            action: "show",
            source: anchor == nil ? "globalHotkey" : "click"
        )
    }

    // MARK: - Anchor resolution

    /// Resolve the best status-bar button to anchor the popup to when
    /// no caller-supplied anchor exists. Walks the documented
    /// priority chain:
    ///
    /// 1. The first visible `.bookmarkShelf` standalone module sorted
    ///    ascending by `sortOrder`.
    /// 2. The first menu view whose `bookmarkShelfItem != nil`.
    /// 3. `nil` so the panel centres on the active screen.
    private func resolveDefaultAnchor() -> NSStatusBarButton? {
        let settings = AppContainer.shared.store.settings

        // Step 1: visible standalone module.
        let standalone = settings.resolvedStandaloneModules
            .filter { $0.isVisible && $0.kind == .bookmarkShelf }
            .sorted { $0.sortOrder < $1.sortOrder }
        for module in standalone {
            if let button = AppContainer.shared.statusItemManager
                .statusBarButton(forStandaloneModuleID: module.id) {
                return button
            }
        }

        // Step 2: first menu view carrying a `bookmarkShelfItem`.
        for view in settings.resolvedMenuViews {
            guard view.bookmarkShelfItem != nil else { continue }
            if let button = AppContainer.shared.statusItemManager
                .statusBarButton(for: view.id) {
                return button
            }
        }

        // Step 3: no anchor — centre on the active screen.
        return nil
    }

    // MARK: - Panel close

    /// Reset the breadcrumb back-stack when the panel dismisses. Does
    /// NOT flush a debounced save — the storage layer's debounce
    /// continues normally (Requirement 8.4 / 8.11).
    private func handlePanelClose() {
        panel?.popupState.popToRoot()
        logPopupActivation(action: "hide", source: "panelClose")
    }

    // MARK: - Verbose diagnostics

    /// Emit a structural diagnostics line gated on
    /// `enableVerboseDiagnostics`. Action and source are
    /// caller-controlled string literals — never user-supplied data
    /// (Requirements 19.4, 19.5).
    private func logPopupActivation(action: String, source: String) {
        guard AppContainer.shared.store.settings
            .resolvedEnableVerboseDiagnostics else { return }
        DiagnosticsLogger.shared.log(
            "BookmarkShelf popup \(action) #\(popupActivationSequence) source=\(source)"
        )
    }

    // MARK: - Public accessors

    /// Live storage handle exposed so menu builders and action handlers
    /// can read the current tree without binding to the `@Published`
    /// publisher. Returns `nil` when the controller is stopped.
    var storageHandle: BookmarkShelfStorage? { storage }
}
