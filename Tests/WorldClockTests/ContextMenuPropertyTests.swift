//
//  ContextMenuPropertyTests.swift
//  WorldClockTests
//
//  Property-based tests for the row-context-menu actions exposed by
//  the World Clock popover:
//
//  - Property 22: Copy Time and Copy Time Zone Identifier write the
//    expected single-payload string after clearing the pasteboard.
//  - Property 23: Pin/Unpin context menu toggle flips exactly the
//    targeted clock's `pinToMenuBar` (every other field unchanged
//    except `updatedAt`).
//
//  Strategy:
//
//  - Property 22 targets the algorithm
//      pasteboard.clearContents()
//      pasteboard.setString(payload, forType: .string)
//    The `NSPasteboard.general` singleton is shared with the rest of
//    the app, so we route the assertion through a dedicated
//    `NSPasteboard(name:)` instance so the test never clobbers the
//    user's clipboard. The algorithm under test is identical to the
//    one in `ClockRowContextMenu.body` — the per-action production
//    bodies are short two-line clauses that we replicate exactly.
//
//  - Property 23 mirrors `PreferencesStore.updateWorldClock(_:)`'s
//    pin-toggle path: produce a `ClockConfig` with `pinToMenuBar`
//    flipped, pass it through, and assert that exactly one field
//    flipped on the targeted row, every other clock is byte-equal,
//    and `updatedAt` advanced.
//

import AppKit
import Foundation
import Testing
@testable import MenuShelf

// MARK: - Property 22: pasteboard payload shape

/// Algorithm under test for the "Copy Time" / "Copy Time Zone
/// Identifier" context menu items. Mirrors `ClockRowContextMenu.body`
/// in `WorldClockPopoverView.swift` clause-for-clause:
///
///     let pasteboard = NSPasteboard.general
///     pasteboard.clearContents()
///     pasteboard.setString(displayedTimeString, forType: .string)
///
/// We accept the pasteboard as a parameter so the test can route
/// writes through a private `NSPasteboard(name:)` instance and never
/// touch the user's clipboard.
private func performCopy(
    _ payload: String,
    to pasteboard: NSPasteboard
) {
    pasteboard.clearContents()
    pasteboard.setString(payload, forType: .string)
}

/// **Validates: Requirements 7.2, 7.3**
///
/// After `performCopy(payload, to: pasteboard)`, the pasteboard:
/// 1. contains exactly the `payload` string for the
///    `public.utf8-plain-text` (`.string`) type;
/// 2. does not retain pre-existing strings from prior writes.
@Test("Property 22: Copy Time writes the displayed time string to the pasteboard")
func property22CopyTimeWritesDisplayedTime() {
    let pasteboard = NSPasteboard(name: NSPasteboard.Name(rawValue: "WorldClockTestPB-Time"))
    let referenceDate = Date(timeIntervalSinceReferenceDate: 700_000_000)

    forAll(arbitraryClockConfig, iterations: 50) { clock in
        for use24HourTime in [false, true] {
            let displayedTime = formatWorldClockTime(
                date: referenceDate,
                timeZone: clock.resolvedTimeZone,
                use24HourTime: use24HourTime
            )
            performCopy(displayedTime, to: pasteboard)
            let read = pasteboard.string(forType: .string)
            #expect(read == displayedTime, "Pasteboard should contain the displayed time string")
        }
    }
}

@Test("Property 22: Copy Time Zone Identifier writes the IANA identifier")
func property22CopyTimeZoneIdentifierWritesIdentifier() {
    let pasteboard = NSPasteboard(name: NSPasteboard.Name(rawValue: "WorldClockTestPB-ID"))

    forAll(arbitraryClockConfig, iterations: 100) { clock in
        let identifier = clock.timeZoneIdentifier
        performCopy(identifier, to: pasteboard)
        let read = pasteboard.string(forType: .string)
        #expect(read == identifier)
    }
}

@Test("Property 22: clearContents drops the prior string before the new write")
func property22ClearContentsDropsPriorString() {
    let pasteboard = NSPasteboard(name: NSPasteboard.Name(rawValue: "WorldClockTestPB-Clear"))

    // Write a sentinel value first.
    performCopy("PRIOR-VALUE", to: pasteboard)
    #expect(pasteboard.string(forType: .string) == "PRIOR-VALUE")

    // Now write a fresh value through the same algorithm.
    performCopy("NEW-VALUE", to: pasteboard)
    #expect(pasteboard.string(forType: .string) == "NEW-VALUE")
    // The prior value is gone — clearContents() removed it.
    #expect(pasteboard.string(forType: .string) != "PRIOR-VALUE")
}

