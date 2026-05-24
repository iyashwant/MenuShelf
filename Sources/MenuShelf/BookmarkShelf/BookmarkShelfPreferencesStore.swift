//
//  BookmarkShelfPreferencesStore.swift
//  MenuShelf
//
//  Bookmark Shelf persistence operations on `PreferencesStore`. Mirrors
//  `ClipboardShelfPreferencesStore.swift`. The new fields on `AppSettings`
//  (`bookmarkShelf`) and on `MenuViewConfig` (`bookmarkShelfItem`,
//  `bookmarkContentItems`) live inline in `AppModels.swift`; the
//  manipulation API lives here.
//
//  The bookmark tree itself is NOT mutated through this file — that lives
//  in `BookmarkShelfStorage` and persists to a separate `bookmarks.json`
//  side file (Requirement 4.10 / 20.4). This file deals exclusively with
//  the settings-side shape (`BookmarkShelfSettings` and the per-menu-view
//  inline rows).
//

import Foundation

extension PreferencesStore {
    // MARK: - Top-level Bookmark Shelf settings (Task 5.1)

    /// Toggle Bookmark Shelf enabled/disabled. The settings observer in
    /// AppContainer routes this to `BookmarkShelfController.start/stop`,
    /// so the runtime storage handle and popup hotkey are torn up or down
    /// within 1 second (Requirement 7.6, 7.7).
    func setEnableBookmarkShelf(_ enabled: Bool) {
        updateBookmarkShelfSettings { $0.enableBookmarkShelf = enabled }
    }

    /// Apply an arbitrary mutation to `BookmarkShelfSettings`. Persists
    /// through the standard debounce-and-save path. Never calls
    /// `store.save()` directly (Requirement 5.9 / 20.4 / AGENTS.md
    /// "Settings updates").
    func updateBookmarkShelfSettings(_ update: (inout BookmarkShelfSettings) -> Void) {
        var current = settings.resolvedBookmarkShelf
        update(&current)
        settings.bookmarkShelf = current
    }

    // MARK: - Inline whole-shelf row (Task 5.2)

    /// Set the Bookmark Shelf inline whole-shelf entry on the target menu
    /// view (creating one if needed). No-ops if the menu view already has
    /// the entry. Auto-enables Bookmark Shelf when adding the first entry
    /// so the menu actually populates when opened (Requirement 9.10).
    func addBookmarkShelfItem(toMenuViewID menuViewID: UUID?) {
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
        guard views[index].bookmarkShelfItem == nil else {
            settings.menuViews = views
            return
        }

        views[index].bookmarkShelfItem = BookmarkShelfMenuItemConfig.make()
        views[index].updatedAt = Date()
        settings.menuViews = views
        selectedMenuViewID = targetID

        if !settings.resolvedBookmarkShelf.enableBookmarkShelf {
            // Auto-enable so the menu populates next time it opens.
            setEnableBookmarkShelf(true)
        }
    }

    /// Clear the Bookmark Shelf inline whole-shelf entry from a menu
    /// view. Used by the settings UI's content-list remove button.
    func removeBookmarkShelfItem(fromMenuViewID menuViewID: UUID) {
        var views = settings.resolvedMenuViews
        guard let index = views.firstIndex(where: { $0.id == menuViewID }) else { return }
        guard views[index].bookmarkShelfItem != nil else { return }

        views[index].bookmarkShelfItem = nil
        views[index].updatedAt = Date()
        settings.menuViews = views
    }

    // MARK: - Per-node content items (Task 5.3)

    /// Append a fresh `BookmarkContentItemConfig` referencing `nodeID`
    /// onto the named menu view's `bookmarkContentItems` array.
    /// Multiple entries pointing at the same `nodeID` are permitted
    /// (Requirement 10.10) — the helper does not deduplicate.
    /// Auto-enables Bookmark Shelf when adding the first entry, mirroring
    /// `addBookmarkShelfItem` behaviour.
    @discardableResult
    func addBookmarkContentItem(toMenuViewID menuViewID: UUID, nodeID: UUID) -> BookmarkContentItemConfig? {
        var views = settings.resolvedMenuViews
        guard let index = views.firstIndex(where: { $0.id == menuViewID }) else { return nil }

        var array = views[index].resolvedBookmarkContentItems
        let entry = BookmarkContentItemConfig.make(nodeID: nodeID)
        array.append(entry)
        views[index].bookmarkContentItems = array
        views[index].updatedAt = Date()
        settings.menuViews = views

        if !settings.resolvedBookmarkShelf.enableBookmarkShelf {
            setEnableBookmarkShelf(true)
        }

        return entry
    }

    /// Remove the named entry from the named menu view's
    /// `bookmarkContentItems` array. No-op when the menu view id or the
    /// entry id is absent.
    func removeBookmarkContentItem(fromMenuViewID menuViewID: UUID, contentItemID: UUID) {
        var views = settings.resolvedMenuViews
        guard let index = views.firstIndex(where: { $0.id == menuViewID }) else { return }

        var array = views[index].resolvedBookmarkContentItems
        guard array.contains(where: { $0.id == contentItemID }) else { return }
        array.removeAll { $0.id == contentItemID }
        views[index].bookmarkContentItems = array
        views[index].updatedAt = Date()
        settings.menuViews = views
    }

    /// Replace the matching entry by `id`, preserving the stored
    /// `createdAt` from the pre-state and bumping `updatedAt = Date()`.
    /// No-op when the menu view id or the entry id is absent.
    func updateBookmarkContentItem(inMenuViewID menuViewID: UUID, _ updated: BookmarkContentItemConfig) {
        var views = settings.resolvedMenuViews
        guard let viewIndex = views.firstIndex(where: { $0.id == menuViewID }) else { return }

        var array = views[viewIndex].resolvedBookmarkContentItems
        guard let entryIndex = array.firstIndex(where: { $0.id == updated.id }) else { return }

        var replacement = updated
        replacement.createdAt = array[entryIndex].createdAt
        replacement.updatedAt = Date()
        array[entryIndex] = replacement
        views[viewIndex].bookmarkContentItems = array
        views[viewIndex].updatedAt = Date()
        settings.menuViews = views
    }
}
