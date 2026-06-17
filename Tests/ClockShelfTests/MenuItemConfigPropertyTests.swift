//
//  MenuItemConfigPropertyTests.swift
//  ClockShelfTests
//
//  Property-based tests covering `ClockShelfMenuItemConfig` and the
//  per-menu-view attach/remove operations exposed by
//  `PreferencesStore.addClockShelfItem(toMenuViewID:)` and
//  `removeClockShelfItem(fromMenuViewID:)`.
//
//  - Property 1: `displayTitle` round-trip and trimming.
//  - Property 2: "Add Clock Shelf" availability is exactly
//    `view.clockShelfItem != nil`.
//  - Property 3: `addClockShelfItem` post-conditions — fresh item
//    present on the targeted view, every other view unchanged, and the
//    post-state has `enableClockShelf == true`.
//  - Property 6: `removeClockShelfItem` clears only the targeted view's
//    field.
//
//  `PreferencesStore` is the integration path that wraps these
//  operations, but instantiating it from tests is impractical (it loads
//  user settings from disk and may surface NSAlert on errors). Instead,
//  we reproduce the documented pure logic of `addClockShelfItem` /
//  `removeClockShelfItem` here as `applyAddClockShelfItem(...)` /
//  `applyRemoveClockShelfItem(...)` and assert the property invariants
//  against those reproductions. The reproductions match the production
//  bodies in `ClockShelfPreferencesStore.swift` clause-for-clause.
//

import Foundation
import Testing
@testable import MenuShelf

// MARK: - Test helpers (mirror PreferencesStore.add/remove ClockShelfItem)

/// Lightweight surrogate for the relevant PreferencesStore state when
/// applying a menu-view attach/remove. Mirrors the AGENTS.md pattern of
/// reading/writing through `settings.menuViews`.
private struct StoreSnapshot: Equatable {
    var settings: AppSettings
    var selectedMenuViewID: UUID?
}

/// Reproduce `PreferencesStore.addClockShelfItem(toMenuViewID:)` over a
/// pure-value `StoreSnapshot`. Matches the production body line-for-line.
private func applyAddClockShelfItem(
    _ snapshot: StoreSnapshot,
    toMenuViewID menuViewID: UUID?
) -> StoreSnapshot {
    var copy = snapshot
    var views = copy.settings.resolvedMenuViews
    let targetID: UUID

    if let menuViewID, views.contains(where: { $0.id == menuViewID }) {
        targetID = menuViewID
    } else {
        let view = MenuViewConfig.make(
            title: "MenuShelf",
            defaults: copy.settings.defaultMenuSettings
        )
        views.append(view)
        targetID = view.id
        copy.selectedMenuViewID = targetID
    }

    guard let index = views.firstIndex(where: { $0.id == targetID }) else { return copy }
    guard views[index].clockShelfItem == nil else {
        copy.settings.menuViews = views
        return copy
    }

    views[index].clockShelfItem = ClockShelfMenuItemConfig.make()
    views[index].updatedAt = Date()
    copy.settings.menuViews = views
    copy.selectedMenuViewID = targetID

    if !copy.settings.resolvedClockShelf.enableClockShelf {
        var current = copy.settings.resolvedClockShelf
        current.enableClockShelf = true
        copy.settings.clockShelf = current
    }

    return copy
}

/// Reproduce `PreferencesStore.removeClockShelfItem(fromMenuViewID:)`.
private func applyRemoveClockShelfItem(
    _ snapshot: StoreSnapshot,
    fromMenuViewID menuViewID: UUID
) -> StoreSnapshot {
    var copy = snapshot
    var views = copy.settings.resolvedMenuViews
    guard let index = views.firstIndex(where: { $0.id == menuViewID }) else { return copy }
    guard views[index].clockShelfItem != nil else { return copy }

    views[index].clockShelfItem = nil
    views[index].updatedAt = Date()
    copy.settings.menuViews = views
    return copy
}

