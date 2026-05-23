//
//  ClipboardShelfPreferencesStore.swift
//  MenuShelf
//
//  Clipboard Shelf persistence operations on `PreferencesStore`. Mirrors
//  `BrowserFlipPreferencesStore.swift`. The new fields on `AppSettings`
//  (`clipboardShelf`) and on `MenuViewConfig` (`clipboardShelfItem`) live
//  inline in `AppModels.swift`; the manipulation API lives here.
//

import Foundation

extension PreferencesStore {
    /// Set the Clipboard Shelf entry on the target menu view (creating
    /// one if needed). No-ops if the menu view already has the entry.
    /// Auto-enables Clipboard Shelf when adding the first entry so the
    /// menu actually populates when opened (Requirement 1.5).
    func addClipboardShelfItem(toMenuViewID menuViewID: UUID?) {
        var views = settings.resolvedMenuViews
        let targetID: UUID

        if let menuViewID, views.contains(where: { $0.id == menuViewID }) {
            targetID = menuViewID
        } else {
            let view = MenuViewConfig.make(title: "MenuShelf", defaults: settings.defaultMenuSettings)
            views.append(view)
            targetID = view.id
            selectedMenuViewID = targetID
        }

        guard let index = views.firstIndex(where: { $0.id == targetID }) else { return }
        guard views[index].clipboardShelfItem == nil else {
            settings.menuViews = views
            return
        }

        views[index].clipboardShelfItem = ClipboardShelfMenuItemConfig.make()
        views[index].updatedAt = Date()
        settings.menuViews = views
        selectedMenuViewID = targetID

        if !settings.resolvedClipboardShelf.enableClipboardShelf {
            // Auto-enable so the menu populates next time it opens.
            setEnableClipboardShelf(true)
        }
    }

    /// Clear the Clipboard Shelf entry from a menu view. Used by the
    /// settings UI's content-list remove button.
    func removeClipboardShelfItem(fromMenuViewID menuViewID: UUID) {
        var views = settings.resolvedMenuViews
        guard let index = views.firstIndex(where: { $0.id == menuViewID }) else { return }
        guard views[index].clipboardShelfItem != nil else { return }

        views[index].clipboardShelfItem = nil
        views[index].updatedAt = Date()
        settings.menuViews = views
    }

    /// Toggle Clipboard Shelf enabled/disabled. The settings observer in
    /// AppContainer routes this to `ClipboardShelfController.start/stop`,
    /// so the runtime monitor and popup hotkey are torn up or down within
    /// 1 second (Requirements 2.2, 7.9).
    func setEnableClipboardShelf(_ enabled: Bool) {
        updateClipboardShelfSettings { $0.enableClipboardShelf = enabled }
    }

    /// Apply an arbitrary mutation to `ClipboardShelfSettings`. Persists
    /// through the standard debounce-and-save path. The settings observer
    /// in AppContainer mirrors the new value into the vendored Defaults
    /// keys via `ClipboardShelfController.apply(settings:)`.
    func updateClipboardShelfSettings(_ update: (inout ClipboardShelfSettings) -> Void) {
        var current = settings.resolvedClipboardShelf
        update(&current)
        settings.clipboardShelf = current
    }

    /// Clear the Clipboard Shelf history. `includingPinned == true` removes
    /// pinned items as well; otherwise pinned items are preserved
    /// (Requirement 6.6).
    @MainActor
    func clearClipboardShelfHistory(includingPinned: Bool) {
        ClipboardShelfController.shared.clearHistory(includingPinned: includingPinned)
    }
}
