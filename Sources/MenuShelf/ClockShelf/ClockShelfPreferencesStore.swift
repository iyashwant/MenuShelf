//
//  ClockShelfPreferencesStore.swift
//  MenuShelf
//
//  Clock Shelf persistence operations on `PreferencesStore`. Mirrors
//  `ClipboardShelfPreferencesStore.swift`. The new fields on `AppSettings`
//  (`clockShelf`) and on `MenuViewConfig` (`clockShelfItem`) live inline
//  in `AppModels.swift`; the manipulation API lives here.
//

import Foundation

extension PreferencesStore {
    // MARK: - Menu view attachment

    /// Set the Clock Shelf entry on the target menu view (creating one if
    /// needed). No-ops when the menu view already has the entry.
    /// Auto-enables Clock Shelf when adding the first entry so the menu
    /// actually responds to clicks (Requirement 1.5).
    func addClockShelfItem(toMenuViewID menuViewID: UUID?) {
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
        guard views[index].clockShelfItem == nil else {
            settings.menuViews = views
            return
        }

        views[index].clockShelfItem = ClockShelfMenuItemConfig.make()
        views[index].updatedAt = Date()
        settings.menuViews = views
        selectedMenuViewID = targetID

        if !settings.resolvedClockShelf.enableClockShelf {
            // Auto-enable so the popover responds when the menu item is
            // clicked (Requirement 1.5).
            setEnableClockShelf(true)
        }
    }

    /// Clear the Clock Shelf entry from a menu view. Used by the settings
    /// UI's content-list remove button.
    func removeClockShelfItem(fromMenuViewID menuViewID: UUID) {
        var views = settings.resolvedMenuViews
        guard let index = views.firstIndex(where: { $0.id == menuViewID }) else { return }
        guard views[index].clockShelfItem != nil else { return }

        views[index].clockShelfItem = nil
        views[index].updatedAt = Date()
        settings.menuViews = views
    }

    // MARK: - Top-level settings

    /// Toggle the master enable flag for the Clock Shelf module. Routed
    /// through `updateClockShelfSettings(_:)` so a single mutation path
    /// owns the read-modify-write of `settings.clockShelf` (Requirement 8.9).
    func setEnableClockShelf(_ enabled: Bool) {
        updateClockShelfSettings { $0.enableClockShelf = enabled }
    }

    /// Apply a partial update to the persisted `ClockShelfSettings`.
    /// Reads the resolved value (so callers always see populated
    /// defaults), applies the closure, and writes the result back to
    /// `settings.clockShelf`. Persistence and menu rebuilds are handled
    /// by the existing debounce-and-save path on `PreferencesStore`
    /// (AGENTS.md §3 — never call `store.save()` directly).
    func updateClockShelfSettings(_ update: (inout ClockShelfSettings) -> Void) {
        var current = settings.resolvedClockShelf
        update(&current)
        settings.clockShelf = current
    }
}

extension PreferencesStore {
    // MARK: - Clock list

    /// Append a new clock for the given identifier. Validates against
    /// `TimeZone.knownTimeZoneIdentifiers` (Requirement 2.5) and enforces
    /// the 32-clock cap (Requirement 2.8). Returns the appended
    /// `ClockConfig` on success, or `nil` when the addition is rejected;
    /// the rejection is surfaced through `showError(_:)` so the user sees
    /// a non-blocking notice. Marked `@discardableResult` because the
    /// settings UI does not need the return value at every call site.
    @discardableResult
    func addClockShelf(timeZoneIdentifier: String) -> ClockConfig? {
        let trimmed = timeZoneIdentifier
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard TimeZone.knownTimeZoneIdentifiers.contains(trimmed) else {
            showError("\(trimmed) is not a recognized time zone.")
            return nil
        }

        var current = settings.resolvedClockShelf
        guard current.clocks.count < 32 else {
            showError("Clock Shelf supports up to 32 clocks.")
            return nil
        }

        let now = Date()
        let clock = ClockConfig(
            id: UUID(),
            timeZoneIdentifier: trimmed,
            label: nil,
            emoji: nil,
            pinToMenuBar: false,
            showInPopover: true,
            sortOrder: current.clocks.count,
            createdAt: now,
            updatedAt: now
        )
        current.clocks.append(clock)
        settings.clockShelf = current
        return clock
    }

    /// Remove the matching clock by `id` and renumber every surviving
    /// `sortOrder` so the sequence stays contiguous and zero-based
    /// (Requirement 2.7). No-op when no clock matches the id.
    func removeClockShelf(id: UUID) {
        var current = settings.resolvedClockShelf
        current.clocks.removeAll { $0.id == id }
        for newIndex in current.clocks.indices {
            current.clocks[newIndex].sortOrder = newIndex
        }
        settings.clockShelf = current
    }

    /// Reorder clocks in response to SwiftUI's `.onMove` callback. Sorts
    /// the array by `sortOrder` first so the incoming `IndexSet`/
    /// `toOffset` indices line up with what the UI displayed, applies
    /// `Array.move(fromOffsets:toOffset:)`, then renumbers `sortOrder`
    /// contiguously from zero (Requirement 2.6).
    func moveClockShelf(from source: IndexSet, to destination: Int) {
        var current = settings.resolvedClockShelf
        current.clocks.sort { $0.sortOrder < $1.sortOrder }
        current.clocks.move(fromOffsets: source, toOffset: destination)
        for newIndex in current.clocks.indices {
            current.clocks[newIndex].sortOrder = newIndex
        }
        settings.clockShelf = current
    }

    /// Apply an edit to an existing clock matched by `id`. `createdAt`
    /// and `sortOrder` are preserved from the pre-state regardless of
    /// what the caller passed in, and `updatedAt` is bumped to `Date()`
    /// (Requirement 2.9). No-op when no clock matches the id.
    func updateClockShelf(_ clock: ClockConfig) {
        var current = settings.resolvedClockShelf
        guard let index = current.clocks.firstIndex(where: { $0.id == clock.id }) else {
            return
        }
        var updated = clock
        updated.sortOrder = current.clocks[index].sortOrder
        updated.createdAt = current.clocks[index].createdAt
        updated.updatedAt = Date()
        current.clocks[index] = updated
        settings.clockShelf = current
    }
}