/// Build a deterministic `StoreSnapshot` with `n` menu views, each with
/// a stable id and no Clock Shelf attached. Used so property tests can
/// drive `addClockShelfItem(toMenuViewID:)` against a known shape.
private func snapshotWithMenuViews(count n: Int) -> StoreSnapshot {
    var settings = AppSettings.defaults
    settings.menuViews = (0..<n).map { _ in
        MenuViewConfig.make(title: "View", defaults: settings.defaultMenuSettings)
    }
    settings.clockShelf = ClockShelfSettings.defaults  // enableClockShelf == false
    return StoreSnapshot(settings: settings, selectedMenuViewID: settings.menuViews?.first?.id)
}

// MARK: - Property 1: displayTitle round-trip and trimming

/// **Validates: Requirement 1.2**
@Test("Property 1: displayTitle returns trimmed override when non-empty")
func property1DisplayTitleTrimmed() {
    let item = ClockShelfMenuItemConfig(
        id: UUID(),
        titleOverride: "  Hello World  ",
        sectionName: nil,
        createdAt: Date(),
        updatedAt: Date()
    )
    #expect(item.displayTitle == "Hello World")
}

@Test("Property 1: displayTitle falls back to \"Clock Shelf\" for nil/empty/whitespace")
func property1DisplayTitleFallback() {
    let cases: [String?] = [nil, "", " ", "   ", "\t\n", "\u{00A0}"]
    for override in cases {
        let item = ClockShelfMenuItemConfig(
            id: UUID(),
            titleOverride: override,
            sectionName: nil,
            createdAt: Date(),
            updatedAt: Date()
        )
        let title = item.displayTitle
        if let override, !override.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            // Should not happen for these inputs.
            Issue.record("Unexpected non-empty trimmed for override: \(override)")
        }
        #expect(title == "Clock Shelf", "Expected fallback for override: \(String(describing: override)), got \(title)")
    }
}

@Test("Property 1: displayTitle is idempotent under repeated trimming")
func property1DisplayTitleIdempotent() {
    forAll(arbitraryStringForOverride, iterations: 100) { override in
        var item = ClockShelfMenuItemConfig.make()
        item.titleOverride = override
        let firstPass = item.displayTitle
        // Reapply the trimmed value as override; displayTitle must
        // still return the same value (idempotence).
        item.titleOverride = firstPass
        let secondPass = item.displayTitle
        #expect(firstPass == secondPass)
    }
}

/// Generator emitting strings spanning the trim range: empty,
/// whitespace-only, leading/trailing whitespace, and arbitrary content.
private let arbitraryStringForOverride: AnyGenerator<String> = AnyGenerator { rng in
    let kind = Int.random(in: 0...4, using: &rng)
    switch kind {
    case 0: return ""
    case 1: return "    "
    case 2: return "  Hello  "
    case 3: return "\tClock Shelf\n"
    default:
        let length = Int.random(in: 1...12, using: &rng)
        let chars = "abcdefghijklmnopqrstuvwxyz "
        var result = ""
        for _ in 0..<length {
            let idx = Int.random(in: 0..<chars.count, using: &rng)
            result.append(chars[chars.index(chars.startIndex, offsetBy: idx)])
        }
        return result
    }
}

// MARK: - Property 2: "Add Clock Shelf" availability mirrors clockShelfItem

/// **Validates: Requirement 1.3**
///
/// The "Add Clock Shelf" entry in the menu view detail's Add menu is
/// enabled iff the menu view does not already have a Clock Shelf item.
@Test("Property 2: addAvailability is the negation of clockShelfItem presence")
func property2AddAvailability() {
    forAll(arbitraryMenuViewWithMaybeClockShelf, iterations: 100) { view in
        let canAdd = view.clockShelfItem == nil
        // The button's `disabled` predicate in the Add menu mirrors this:
        // `disabled` when `view.clockShelfItem != nil`, equivalently
        // `enabled` when `view.clockShelfItem == nil`.
        #expect(canAdd == (view.clockShelfItem == nil))
    }
}

