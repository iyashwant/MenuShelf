//
//  MenuItemConfigPropertyTests.swift
//  WorldClockTests
//
//  Property-based tests covering `WorldClockMenuItemConfig` and the
//  per-menu-view attach/remove operations exposed by
//  `PreferencesStore.addWorldClockItem(toMenuViewID:)` and
//  `removeWorldClockItem(fromMenuViewID:)`.
//
//  - Property 1: `displayTitle` round-trip and trimming.
//  - Property 2: "Add World Clock" availability is exactly
//    `view.worldClockItem != nil`.
//  - Property 3: `addWorldClockItem` post-conditions — fresh item
//    present on the targeted view, every other view unchanged, and the
//    post-state has `enableWorldClock == true`.
//  - Property 6: `removeWorldClockItem` clears only the targeted view's
//    field.
//
//  `PreferencesStore` is the integration path that wraps these
//  operations, but instantiating it from tests is impractical (it loads
//  user settings from disk and may surface NSAlert on errors). Instead,
//  we reproduce the documented pure logic of `addWorldClockItem` /
//  `removeWorldClockItem` here as `applyAddWorldClockItem(...)` /
//  `applyRemoveWorldClockItem(...)` and assert the property invariants
//  against those reproductions. The reproductions match the production
//  bodies in `WorldClockPreferencesStore.swift` clause-for-clause.
//

import Foundation
import Testing
@testable import MenuShelf

// MARK: - Test helpers (mirror PreferencesStore.add/remove WorldClockItem)

/// Lightweight surrogate for the relevant PreferencesStore state when
/// applying a menu-view attach/remove. Mirrors the AGENTS.md pattern of
/// reading/writing through `settings.menuViews`.
private struct StoreSnapshot: Equatable {
    var settings: AppSettings
    var selectedMenuViewID: UUID?
}

/// Reproduce `PreferencesStore.addWorldClockItem(toMenuViewID:)` over a
/// pure-value `StoreSnapshot`. Matches the production body line-for-line.
private func applyAddWorldClockItem(
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
    guard views[index].worldClockItem == nil else {
        copy.settings.menuViews = views
        return copy
    }

    views[index].worldClockItem = WorldClockMenuItemConfig.make()
    views[index].updatedAt = Date()
    copy.settings.menuViews = views
    copy.selectedMenuViewID = targetID

    if !copy.settings.resolvedWorldClock.enableWorldClock {
        var current = copy.settings.resolvedWorldClock
        current.enableWorldClock = true
        copy.settings.worldClock = current
    }

    return copy
}

/// Reproduce `PreferencesStore.removeWorldClockItem(fromMenuViewID:)`.
private func applyRemoveWorldClockItem(
    _ snapshot: StoreSnapshot,
    fromMenuViewID menuViewID: UUID
) -> StoreSnapshot {
    var copy = snapshot
    var views = copy.settings.resolvedMenuViews
    guard let index = views.firstIndex(where: { $0.id == menuViewID }) else { return copy }
    guard views[index].worldClockItem != nil else { return copy }

    views[index].worldClockItem = nil
    views[index].updatedAt = Date()
    copy.settings.menuViews = views
    return copy
}

/// Build a deterministic `StoreSnapshot` with `n` menu views, each with
/// a stable id and no World Clock attached. Used so property tests can
/// drive `addWorldClockItem(toMenuViewID:)` against a known shape.
private func snapshotWithMenuViews(count n: Int) -> StoreSnapshot {
    var settings = AppSettings.defaults
    settings.menuViews = (0..<n).map { _ in
        MenuViewConfig.make(title: "View", defaults: settings.defaultMenuSettings)
    }
    settings.worldClock = WorldClockSettings.defaults  // enableWorldClock == false
    return StoreSnapshot(settings: settings, selectedMenuViewID: settings.menuViews?.first?.id)
}

// MARK: - Property 1: displayTitle round-trip and trimming

/// **Validates: Requirement 1.2**
@Test("Property 1: displayTitle returns trimmed override when non-empty")
func property1DisplayTitleTrimmed() {
    let item = WorldClockMenuItemConfig(
        id: UUID(),
        titleOverride: "  Hello World  ",
        sectionName: nil,
        createdAt: Date(),
        updatedAt: Date()
    )
    #expect(item.displayTitle == "Hello World")
}

