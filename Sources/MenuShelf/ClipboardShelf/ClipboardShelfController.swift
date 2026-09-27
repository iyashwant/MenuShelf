//
//  ClipboardShelfController.swift
//  MenuShelf
//
//  Single integration seam between MenuShelf and the vendored Maccy core.
//  Owns the floating popup, the pasteboard monitor lifecycle, the SwiftData
//  container handle (via `ClipboardShelfStorage`), and the global popup
//  hotkey registration. Everything outside `Sources/MenuShelf/ClipboardShelf/`
//  talks to this controller and nothing else from `Vendor/`.
//

import AppKit
import Defaults
import Foundation
import KeyboardShortcuts
import SwiftUI

@MainActor
final class ClipboardShelfController {
    static let shared = ClipboardShelfController()

    private init() {}

    private var panel: FloatingPanel<ClipboardShelfContentView>?
    private var storage: ClipboardShelfStorage?
    private var isRunning = false
    private var didReportLoadFailure = false
    private var lastAppliedSettings: ClipboardShelfSettings?
    private var didShowAccessibilityNotice = false
    private var popupActivationSequence: Int = 0

    /// Idempotent. Builds the SwiftData container, the pasteboard monitor,
    /// the floating popup, and registers `KeyboardShortcuts.Name.popup`
    /// when called for the first time. Subsequent calls only push the new
    /// settings through `apply(settings:)`.
    func start(with settings: ClipboardShelfSettings) {
        guard settings.enableClipboardShelf else { return }

        guard !isRunning else {
            apply(settings: settings)
            return
        }

        // 1. Open the SwiftData container. Surface a one-time error if the
        // file is missing or unreadable, but keep launching: the vendored
        // Storage falls back to in-memory so the rest of MenuShelf still
        // works (Requirement 3.8).
        do {
            storage = try ClipboardShelfStorage()
        } catch {
            if !didReportLoadFailure {
                didReportLoadFailure = true
                AppContainer.shared.store.showError(error.localizedDescription)
                DiagnosticsLogger.shared.log("Clipboard Shelf storage open failed: \(error.localizedDescription)")
            }
            // Keep going on the in-memory fallback — the user can still see
            // and pin clips for the current session.
            storage = nil
        }

        // 2. Mirror canonical MenuShelf settings into the vendored Defaults
        // keys before the monitor or popup state-machine reads them.
        mirrorToDefaults(settings)
        lastAppliedSettings = settings

        // 3. Wire the pasteboard monitor → history append hook and start it.
        // Capture-event diagnostics are emitted from the same hook so we can
        // log only sanitized metadata (no clipboard payload — Requirement
        // 12.3 / Property 4).
        Clipboard.shared.onNewCopy { item in
            let bundleID = item.application ?? "unknown"
            let typeCount = item.contents.count
            let totalBytes = item.contents.reduce(0) { acc, content in
                acc + (content.value?.count ?? 0)
            }
            DiagnosticsLogger.shared.log(
                "ClipboardShelf captured: app=\(bundleID) types=\(typeCount) bytes=\(totalBytes)"
            )
            History.shared.add(item)
        }
        Clipboard.shared.start()

        // 4. Build the floating popup.
        let panel = FloatingPanel<ClipboardShelfContentView>(
            contentRect: NSRect(origin: .zero, size: settings.popupSize),
            identifier: (Bundle.main.bundleIdentifier ?? "app.menushelf.MenuShelf") + ".clipboardShelf",
            statusBarButton: nil,
            onClose: {
                ClipboardShelfState.shared.popup.reset()
            }
        ) {
            ClipboardShelfContentView()
        }
        ClipboardShelfState.shared.panel = panel
        ClipboardShelfState.shared.openPreferencesHandler = {
            AppContainer.shared.settingsWindowController.show(focusClipboardShelf: true)
        }
        self.panel = panel

        // 5. Register the popup hotkey. Keep the secondary delete/pin hotkeys
        // disabled per Requirement 9.4.
        KeyboardShortcuts.onKeyDown(for: .popup) { [weak self] in
            self?.togglePopup(anchor: nil)
        }
        KeyboardShortcuts.disable([.delete, .pin])

        // 6. Show recent images from the screenshot folders, if turned on.
        ClipboardShelfScreenshots.shared.configure(with: settings)

        DiagnosticsLogger.shared.log("Clipboard Shelf started (interval=\(settings.clipboardCheckInterval)s, size=\(settings.size))")
        isRunning = true
    }

    /// Idempotent. Stops the pasteboard monitor, hides the popup, releases
    /// the storage handle, and disables the popup hotkey.
    func stop() {
        guard isRunning else { return }
        isRunning = false

        Clipboard.shared.clearHooks()
        Clipboard.shared.stop()
        ClipboardShelfScreenshots.shared.stop()

        panel?.close()
        ClipboardShelfState.shared.panel = nil
        panel = nil

        KeyboardShortcuts.disable(.popup)

        storage = nil
        lastAppliedSettings = nil
        DiagnosticsLogger.shared.log("Clipboard Shelf stopped")
    }

    /// Push canonical settings into the vendored layer. Called whenever
    /// `AppSettings.clipboardShelf` changes. Cheap to call repeatedly.
    func apply(settings: ClipboardShelfSettings) {
        if !settings.enableClipboardShelf {
            stop()
            return
        }

        if !isRunning {
            start(with: settings)
            return
        }

        let previous = lastAppliedSettings
        mirrorToDefaults(settings)

        // Restart the polling timer if the interval changed so the new
        // value takes effect (Requirement 2.2).
        if previous?.clipboardCheckInterval != settings.clipboardCheckInterval {
            Clipboard.shared.restart()
        }

        ClipboardShelfScreenshots.shared.configure(with: settings)
        lastAppliedSettings = settings
    }