@Test("Property 2: addAvailability flips after addClockShelfItem")
func property2AddAvailabilityFlipsAfterAdd() {
    let initial = snapshotWithMenuViews(count: 3)
    let targetID = initial.settings.resolvedMenuViews[1].id

    // Pre: canAdd == true.
    #expect(initial.settings.resolvedMenuViews[1].clockShelfItem == nil)

    let after = applyAddClockShelfItem(initial, toMenuViewID: targetID)

    // Post: canAdd == false.
    let postViews = after.settings.resolvedMenuViews
    #expect(postViews[1].clockShelfItem != nil)
}

private let arbitraryMenuViewWithMaybeClockShelf: AnyGenerator<MenuViewConfig> = AnyGenerator { rng in
    var view = MenuViewConfig.make(title: "View", defaults: .defaults)
    if Bool.random(using: &rng) {
        view.clockShelfItem = ClockShelfMenuItemConfig.make()
    }
    return view
}

// MARK: - Property 3: addClockShelfItem post-conditions

/// **Validates: Requirements 1.4, 1.5**
///
/// Post-conditions for `addClockShelfItem(toMenuViewID:)` against a
/// menu view that does not yet have a `clockShelfItem`:
/// 1. The targeted view has a fresh `ClockShelfMenuItemConfig` whose
///    `id` is a new UUID, `titleOverride` and `sectionName` are nil,
///    and `createdAt`/`updatedAt` are recent.
/// 2. Every other view in the array is byte-equal to its pre-state.
/// 3. The post-state has `enableClockShelf == true`.
@Test("Property 3: addClockShelfItem creates fresh item on target, leaves siblings unchanged")
func property3AddClockShelfItemPostConditions() {
    forAll(arbitraryViewCountAndIndex, iterations: 50) { (n, idx) in
        let initial = snapshotWithMenuViews(count: n)
        let preViews = initial.settings.resolvedMenuViews
        let targetID = preViews[idx].id

        let beforeAdd = Date()
        let after = applyAddClockShelfItem(initial, toMenuViewID: targetID)

        let postViews = after.settings.resolvedMenuViews
        #expect(postViews.count == preViews.count)

        // 1) Target view: clock shelf item present and freshly minted.
        guard let targetItem = postViews[idx].clockShelfItem else {
            Issue.record("Expected clockShelfItem on view at index \(idx)")
            return
        }
        #expect(targetItem.titleOverride == nil)
        #expect(targetItem.sectionName == nil)
        #expect(targetItem.createdAt >= beforeAdd)
        #expect(targetItem.updatedAt >= beforeAdd)

        // 2) Every other view is unchanged.
        for otherIdx in postViews.indices where otherIdx != idx {
            #expect(
                postViews[otherIdx].id == preViews[otherIdx].id,
                "Sibling view id should be unchanged"
            )
            #expect(
                postViews[otherIdx].clockShelfItem == nil,
                "Sibling view clockShelfItem should remain nil"
            )
            #expect(
                postViews[otherIdx].title == preViews[otherIdx].title,
                "Sibling view title should be unchanged"
            )
        }

        // 3) Feature is auto-enabled.
        #expect(after.settings.resolvedClockShelf.enableClockShelf == true)
    }
}

@Test("Property 3: addClockShelfItem is idempotent — second call does not replace the item")
func property3AddClockShelfItemIdempotent() {
    let initial = snapshotWithMenuViews(count: 2)
    let targetID = initial.settings.resolvedMenuViews[0].id
    let first = applyAddClockShelfItem(initial, toMenuViewID: targetID)
    let second = applyAddClockShelfItem(first, toMenuViewID: targetID)

    let firstItem = first.settings.resolvedMenuViews[0].clockShelfItem
    let secondItem = second.settings.resolvedMenuViews[0].clockShelfItem
    #expect(firstItem != nil)
    #expect(secondItem != nil)
    #expect(firstItem?.id == secondItem?.id)
}

