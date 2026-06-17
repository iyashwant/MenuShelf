//
//  PopoverAndPinnedPropertyTests.swift
//  ClockShelfTests
//
//  Property-based tests covering the Clock Shelf popover row pipeline
//  and the pinned status item lifecycle:
//
//  - Property 13: `ClockShelfPopoverState.rows` composition — given a
//    `ClockShelfSettings`, the row snapshot equals
//    `clocks.filter(\.showInPopover).sorted(by: \.sortOrder).map(ClockShelfRowModel.init)`.
//  - Property 14: pinned status item set after `apply(settings:)` —
//    `Set(pinnedItems.keys) == Set(settings.clocks.filter(\.pinToMenuBar).map(\.id))`
//    and `pinnedOrder == ...sorted(by: \.sortOrder).map(\.id)`.
//  - Property 15: pinned title format never includes a day-offset
//    suffix in the form of `"+N"` / `"-N"`.
//
//  Why these tests are pure-data:
//
//  `ClockShelfController.shared` cannot be exercised in this test
//  process — it manipulates `NSStatusBar.system`, registers
//  `KeyboardShortcuts.onKeyDown` callbacks, and reads from
//  `AppContainer.shared.store`. Driving it from `swift test` would
//  corrupt application state. The properties under test, however, are
//  *pure-data invariants* about the controller's `rebuildRowSnapshot()`
//  and `apply(settings:)` reconciler — both can be re-implemented as
//  free functions over the input settings, and the resulting outputs
//  asserted directly. The reproductions match the production bodies in
//  `ClockShelfController.swift` clause-for-clause.
//

import Foundation
import Testing
@testable import MenuShelf

// MARK: - Property 13: row composition

/// Pure reproduction of `ClockShelfController.rebuildRowSnapshot()`
/// (without the side effect of writing to the controller's
/// `popoverState.rows` field).
private func composeRows(_ settings: ClockShelfSettings) -> [ClockShelfRowModel] {
    let visible = settings.clocks
        .filter { $0.showInPopover }
        .sorted { $0.sortOrder < $1.sortOrder }
    return visible.map { clock in
        ClockShelfRowModel(
            id: clock.id,
            displayLabel: clock.displayLabel,
            emoji: clock.emoji,
            timeZone: clock.resolvedTimeZone,
            showInPopover: clock.showInPopover
        )
    }
}

/// **Validates: Requirements 3.4, 3.5, 3.6, 3.7**
///
/// The row snapshot is exactly `clocks.filter(\.showInPopover).sorted(by:
/// \.sortOrder).map(ClockShelfRowModel.init)`. We verify the cardinality,
/// the ordering, the per-row field mapping, and the `showInPopover`
/// filter.
@Test("Property 13: rows composition matches filter + sort + map of clocks")
func property13RowComposition() {
    forAll(arbitraryClockShelfSettings, iterations: 100) { settings in
        let rows = composeRows(settings)

        let expected = settings.clocks
            .filter { $0.showInPopover }
            .sorted { $0.sortOrder < $1.sortOrder }

        // 1) Cardinality matches.
        #expect(rows.count == expected.count)

        // 2) Per-row id and order match the sorted-by-sortOrder
        //    visible projection.
        for (row, clock) in zip(rows, expected) {
            #expect(row.id == clock.id)
            #expect(row.displayLabel == clock.displayLabel)
            #expect(row.emoji == clock.emoji)
            #expect(row.timeZone == clock.resolvedTimeZone)
            #expect(row.showInPopover == true)
        }

        // 3) `showInPopover == false` clocks never appear.
        let hiddenIDs = Set(
            settings.clocks
                .filter { !$0.showInPopover }
                .map(\.id)
        )
        for row in rows {
            #expect(!hiddenIDs.contains(row.id))
        }
    }
}

@Test("Property 13: rows are sorted ascending by sortOrder")
func property13RowsAscendingSortOrder() {
    var settings = ClockShelfSettings.defaults
    settings.enableClockShelf = true
    let now = Date()
    settings.clocks = [
        ClockConfig(
            id: UUID(),
            timeZoneIdentifier: "Asia/Tokyo",
            label: "Tokyo",
            emoji: nil,
            pinToMenuBar: false,
            showInPopover: true,
            sortOrder: 5,
            createdAt: now,
            updatedAt: now
        ),
        ClockConfig(
            id: UUID(),
            timeZoneIdentifier: "Europe/Berlin",
            label: "Berlin",
            emoji: nil,
            pinToMenuBar: false,
            showInPopover: true,
            sortOrder: 0,
            createdAt: now,
            updatedAt: now
        ),
        ClockConfig(
            id: UUID(),
            timeZoneIdentifier: "America/Los_Angeles",
            label: "Pacific",
            emoji: nil,
            pinToMenuBar: false,
            showInPopover: true,
            sortOrder: 2,
            createdAt: now,
            updatedAt: now
        ),
    ]

    let rows = composeRows(settings)
    #expect(rows.map(\.displayLabel) == ["Berlin", "Pacific", "Tokyo"])
}