    /// Toggle the popup visibility. `anchor` is the originating status item
    /// button when invoked from a menu click; nil when triggered by hotkey
    /// (in which case popup uses the configured `popupPosition`).
    func togglePopup(anchor: NSStatusBarButton?) {
        guard let panel else { return }
        if anchor != nil {
            panel.statusBarButton = anchor
        }
        let height = ClipboardShelfState.shared.popup.height
        let position: PopupPosition = (anchor != nil) ? .statusItem : Defaults[.popupPosition]
        let wasPresented = panel.isPresented
        panel.toggle(height: height, at: position)
        logPopupActivation(action: wasPresented ? "hide" : "show",
                           source: anchor != nil ? "menuClick" : "globalHotkey")
    }

    /// Show the popup unconditionally (no toggle). Used by the menu action
    /// when the click should always open the popup.
    func showPopup(anchor: NSStatusBarButton?) {
        guard let panel else { return }
        if anchor != nil {
            panel.statusBarButton = anchor
        }
        let height = ClipboardShelfState.shared.popup.height
        let position: PopupPosition = (anchor != nil) ? .statusItem : Defaults[.popupPosition]
        panel.open(height: height, at: position)
        logPopupActivation(action: "show",
                           source: anchor != nil ? "menuClick" : "globalHotkey")
    }

    /// Clear non-pinned (and optionally pinned) history items via the
    /// vendored `History` API. Called from the settings pane's
    /// "Clear History…" button.
    func clearHistory(includingPinned: Bool) {
        if includingPinned {
            History.shared.clearAll()
        } else {
            History.shared.clear()
        }
    }

    /// Invoked from the vendored `Accessibility.check()` when AX trust is
    /// not granted. Shows a one-time guidance alert that opens
    /// System Settings → Privacy & Security → Accessibility, then
    /// suppresses further alerts for the rest of the session
    /// (Requirement 10.3, 10.4).
    func handleAccessibilityDenial() {
        DiagnosticsLogger.shared.log(
            "ClipboardShelf paste failed: Accessibility permission not granted; falling back to copy-only."
        )
        guard !didShowAccessibilityNotice else { return }
        didShowAccessibilityNotice = true

        let alert = NSAlert()
        alert.messageText = "Accessibility Permission Required to Paste"
        alert.informativeText = """
        Clipboard Shelf needs Accessibility access to paste into the previously focused app. Without it, activating an item only copies the content to the system clipboard.

        Grant access in System Settings → Privacy & Security → Accessibility, then quit and relaunch MenuShelf.
        """
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Cancel")

        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                NSWorkspace.shared.open(url)
            }
        }
    }

    // MARK: - Private

    private func logPopupActivation(action: String, source: String) {
        guard store.settings.resolvedEnableVerboseDiagnostics else { return }
        popupActivationSequence += 1
        DiagnosticsLogger.shared.log(
            "ClipboardShelf popup \(action) #\(popupActivationSequence) source=\(source)"
        )
    }

    private var store: PreferencesStore { AppContainer.shared.store }

    /// Mirror the canonical `ClipboardShelfSettings` into the vendored
    /// `Defaults[...]` keys so the vendored core observes changes through
    /// its existing `Defaults.updates(...)` streams (design Property 8).
    private func mirrorToDefaults(_ settings: ClipboardShelfSettings) {
        Defaults[.clipboardCheckInterval] = settings.clipboardCheckInterval
        Defaults[.size] = settings.size
        Defaults[.pasteByDefault] = settings.pasteByDefault
        Defaults[.removeFormattingByDefault] = settings.removeFormattingByDefault
        Defaults[.clearOnQuit] = settings.clearOnQuit
        Defaults[.ignoreEvents] = settings.ignoreEvents
        Defaults[.ignoreOnlyNextEvent] = settings.ignoreOnlyNextEvent
        Defaults[.ignoredApps] = settings.ignoredApplicationBundleIDs
        Defaults[.ignoreRegexp] = settings.ignoredRegularExpressions
        Defaults[.windowSize] = settings.popupSize
        Defaults[.pinTo] = mapPinPosition(settings.pinTo)
        Defaults[.popupPosition] = mapPopupPosition(settings.popupPosition)
        Defaults[.searchMode] = mapSearchMode(settings.searchMode)
        Defaults[.sortBy] = mapSortKey(settings.sortBy)
        Defaults[.enabledPasteboardTypes] = Set(
            settings.enabledPasteboardTypes.map { NSPasteboard.PasteboardType($0) }
        )
    }

    private func mapSortKey(_ key: ClipboardShelfSortKey) -> Sorter.By {
        switch key {
        case .firstCopiedAt: .firstCopiedAt
        case .lastCopiedAt: .lastCopiedAt
        case .numberOfCopies: .numberOfCopies
        }
    }

    private func mapSearchMode(_ mode: ClipboardShelfSearchMode) -> Search.Mode {
        switch mode {
        case .exact: .exact
        case .fuzzy: .fuzzy
        case .regularExpression: .regexp
        }
    }

    private func mapPinPosition(_ position: ClipboardShelfPinPosition) -> PinsPosition {
        switch position {
        case .top: .top
        case .bottom: .bottom
        }
    }

    private func mapPopupPosition(_ position: ClipboardShelfPopupPosition) -> PopupPosition {
        switch position {
        case .statusItem: .statusItem
        case .cursor: .cursor
        case .screenCenter: .center
        case .lastPosition: .lastPosition
        }
    }
}