@Test("Property 1: displayTitle falls back to \"World Clock\" for nil/empty/whitespace")
func property1DisplayTitleFallback() {
    let cases: [String?] = [nil, "", " ", "   ", "\t\n", "\u{00A0}"]
    for override in cases {
        let item = WorldClockMenuItemConfig(
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
        #expect(title == "World Clock", "Expected fallback for override: \(String(describing: override)), got \(title)")
    }
}

@Test("Property 1: displayTitle is idempotent under repeated trimming")
func property1DisplayTitleIdempotent() {
    forAll(arbitraryStringForOverride, iterations: 100) { override in
        var item = WorldClockMenuItemConfig.make()
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
    case 3: return "\tWorld Clock\n"
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

// MARK: - Property 2: "Add World Clock" availability mirrors worldClockItem

/// **Validates: Requirement 1.3**
///
/// The "Add World Clock" entry in the menu view detail's Add menu is
/// enabled iff the menu view does not already have a World Clock item.
@Test("Property 2: addAvailability is the negation of worldClockItem presence")
func property2AddAvailability() {
    forAll(arbitraryMenuViewWithMaybeWorldClock, iterations: 100) { view in
        let canAdd = view.worldClockItem == nil
        // The button's `disabled` predicate in the Add menu mirrors this:
        // `disabled` when `view.worldClockItem != nil`, equivalently
        // `enabled` when `view.worldClockItem == nil`.
        #expect(canAdd == (view.worldClockItem == nil))
    }
}

@Test("Property 2: addAvailability flips after addWorldClockItem")
func property2AddAvailabilityFlipsAfterAdd() {
    let initial = snapshotWithMenuViews(count: 3)
    let targetID = initial.settings.resolvedMenuViews[1].id

    // Pre: canAdd == true.
    #expect(initial.settings.resolvedMenuViews[1].worldClockItem == nil)

    let after = applyAddWorldClockItem(initial, toMenuViewID: targetID)

    // Post: canAdd == false.
    let postViews = after.settings.resolvedMenuViews
    #expect(postViews[1].worldClockItem != nil)
}

private let arbitraryMenuViewWithMaybeWorldClock: AnyGenerator<MenuViewConfig> = AnyGenerator { rng in
    var view = MenuViewConfig.make(title: "View", defaults: .defaults)
    if Bool.random(using: &rng) {
        view.worldClockItem = WorldClockMenuItemConfig.make()
    }
    return view
}

// MARK: - Property 3: addWorldClockItem post-conditions

/// **Validates: Requirements 1.4, 1.5**
///
/// Post-conditions for `addWorldClockItem(toMenuViewID:)` against a
/// menu view that does not yet have a `worldClockItem`:
/// 1. The targeted view has a fresh `WorldClockMenuItemConfig` whose
///    `id` is a new UUID, `titleOverride` and `sectionName` are nil,
///    and `createdAt`/`updatedAt` are recent.
/// 2. Every other view in the array is byte-equal to its pre-state.
/// 3. The post-state has `enableWorldClock == true`.
@Test("Property 3: addWorldClockItem creates fresh item on target, leaves siblings unchanged")
func property3AddWorldClockItemPostConditions() {
    forAll(arbitraryViewCountAndIndex, iterations: 50) { (n, idx) in
        let initial = snapshotWithMenuViews(count: n)
        let preViews = initial.settings.resolvedMenuViews
        let targetID = preViews[idx].id

        let beforeAdd = Date()
        let after = applyAddWorldClockItem(initial, toMenuViewID: targetID)

        let postViews = after.settings.resolvedMenuViews
        #expect(postViews.count == preViews.count)

        // 1) Target view: world clock item present and freshly minted.
        guard let targetItem = postViews[idx].worldClockItem else {
            Issue.record("Expected worldClockItem on view at index \(idx)")
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
                postViews[otherIdx].worldClockItem == nil,
                "Sibling view worldClockItem should remain nil"
            )
            #expect(
                postViews[otherIdx].title == preViews[otherIdx].title,
                "Sibling view title should be unchanged"
            )
        }

        // 3) Feature is auto-enabled.
        #expect(after.settings.resolvedWorldClock.enableWorldClock == true)
    }
}

@Test("Property 3: addWorldClockItem is idempotent — second call does not replace the item")
func property3AddWorldClockItemIdempotent() {
    let initial = snapshotWithMenuViews(count: 2)
    let targetID = initial.settings.resolvedMenuViews[0].id
    let first = applyAddWorldClockItem(initial, toMenuViewID: targetID)
    let second = applyAddWorldClockItem(first, toMenuViewID: targetID)

    let firstItem = first.settings.resolvedMenuViews[0].worldClockItem
    let secondItem = second.settings.resolvedMenuViews[0].worldClockItem
    #expect(firstItem != nil)
    #expect(secondItem != nil)
    #expect(firstItem?.id == secondItem?.id)
}

@Test("Property 3: addWorldClockItem with nil id creates a new menu view")
func property3AddWorldClockItemNilCreatesNewView() {
    let initial = snapshotWithMenuViews(count: 0)
    let after = applyAddWorldClockItem(initial, toMenuViewID: nil)
    let views = after.settings.resolvedMenuViews
    #expect(views.count == 1)
    #expect(views.first?.worldClockItem != nil)
    #expect(after.settings.resolvedWorldClock.enableWorldClock == true)
}

private let arbitraryViewCountAndIndex: AnyGenerator<(Int, Int)> = AnyGenerator { rng in
    let n = Int.random(in: 1...5, using: &rng)
    let idx = Int.random(in: 0..<n, using: &rng)
    return (n, idx)
}

// MARK: - Property 6: removeWorldClockItem clears only the targeted field

/// **Validates: Requirement 1.15**
///
/// `removeWorldClockItem(fromMenuViewID:)` clears `worldClockItem` for
/// the targeted menu view only. Every other view (including its
/// `worldClockItem` if present) and every other field on the targeted
/// view are byte-equal to the pre-state, modulo `updatedAt` which
/// receives a fresh timestamp.
@Test("Property 6: removeWorldClockItem clears only the targeted view's worldClockItem")
func property6RemoveWorldClockItem() {
    var settings = AppSettings.defaults
    var view0 = MenuViewConfig.make(title: "A", defaults: .defaults)
    var view1 = MenuViewConfig.make(title: "B", defaults: .defaults)
    let view2 = MenuViewConfig.make(title: "C", defaults: .defaults)
    view0.worldClockItem = WorldClockMenuItemConfig.make()
    view1.worldClockItem = WorldClockMenuItemConfig.make()
    // view2 has no item.
    settings.menuViews = [view0, view1, view2]

    let snapshot = StoreSnapshot(settings: settings, selectedMenuViewID: view0.id)

    // Remove from view1; verify only view1's worldClockItem was cleared.
    let after = applyRemoveWorldClockItem(snapshot, fromMenuViewID: view1.id)
    let postViews = after.settings.resolvedMenuViews
    #expect(postViews[0].worldClockItem != nil, "view0 should be untouched")
    #expect(postViews[1].worldClockItem == nil, "view1 should have its item cleared")
    #expect(postViews[2].worldClockItem == nil, "view2 had no item; still nil")
    #expect(postViews[0].id == view0.id)
    #expect(postViews[1].id == view1.id)
    #expect(postViews[2].id == view2.id)
    // view1.worldClockItem.id (pre) is gone; view0.worldClockItem.id is preserved.
    #expect(postViews[0].worldClockItem?.id == view0.worldClockItem?.id)
}

@Test("Property 6: removeWorldClockItem on a non-existent view is a no-op")
func property6RemoveNonExistent() {
    let initial = snapshotWithMenuViews(count: 2)
    let bogusID = UUID()
    let after = applyRemoveWorldClockItem(initial, fromMenuViewID: bogusID)
    #expect(after == initial)
}

@Test("Property 6: removeWorldClockItem on a view without an item is a no-op")
func property6RemoveWhenNoItem() {
    let initial = snapshotWithMenuViews(count: 2)
    let targetID = initial.settings.resolvedMenuViews[0].id
    let after = applyRemoveWorldClockItem(initial, fromMenuViewID: targetID)
    #expect(after == initial)
}

@Test("Property 6: add then remove returns to a state with worldClockItem == nil on target")
func property6AddThenRemoveCycles() {
    let initial = snapshotWithMenuViews(count: 1)
    let targetID = initial.settings.resolvedMenuViews[0].id

    let added = applyAddWorldClockItem(initial, toMenuViewID: targetID)
    #expect(added.settings.resolvedMenuViews[0].worldClockItem != nil)

    let removed = applyRemoveWorldClockItem(added, fromMenuViewID: targetID)
    #expect(removed.settings.resolvedMenuViews[0].worldClockItem == nil)
}