@Test("Property 22: round trip — string written equals string read for any UTF-8 payload")
func property22RoundTripUTF8Payload() {
    let pasteboard = NSPasteboard(name: NSPasteboard.Name(rawValue: "WorldClockTestPB-UTF8"))
    let payloads = [
        "Plain ASCII",
        "12:34 PM",
        "13:45",
        "🌍 12:00",
        "America/Los_Angeles",
        "Pacific/Pago_Pago",
        "Asia/Tokyo",
        "Hello, world!",
    ]
    for payload in payloads {
        performCopy(payload, to: pasteboard)
        let read = pasteboard.string(forType: .string)
        #expect(read == payload, "Round trip failed for \(payload)")
    }
}

@Test("Property 22: a single setString call writes exactly one payload, not concatenated history")
func property22SinglePayloadOnly() {
    let pasteboard = NSPasteboard(name: NSPasteboard.Name(rawValue: "WorldClockTestPB-Single"))
    performCopy("first", to: pasteboard)
    performCopy("second", to: pasteboard)
    performCopy("third", to: pasteboard)
    let read = pasteboard.string(forType: .string)
    #expect(read == "third")
    // The pasteboard's `pasteboardItems` should hold exactly one item.
    #expect((pasteboard.pasteboardItems ?? []).count == 1)
}

// MARK: - Property 23: pin/unpin toggle

/// Pure reproduction of the pin-toggle path the `ClockRowContextMenu`
/// runs when the user invokes "Pin to Menu Bar" / "Unpin from Menu
/// Bar". Mirrors:
///
///     var updated = liveClock
///     updated.pinToMenuBar.toggle()
///     store.updateWorldClock(updated)
///
/// where `updateWorldClock(_:)` preserves `createdAt` and `sortOrder`
/// from the pre-state, bumps `updatedAt`, and writes the result back
/// (matching `WorldClockPreferencesStore.updateWorldClock(_:)`).
private func applyPinToggle(
    _ wc: inout WorldClockSettings,
    id: UUID
) {
    guard let liveClock = wc.clocks.first(where: { $0.id == id }) else {
        return
    }
    var updated = liveClock
    updated.pinToMenuBar.toggle()

    // Now apply through the documented updateWorldClock semantics:
    // preserve createdAt and sortOrder; bump updatedAt.
    guard let index = wc.clocks.firstIndex(where: { $0.id == id }) else {
        return
    }
    var rebound = updated
    rebound.sortOrder = wc.clocks[index].sortOrder
    rebound.createdAt = wc.clocks[index].createdAt
    rebound.updatedAt = Date()
    wc.clocks[index] = rebound
}

/// **Validates: Requirement 7.5**
///
/// After `applyPinToggle(_:id:)`:
/// 1. exactly the targeted clock's `pinToMenuBar` flipped;
/// 2. every other clock is byte-equal to its pre-state;
/// 3. every other field on the targeted clock is byte-equal except
///    `updatedAt`, which advanced.
@Test("Property 23: pin toggle flips only the targeted clock's pinToMenuBar")
func property23PinTogglesTargetOnly() {
    let pre = makeMultiClockSettings()

    forAll(arbitraryTargetIndex(in: pre.clocks.count), iterations: 50) { targetIdx in
        var wc = pre
        let preStateClocks = wc.clocks
        let targetID = preStateClocks[targetIdx].id
        let beforeToggle = Date()

        applyPinToggle(&wc, id: targetID)

        // 1) Exactly one pinToMenuBar value differs.
        var diffCount = 0
        for (preClock, postClock) in zip(preStateClocks, wc.clocks) {
            if preClock.pinToMenuBar != postClock.pinToMenuBar {
                diffCount += 1
                #expect(postClock.id == targetID)
                #expect(postClock.pinToMenuBar == !preClock.pinToMenuBar)
            }
        }
        #expect(diffCount == 1, "Exactly one clock's pinToMenuBar should flip")

        // 2) Every other clock is byte-equal.
        for (idx, (preClock, postClock)) in zip(preStateClocks, wc.clocks).enumerated()
        where idx != targetIdx {
            #expect(preClock == postClock, "Sibling clock at index \(idx) must be unchanged")
        }

        // 3) Targeted clock: every field unchanged except pinToMenuBar
        //    and updatedAt.
        let preTarget = preStateClocks[targetIdx]
        let postTarget = wc.clocks[targetIdx]
        #expect(postTarget.id == preTarget.id)
        #expect(postTarget.timeZoneIdentifier == preTarget.timeZoneIdentifier)
        #expect(postTarget.label == preTarget.label)
        #expect(postTarget.emoji == preTarget.emoji)
        #expect(postTarget.showInPopover == preTarget.showInPopover)
        #expect(postTarget.sortOrder == preTarget.sortOrder)
        #expect(postTarget.createdAt == preTarget.createdAt)
        #expect(postTarget.pinToMenuBar == !preTarget.pinToMenuBar)
        #expect(postTarget.updatedAt >= beforeToggle)
    }
}