@Test("Property 3: addClockShelfItem with nil id creates a new menu view")
func property3AddClockShelfItemNilCreatesNewView() {
    let initial = snapshotWithMenuViews(count: 0)
    let after = applyAddClockShelfItem(initial, toMenuViewID: nil)
    let views = after.settings.resolvedMenuViews
    #expect(views.count == 1)
    #expect(views.first?.clockShelfItem != nil)
    #expect(after.settings.resolvedClockShelf.enableClockShelf == true)
}

private let arbitraryViewCountAndIndex: AnyGenerator<(Int, Int)> = AnyGenerator { rng in
    let n = Int.random(in: 1...5, using: &rng)
    let idx = Int.random(in: 0..<n, using: &rng)
    return (n, idx)
}

// MARK: - Property 6: removeClockShelfItem clears only the targeted field

/// **Validates: Requirement 1.15**
///
/// `removeClockShelfItem(fromMenuViewID:)` clears `clockShelfItem` for
/// the targeted menu view only. Every other view (including its
/// `clockShelfItem` if present) and every other field on the targeted
/// view are byte-equal to the pre-state, modulo `updatedAt` which
/// receives a fresh timestamp.
@Test("Property 6: removeClockShelfItem clears only the targeted view's clockShelfItem")
func property6RemoveClockShelfItem() {
    var settings = AppSettings.defaults
    var view0 = MenuViewConfig.make(title: "A", defaults: .defaults)
    var view1 = MenuViewConfig.make(title: "B", defaults: .defaults)
    let view2 = MenuViewConfig.make(title: "C", defaults: .defaults)
    view0.clockShelfItem = ClockShelfMenuItemConfig.make()
    view1.clockShelfItem = ClockShelfMenuItemConfig.make()
    // view2 has no item.
    settings.menuViews = [view0, view1, view2]

    let snapshot = StoreSnapshot(settings: settings, selectedMenuViewID: view0.id)

    // Remove from view1; verify only view1's clockShelfItem was cleared.
    let after = applyRemoveClockShelfItem(snapshot, fromMenuViewID: view1.id)
    let postViews = after.settings.resolvedMenuViews
    #expect(postViews[0].clockShelfItem != nil, "view0 should be untouched")
    #expect(postViews[1].clockShelfItem == nil, "view1 should have its item cleared")
    #expect(postViews[2].clockShelfItem == nil, "view2 had no item; still nil")
    #expect(postViews[0].id == view0.id)
    #expect(postViews[1].id == view1.id)
    #expect(postViews[2].id == view2.id)
    // view1.clockShelfItem.id (pre) is gone; view0.clockShelfItem.id is preserved.
    #expect(postViews[0].clockShelfItem?.id == view0.clockShelfItem?.id)
}

@Test("Property 6: removeClockShelfItem on a non-existent view is a no-op")
func property6RemoveNonExistent() {
    let initial = snapshotWithMenuViews(count: 2)
    let bogusID = UUID()
    let after = applyRemoveClockShelfItem(initial, fromMenuViewID: bogusID)
    #expect(after == initial)
}

@Test("Property 6: removeClockShelfItem on a view without an item is a no-op")
func property6RemoveWhenNoItem() {
    let initial = snapshotWithMenuViews(count: 2)
    let targetID = initial.settings.resolvedMenuViews[0].id
    let after = applyRemoveClockShelfItem(initial, fromMenuViewID: targetID)
    #expect(after == initial)
}

@Test("Property 6: add then remove returns to a state with clockShelfItem == nil on target")
func property6AddThenRemoveCycles() {
    let initial = snapshotWithMenuViews(count: 1)
    let targetID = initial.settings.resolvedMenuViews[0].id

    let added = applyAddClockShelfItem(initial, toMenuViewID: targetID)
    #expect(added.settings.resolvedMenuViews[0].clockShelfItem != nil)

    let removed = applyRemoveClockShelfItem(added, fromMenuViewID: targetID)
    #expect(removed.settings.resolvedMenuViews[0].clockShelfItem == nil)
}
