//
//  CaffeineShelfPreferencesStore.swift
//  MenuShelf
//
//  CaffeineShelf persistence operations on `PreferencesStore`. Mirrors
//  `ClockShelfPreferencesStore.swift`. The hook field on `AppSettings`
//  (`caffeineShelf`) lives inline in `AppModels.swift`; the manipulation API
//  lives here. Adding/removing the standalone menu-bar icon is handled by the
//  generic `addStandaloneModule(kind:)` / `removeStandaloneModule(id:)`.
//

import Foundation

extension PreferencesStore {
    /// Toggle the master enable flag for the CaffeineShelf module. Routed
    /// through `updateCaffeineShelfSettings(_:)` so a single mutation path owns
    /// the read-modify-write of `settings.caffeineShelf`.
    func setEnableCaffeineShelf(_ enabled: Bool) {
        updateCaffeineShelfSettings { $0.enableCaffeineShelf = enabled }
    }

    /// Set the CaffeineShelf entry on the target menu view (creating one if
    /// needed). No-ops if the menu view already has the entry. Auto-enables
    /// CaffeineShelf when adding the first entry so the menu actually
    /// populates when opened.
    func addCaffeineShelfItem(toMenuViewID menuViewID: UUID?) {
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
        guard views[index].caffeineShelfItem == nil else {
            settings.menuViews = views
            return
        }

        views[index].caffeineShelfItem = CaffeineShelfMenuItemConfig.make()
        views[index].updatedAt = Date()
        settings.menuViews = views
        selectedMenuViewID = targetID

        if !settings.resolvedCaffeineShelf.enableCaffeineShelf {
            setEnableCaffeineShelf(true)
        }
    }

    /// Clear the CaffeineShelf entry from a menu view. Used by the settings
    /// UI's content-list remove button.
    func removeCaffeineShelfItem(fromMenuViewID menuViewID: UUID) {
        var views = settings.resolvedMenuViews
        guard let index = views.firstIndex(where: { $0.id == menuViewID }) else { return }
        guard views[index].caffeineShelfItem != nil else { return }

        views[index].caffeineShelfItem = nil
        views[index].updatedAt = Date()
        settings.menuViews = views
    }

    /// Toggle whether keep-awake also covers the lid being closed. The
    /// controller orchestrates the privileged grant; this only persists the
    /// flag.
    func setKeepAwakeWithLidClosed(_ on: Bool) {
        updateCaffeineShelfSettings { $0.keepAwakeWithLidClosed = on }
    }

    /// Apply a partial update to the persisted `CaffeineShelfSettings`. Reads
    /// the resolved value (so callers always see populated defaults), applies
    /// the closure, and writes the result back. Persistence is handled by the
    /// existing debounce-and-save path on `PreferencesStore` (never call
    /// `store.save()` directly).
    func updateCaffeineShelfSettings(_ update: (inout CaffeineShelfSettings) -> Void) {
        var current = settings.resolvedCaffeineShelf
        update(&current)
        settings.caffeineShelf = current
    }
}