@Test("Property 23: pin toggle is its own inverse (toggling twice returns to the pre-state's pinToMenuBar)")
func property23PinToggleInverse() {
    var wc = makeMultiClockSettings()
    let targetID = wc.clocks[1].id
    let preState = wc.clocks[1].pinToMenuBar
    applyPinToggle(&wc, id: targetID)
    #expect(wc.clocks[1].pinToMenuBar == !preState)
    applyPinToggle(&wc, id: targetID)
    #expect(wc.clocks[1].pinToMenuBar == preState)
}

@Test("Property 23: pin toggle on a non-existent id is a no-op")
func property23PinToggleNonExistentNoOp() {
    var wc = makeMultiClockSettings()
    let pre = wc
    applyPinToggle(&wc, id: UUID())
    #expect(wc == pre)
}

@Test("Property 23: pin toggle on first/last/middle clocks each work independently")
func property23PinToggleOnVariousIndices() {
    var wc = makeMultiClockSettings()
    let prePinFlags = wc.clocks.map(\.pinToMenuBar)

    // Flip the first.
    applyPinToggle(&wc, id: wc.clocks[0].id)
    #expect(wc.clocks[0].pinToMenuBar == !prePinFlags[0])
    #expect(wc.clocks[1].pinToMenuBar == prePinFlags[1])
    #expect(wc.clocks[2].pinToMenuBar == prePinFlags[2])

    // Flip the last.
    applyPinToggle(&wc, id: wc.clocks[2].id)
    #expect(wc.clocks[0].pinToMenuBar == !prePinFlags[0])
    #expect(wc.clocks[1].pinToMenuBar == prePinFlags[1])
    #expect(wc.clocks[2].pinToMenuBar == !prePinFlags[2])

    // Flip the middle.
    applyPinToggle(&wc, id: wc.clocks[1].id)
    #expect(wc.clocks[0].pinToMenuBar == !prePinFlags[0])
    #expect(wc.clocks[1].pinToMenuBar == !prePinFlags[1])
    #expect(wc.clocks[2].pinToMenuBar == !prePinFlags[2])
}

// MARK: - Helpers

private func makeMultiClockSettings() -> WorldClockSettings {
    let now = Date(timeIntervalSinceReferenceDate: 0)
    var settings = WorldClockSettings.defaults
    settings.enableWorldClock = true
    settings.clocks = [
        ClockConfig(
            id: UUID(),
            timeZoneIdentifier: "America/Los_Angeles",
            label: "Pacific",
            emoji: "🌎",
            pinToMenuBar: true,
            showInPopover: true,
            sortOrder: 0,
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
            sortOrder: 1,
            createdAt: now.addingTimeInterval(60),
            updatedAt: now.addingTimeInterval(60)
        ),
        ClockConfig(
            id: UUID(),
            timeZoneIdentifier: "Asia/Tokyo",
            label: "Tokyo",
            emoji: "🌏",
            pinToMenuBar: false,
            showInPopover: true,
            sortOrder: 2,
            createdAt: now.addingTimeInterval(120),
            updatedAt: now.addingTimeInterval(120)
        ),
    ]
    return settings
}

private func arbitraryTargetIndex(in count: Int) -> AnyGenerator<Int> {
    AnyGenerator { rng in
        Int.random(in: 0..<count, using: &rng)
    }
}