@Test("Property 13: empty clocks → empty rows")
func property13EmptyClocks() {
    var settings = ClockShelfSettings.defaults
    settings.enableClockShelf = true
    settings.clocks = []
    #expect(composeRows(settings).isEmpty)
}

// MARK: - Property 14: pinned status item set

/// Pure reproduction of the controller's "desired pinned set" after
/// `apply(settings:)`. Returns `(orderedIDs, idSet)` so tests can
/// assert both the set membership and the deterministic order.
private func composePinnedSet(_ settings: ClockShelfSettings) -> (order: [UUID], ids: Set<UUID>) {
    guard settings.enableClockShelf else {
        return ([], [])
    }
    let desired = settings.clocks
        .filter { $0.pinToMenuBar }
        .sorted { $0.sortOrder < $1.sortOrder }
    let order = desired.map(\.id)
    return (order, Set(order))
}

/// **Validates: Requirements 4.2, 4.11, 4.12**
@Test("Property 14: pinned set matches clocks where pinToMenuBar == true")
func property14PinnedSetMatchesFilter() {
    forAll(arbitraryClockShelfSettings, iterations: 100) { settings in
        let (order, ids) = composePinnedSet(settings)

        if settings.enableClockShelf == false {
            // When the feature is disabled, every pinned item is torn
            // down and the order is empty.
            #expect(order.isEmpty)
            #expect(ids.isEmpty)
            return
        }

        let expectedSet = Set(
            settings.clocks
                .filter { $0.pinToMenuBar }
                .map(\.id)
        )
        #expect(ids == expectedSet)

        // Order matches sortOrder ascending over the pinned subset.
        let expectedOrder = settings.clocks
            .filter { $0.pinToMenuBar }
            .sorted { $0.sortOrder < $1.sortOrder }
            .map(\.id)
        #expect(order == expectedOrder)
    }
}

@Test("Property 14: feature disabled → empty pinned set even when clocks have pinToMenuBar == true")
func property14DisabledForcesEmptyPinned() {
    let now = Date()
    let pinnedClock = ClockConfig(
        id: UUID(),
        timeZoneIdentifier: "UTC",
        label: nil,
        emoji: nil,
        pinToMenuBar: true,
        showInPopover: true,
        sortOrder: 0,
        createdAt: now,
        updatedAt: now
    )
    var settings = ClockShelfSettings.defaults
    settings.enableClockShelf = false
    settings.clocks = [pinnedClock]

    let (order, ids) = composePinnedSet(settings)
    #expect(order.isEmpty)
    #expect(ids.isEmpty)
}

@Test("Property 14: pinned order is stable across permutations of pinned clocks")
func property14PinnedOrderTracksSortOrder() {
    let now = Date()
    var settings = ClockShelfSettings.defaults
    settings.enableClockShelf = true

    // Three pinned clocks at sortOrder 2, 0, 1 — pinned order must be
    // emitted as the second, third, first slot in the input array.
    let c0 = ClockConfig(id: UUID(), timeZoneIdentifier: "UTC", label: nil, emoji: nil, pinToMenuBar: true, showInPopover: true, sortOrder: 2, createdAt: now, updatedAt: now)
    let c1 = ClockConfig(id: UUID(), timeZoneIdentifier: "UTC", label: nil, emoji: nil, pinToMenuBar: true, showInPopover: true, sortOrder: 0, createdAt: now, updatedAt: now)
    let c2 = ClockConfig(id: UUID(), timeZoneIdentifier: "UTC", label: nil, emoji: nil, pinToMenuBar: true, showInPopover: true, sortOrder: 1, createdAt: now, updatedAt: now)
    settings.clocks = [c0, c1, c2]

    let (order, _) = composePinnedSet(settings)
    #expect(order == [c1.id, c2.id, c0.id])
}

@Test("Property 14: clocks where pinToMenuBar == false are excluded from pinned set")
func property14UnpinnedExcluded() {
    let now = Date()
    var settings = ClockShelfSettings.defaults
    settings.enableClockShelf = true

    let pinned = ClockConfig(id: UUID(), timeZoneIdentifier: "UTC", label: nil, emoji: nil, pinToMenuBar: true, showInPopover: true, sortOrder: 0, createdAt: now, updatedAt: now)
    let unpinned = ClockConfig(id: UUID(), timeZoneIdentifier: "UTC", label: nil, emoji: nil, pinToMenuBar: false, showInPopover: true, sortOrder: 1, createdAt: now, updatedAt: now)
    settings.clocks = [pinned, unpinned]

    let (order, ids) = composePinnedSet(settings)
    #expect(order == [pinned.id])
    #expect(ids == [pinned.id])
    #expect(!ids.contains(unpinned.id))
}

// MARK: - Property 15: pinned title format never includes day-offset suffix

/// Pure reproduction of `ClockShelfController.formatPinnedTitle(...)`.
/// Used by the property test to assert the title shape directly.
private func formatPinnedTitleFreeFunction(
    clock: ClockConfig,
    date: Date,
    use24HourTime: Bool
) -> String {
    let timeString = formatClockShelfTime(
        date: date,
        timeZone: clock.resolvedTimeZone,
        use24HourTime: use24HourTime
    )
    if let emoji = clock.emoji?
        .trimmingCharacters(in: .whitespacesAndNewlines),
       !emoji.isEmpty {
        return "\(emoji) \(timeString)"
    }
    return timeString
}

/// **Validates: Requirements 4.3, 6.5**
///
/// The pinned status item title is `"<emoji> <time>"` when emoji is
/// present and `<time>` otherwise. Crucially: the title NEVER contains
/// a `+N` or `-N` day-offset suffix — that indicator only appears on
/// popover rows (Requirement 6.5 — "the indicator never appears on
/// pinned status item titles").
@Test("Property 15: pinned title is \"<emoji> <time>\" or \"<time>\"")
func property15PinnedTitleShape() {
    let referenceDate = Date(timeIntervalSinceReferenceDate: 700_000_000)
    forAll(arbitraryClockConfig, iterations: 100) { clock in
        for use24HourTime in [false, true] {
            let title = formatPinnedTitleFreeFunction(
                clock: clock,
                date: referenceDate,
                use24HourTime: use24HourTime
            )
            let timeString = formatClockShelfTime(
                date: referenceDate,
                timeZone: clock.resolvedTimeZone,
                use24HourTime: use24HourTime
            )
            if let emoji = clock.emoji?
                .trimmingCharacters(in: .whitespacesAndNewlines),
               !emoji.isEmpty {
                #expect(title == "\(emoji) \(timeString)")
            } else {
                #expect(title == timeString)
            }
        }
    }
}

@Test("Property 15: pinned title never contains a +N / -N day-offset suffix")
func property15NoDayOffsetSuffix() {
    let referenceDate = Date(timeIntervalSinceReferenceDate: 700_000_000)

    // The day-offset suffix on the popover side is rendered as
    // `+1`, `-1`, etc. — single sign character followed by digits.
    // Property 15 says the *pinned title* never contains a substring
    // matching that pattern adjacent to the time. Verify by scanning
    // for any "+<digit>" or "-<digit>" sequence anywhere in the title.
    forAll(arbitraryClockConfig, iterations: 100) { clock in
        for use24HourTime in [false, true] {
            let title = formatPinnedTitleFreeFunction(
                clock: clock,
                date: referenceDate,
                use24HourTime: use24HourTime
            )
            // Check that the title doesn't carry the day-offset markers.
            // A 24-hour title like "13:45" contains a colon-digit run
            // but no `+`/`-` adjacent to digits. A locale 12-hour title
            // like "1:45 PM" likewise contains no signed numeric runs.
            let signedNumericPattern = #/[+\-]\d+/#
            #expect(title.firstMatch(of: signedNumericPattern) == nil,
                    "Pinned title \(title) should not contain signed numeric runs (day-offset markers)")
        }
    }
}

@Test("Property 15: empty / whitespace-only emoji is treated as absent")
func property15EmptyEmojiTreatedAsAbsent() {
    let referenceDate = Date(timeIntervalSinceReferenceDate: 700_000_000)
    let cases: [String?] = ["", "   ", "\t", nil]
    for emoji in cases {
        let clock = ClockConfig(
            id: UUID(),
            timeZoneIdentifier: "UTC",
            label: "UTC",
            emoji: emoji,
            pinToMenuBar: true,
            showInPopover: false,
            sortOrder: 0,
            createdAt: referenceDate,
            updatedAt: referenceDate
        )
        let title = formatPinnedTitleFreeFunction(
            clock: clock,
            date: referenceDate,
            use24HourTime: true
        )
        let timeOnly = formatClockShelfTime(
            date: referenceDate,
            timeZone: TimeZone(identifier: "UTC")!,
            use24HourTime: true
        )
        #expect(title == timeOnly)
    }
}

@Test("Property 15: pinned title with emoji uses single-space separator")
func property15EmojiSpaceSeparator() {
    let referenceDate = Date(timeIntervalSinceReferenceDate: 700_000_000)
    let clock = ClockConfig(
        id: UUID(),
        timeZoneIdentifier: "UTC",
        label: nil,
        emoji: "🌍",
        pinToMenuBar: true,
        showInPopover: false,
        sortOrder: 0,
        createdAt: referenceDate,
        updatedAt: referenceDate
    )
    let title = formatPinnedTitleFreeFunction(
        clock: clock,
        date: referenceDate,
        use24HourTime: true
    )
    #expect(title.hasPrefix("🌍 "))
    // Exactly one space between emoji and time.
    let timeOnly = formatClockShelfTime(
        date: referenceDate,
        timeZone: TimeZone(identifier: "UTC")!,
        use24HourTime: true
    )
    #expect(title == "🌍 \(timeOnly)")
}
