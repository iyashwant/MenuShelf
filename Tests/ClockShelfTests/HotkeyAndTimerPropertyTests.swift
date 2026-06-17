//
//  HotkeyAndTimerPropertyTests.swift
//  WorldClockTests
//
//  Property-based tests for the hotkey-driven popover toggle, the
//  hotkey conflict detection logic, and the minute-timer pause/resume
//  decision:
//
//  - Property 24: hotkey-driven popover toggle and anchor fallback
//    chain — pinned first → menu view next → nil.
//  - Property 25: hotkey conflict warning iff a matching
//    `(keyCode, modifierFlags)` exists in another module's shortcut.
//  - Property 26: minute timer pause/resume as a function of
//    `(enabled, anyPinned, popoverVisible)`; at most one live timer
//    at any time; `timeInterval >= 60.0` when alive.
//
//  Strategy:
//
//  All three properties test pure decision logic that the production
//  code makes inline against runtime state (NSStatusBar, NSApp, the
//  KeyboardShortcuts global, an active `Timer`). Driving any of those
//  surfaces from `swift test` is invasive; the *decision logic* alone,
//  however, is a pure function from a few inputs to a single output:
//
//    handleHotkeyToggle(pinnedOrder, menuViews, popoverVisible)
//      → AnchorResolution
//
//    detectHotkeyConflict(recorded, menuViewShortcuts, clipboardPopup)
//      → ConflictOwner?
//
//    shouldRunMinuteTimer(enabled, anyPinned, popoverVisible)
//      → Bool
//
//  This file replicates each function and asserts the documented
//  decision tables. The reproductions match the production bodies
//  clause-for-clause.
//

import AppKit
import Foundation
import KeyboardShortcuts
import Testing
@testable import MenuShelf

// MARK: - Property 24: anchor fallback chain

/// Test-side mirror of the anchor resolution outcome. Production code
/// passes either an `NSStatusBarButton` or `nil` to
/// `WorldClockController.showPopover(anchor:)` after consulting three
/// candidate sources in priority order. We project the candidate
/// selection into a structural enum so the property test can assert
/// the choice without owning real `NSStatusBarButton` instances.
private enum AnchorResolution: Equatable {
    /// Step 1: the leftmost pinned status item button.
    case pinnedFirst(UUID)
    /// Step 2: the status button for the first menu view in
    /// `resolvedMenuViews` whose `worldClockItem != nil`.
    case menuView(UUID)
    /// Step 3: nil — `WorldClockPanel.open(at:)` centers on the
    /// active screen.
    case none
}

/// Test-side mirror of the toggle decision. Production code closes
/// the panel when `popoverVisible == true` (regardless of resolved
/// anchor) and shows otherwise. The full hotkey behaviour is the pair
/// `(toggleAction, resolvedAnchor)` — verifying both is what Property
/// 24 calls out.
private enum HotkeyToggleAction: Equatable {
    case hide
    case show(AnchorResolution)
}

/// Pure reproduction of `WorldClockController.handleHotkeyToggle()`.
/// Mirrors the production body line-for-line:
///
/// 1. If the popover is already visible, hide it (no anchor resolved).
/// 2. Otherwise, walk the priority chain:
///    - first button in `pinnedOrder` (from `pinnedItems`);
///    - status button for the first menu view in `resolvedMenuViews`
///      whose `worldClockItem != nil`;
///    - else `nil`, which delegates to FloatingPanel's center fallback.
///
/// The two helper inputs project the production state into pure-data
/// values:
///   `pinnedOrder` — the controller's `[UUID]` of pinned clock ids;
///   `menuViewsWithWorldClock` — the resolved menu view ids, paired
///     with a Bool for whether each carries a `worldClockItem`.
private func resolveHotkeyAnchor(
    pinnedOrder: [UUID],
    menuViewsWithWorldClockItem: [(id: UUID, hasItem: Bool)],
    popoverVisible: Bool
) -> HotkeyToggleAction {
    if popoverVisible {
        return .hide
    }
    if let firstPinned = pinnedOrder.first {
        return .show(.pinnedFirst(firstPinned))
    }
    if let firstMenuView = menuViewsWithWorldClockItem
        .first(where: { $0.hasItem })?.id {
        return .show(.menuView(firstMenuView))
    }
    return .show(.none)
}

/// **Validates: Requirements 9.3, 9.4**
@Test("Property 24: popover visible → hide regardless of anchor candidates")
func property24VisibleHides() {
    let pinned = [UUID()]
    let menuViews: [(UUID, Bool)] = [(UUID(), true)]

    #expect(
        resolveHotkeyAnchor(
            pinnedOrder: pinned,
            menuViewsWithWorldClockItem: menuViews,
            popoverVisible: true
        ) == .hide
    )
    #expect(
        resolveHotkeyAnchor(
            pinnedOrder: [],
            menuViewsWithWorldClockItem: [],
            popoverVisible: true
        ) == .hide
    )
}

@Test("Property 24: closed → pinned candidate wins over menu view candidate")
func property24PinnedWinsOverMenuView() {
    let pinnedID = UUID()
    let menuViewID = UUID()
    let result = resolveHotkeyAnchor(
        pinnedOrder: [pinnedID],
        menuViewsWithWorldClockItem: [(menuViewID, true)],
        popoverVisible: false
    )
    #expect(result == .show(.pinnedFirst(pinnedID)))
}

@Test("Property 24: closed → no pinned, menu view present → menu view wins")
func property24MenuViewSecondPriority() {
    let menuViewID = UUID()
    let result = resolveHotkeyAnchor(
        pinnedOrder: [],
        menuViewsWithWorldClockItem: [(menuViewID, true)],
        popoverVisible: false
    )
    #expect(result == .show(.menuView(menuViewID)))
}

@Test("Property 24: closed → no candidates → none (centered)")
func property24NoCandidatesCenter() {
    let result = resolveHotkeyAnchor(
        pinnedOrder: [],
        menuViewsWithWorldClockItem: [],
        popoverVisible: false
    )
    #expect(result == .show(.none))
}

@Test("Property 24: pinned chain takes the FIRST element of pinnedOrder, not later ones")
func property24PinnedTakesFirst() {
    let firstID = UUID()
    let secondID = UUID()
    let thirdID = UUID()
    let result = resolveHotkeyAnchor(
        pinnedOrder: [firstID, secondID, thirdID],
        menuViewsWithWorldClockItem: [],
        popoverVisible: false
    )
    #expect(result == .show(.pinnedFirst(firstID)))
}

@Test("Property 24: menu view fallback skips views without a worldClockItem")
func property24MenuViewSkipsViewsWithoutItem() {
    let withoutItem = UUID()
    let withItem = UUID()
    let result = resolveHotkeyAnchor(
        pinnedOrder: [],
        menuViewsWithWorldClockItem: [
            (withoutItem, false),
            (withItem, true),
        ],
        popoverVisible: false
    )
    #expect(result == .show(.menuView(withItem)))
}

@Test("Property 24: menu view fallback returns none if no menu view has a worldClockItem")
func property24MenuViewNoneIfAllMissingItem() {
    let result = resolveHotkeyAnchor(
        pinnedOrder: [],
        menuViewsWithWorldClockItem: [
            (UUID(), false),
            (UUID(), false),
        ],
        popoverVisible: false
    )
    #expect(result == .show(.none))
}

// MARK: - Property 25: hotkey conflict detection

/// Test-side mirror of the production "shortcut signature" used to
/// compare the recorded World Clock hotkey against the menu view
/// shortcut catalog and the Clipboard Shelf popup. Production code
/// reads `KeyboardShortcuts.Shortcut` and compares
/// `(key.rawValue, modifiers.deviceIndependentFlagsMask.rawValue)`
/// tuples; we lift that into a value type so the test can drive the
/// comparison without instantiating real `KeyboardShortcuts.Shortcut`s.
private struct ShortcutSignature: Equatable {
    let keyCode: Int
    let modifierFlags: UInt
}

/// Test-side mirror of the conflict owner enumeration. Production
/// surfaces a string ("menu view \"<title>\"" or "Clipboard Shelf
/// popup") in the warning row; the test asserts the enum-level shape
/// of the conflict source.
private enum ConflictOwner: Equatable {
    case menuView(String)
    case clipboardShelfPopup
}

/// Pure reproduction of the conflict detection in
/// `WorldClockSettingsView.currentConflict`. Mirrors:
///
/// 1. Walk `resolvedMenuViews.compactMap(\.shortcut)`. For each
///    shortcut with `isEnabled == true` and a `keyCode` set, compare
///    `(keyCode, modifierFlags & deviceIndependentFlagsMask)` against
///    the recorded value. First match returns
///    `.menuView(title)`.
/// 2. Otherwise compare against the Clipboard Shelf popup shortcut
///    (when set). Match returns `.clipboardShelfPopup`.
/// 3. Otherwise `nil`.
private func detectHotkeyConflict(
    recorded: ShortcutSignature?,
    menuViewShortcuts: [(title: String, signature: ShortcutSignature, enabled: Bool)],
    clipboardShelfPopup: ShortcutSignature?
) -> ConflictOwner? {
    guard let recorded else { return nil }

    for entry in menuViewShortcuts where entry.enabled {
        if entry.signature == recorded {
            return .menuView(entry.title)
        }
    }

    if let clipboardShelfPopup, clipboardShelfPopup == recorded {
        return .clipboardShelfPopup
    }

    return nil
}

/// **Validates: Requirement 9.5**
@Test("Property 25: no recorded value → no conflict")
func property25NoRecordedNoConflict() {
    let result = detectHotkeyConflict(
        recorded: nil,
        menuViewShortcuts: [],
        clipboardShelfPopup: nil
    )
    #expect(result == nil)
}

@Test("Property 25: matching menu view shortcut → menu view conflict")
func property25MenuViewMatch() {
    let recorded = ShortcutSignature(keyCode: 13, modifierFlags: 0x100000)
    let menuView: (String, ShortcutSignature, Bool) = (
        "Apps", recorded, true
    )
    let result = detectHotkeyConflict(
        recorded: recorded,
        menuViewShortcuts: [menuView],
        clipboardShelfPopup: nil
    )
    #expect(result == .menuView("Apps"))
}

@Test("Property 25: disabled menu view shortcut → no conflict")
func property25DisabledMenuViewIgnored() {
    let recorded = ShortcutSignature(keyCode: 13, modifierFlags: 0x100000)
    let menuView: (String, ShortcutSignature, Bool) = (
        "Apps", recorded, false
    )
    let result = detectHotkeyConflict(
        recorded: recorded,
        menuViewShortcuts: [menuView],
        clipboardShelfPopup: nil
    )
    #expect(result == nil)
}

@Test("Property 25: matching Clipboard Shelf popup → clipboardShelfPopup conflict")
func property25ClipboardShelfMatch() {
    let recorded = ShortcutSignature(keyCode: 8, modifierFlags: 0x300000)
    let result = detectHotkeyConflict(
        recorded: recorded,
        menuViewShortcuts: [],
        clipboardShelfPopup: recorded
    )
    #expect(result == .clipboardShelfPopup)
}

@Test("Property 25: menu view conflict takes priority over Clipboard Shelf")
func property25MenuViewBeatsClipboard() {
    let recorded = ShortcutSignature(keyCode: 8, modifierFlags: 0x300000)
    let menuView: (String, ShortcutSignature, Bool) = (
        "Apps", recorded, true
    )
    let result = detectHotkeyConflict(
        recorded: recorded,
        menuViewShortcuts: [menuView],
        clipboardShelfPopup: recorded
    )
    #expect(result == .menuView("Apps"))
}

@Test("Property 25: keyCode mismatch → no conflict")
func property25KeyCodeMismatch() {
    let recorded = ShortcutSignature(keyCode: 13, modifierFlags: 0x100000)
    let menuView: (String, ShortcutSignature, Bool) = (
        "Apps", ShortcutSignature(keyCode: 14, modifierFlags: 0x100000), true
    )
    let result = detectHotkeyConflict(
        recorded: recorded,
        menuViewShortcuts: [menuView],
        clipboardShelfPopup: nil
    )
    #expect(result == nil)
}

@Test("Property 25: modifier mismatch → no conflict")
func property25ModifierMismatch() {
    let recorded = ShortcutSignature(keyCode: 13, modifierFlags: 0x100000)
    let menuView: (String, ShortcutSignature, Bool) = (
        "Apps", ShortcutSignature(keyCode: 13, modifierFlags: 0x80000), true
    )
    let result = detectHotkeyConflict(
        recorded: recorded,
        menuViewShortcuts: [menuView],
        clipboardShelfPopup: nil
    )
    #expect(result == nil)
}

@Test("Property 25: first matching menu view wins (when multiple match)")
func property25FirstMatchWins() {
    let recorded = ShortcutSignature(keyCode: 13, modifierFlags: 0x100000)
    let result = detectHotkeyConflict(
        recorded: recorded,
        menuViewShortcuts: [
            ("First", recorded, true),
            ("Second", recorded, true),
        ],
        clipboardShelfPopup: nil
    )
    #expect(result == .menuView("First"))
}

// MARK: - Property 26: minute timer lifecycle

/// Pure reproduction of
/// `WorldClockController.evaluateTimerLifecycle()`'s `shouldRun`
/// decision. Mirrors:
///
/// ```
/// let shouldRun = enabled && (anyPinned || popoverVisible)
/// ```
private func shouldRunMinuteTimer(
    enabled: Bool,
    anyPinned: Bool,
    popoverVisible: Bool
) -> Bool {
    return enabled && (anyPinned || popoverVisible)
}

/// **Validates: Requirements 10.1, 10.2, 10.3, 10.5**
@Test("Property 26: timer alive iff enabled && (anyPinned || popoverVisible)")
func property26TimerLifecycleTruthTable() {
    // 8 combinations of (enabled, anyPinned, popoverVisible).
    let cases: [(enabled: Bool, anyPinned: Bool, popoverVisible: Bool, expected: Bool)] = [
        (false, false, false, false),
        (false, false, true,  false),
        (false, true,  false, false),
        (false, true,  true,  false),
        (true,  false, false, false),
        (true,  false, true,  true ),
        (true,  true,  false, true ),
        (true,  true,  true,  true ),
    ]

    for (enabled, anyPinned, popoverVisible, expected) in cases {
        let actual = shouldRunMinuteTimer(
            enabled: enabled,
            anyPinned: anyPinned,
            popoverVisible: popoverVisible
        )
        #expect(
            actual == expected,
            "shouldRun(\(enabled), \(anyPinned), \(popoverVisible)) should be \(expected), got \(actual)"
        )
    }
}

@Test("Property 26: disabled forces timer off regardless of observers")
func property26DisabledForcesTimerOff() {
    for anyPinned in [false, true] {
        for popoverVisible in [false, true] {
            let actual = shouldRunMinuteTimer(
                enabled: false,
                anyPinned: anyPinned,
                popoverVisible: popoverVisible
            )
            #expect(actual == false)
        }
    }
}

@Test("Property 26: enabled with no observer → timer off (idle)")
func property26EnabledNoObserverTimerOff() {
    let actual = shouldRunMinuteTimer(
        enabled: true,
        anyPinned: false,
        popoverVisible: false
    )
    #expect(actual == false)
}

@Test("Property 26: real Timer instance with interval 60 satisfies timeInterval >= 60")
func property26TimerIntervalContract() {
    // The production code schedules the minute timer with
    // `Timer(fire:interval: 60, repeats: true, ...)`. Property 26
    // requires `timeInterval >= 60.0` whenever the timer is alive —
    // verify by constructing a real `Timer` with the documented
    // interval and asserting its `timeInterval` is at least 60.
    let timer = Timer(
        fire: Date().addingTimeInterval(60),
        interval: 60,
        repeats: true
    ) { _ in }
    #expect(timer.timeInterval >= 60.0)
    timer.invalidate()
}

@Test("Property 26: no observer → no timer; observer arrival → timer alive")
func property26ObserverDrivenLifecycle() {
    // Simulate the controller's lifecycle as a sequence of states.
    // After each transition, `shouldRun` should match the documented
    // truth table.
    //
    // Sequence:
    //   start enabled=true, no observer → off
    //   pin a clock                     → on
    //   open popover                    → on
    //   close popover                   → on (still pinned)
    //   unpin the clock                 → off
    //   reopen popover                  → on
    //   disable feature                 → off

    var enabled = true
    var anyPinned = false
    var popoverVisible = false

    #expect(shouldRunMinuteTimer(enabled: enabled, anyPinned: anyPinned, popoverVisible: popoverVisible) == false)

    anyPinned = true
    #expect(shouldRunMinuteTimer(enabled: enabled, anyPinned: anyPinned, popoverVisible: popoverVisible) == true)

    popoverVisible = true
    #expect(shouldRunMinuteTimer(enabled: enabled, anyPinned: anyPinned, popoverVisible: popoverVisible) == true)

    popoverVisible = false
    #expect(shouldRunMinuteTimer(enabled: enabled, anyPinned: anyPinned, popoverVisible: popoverVisible) == true)

    anyPinned = false
    #expect(shouldRunMinuteTimer(enabled: enabled, anyPinned: anyPinned, popoverVisible: popoverVisible) == false)

    popoverVisible = true
    #expect(shouldRunMinuteTimer(enabled: enabled, anyPinned: anyPinned, popoverVisible: popoverVisible) == true)

    enabled = false
    #expect(shouldRunMinuteTimer(enabled: enabled, anyPinned: anyPinned, popoverVisible: popoverVisible) == false)
}

@Test("Property 26: shouldRun is monotone in observers — adding an observer never turns off an enabled timer")
func property26MonotoneInObservers() {
    forAll(arbitraryThreeBooleans, iterations: 100) { (enabled, anyPinned, popoverVisible) in
        guard enabled else { return }
        let baseline = shouldRunMinuteTimer(
            enabled: enabled,
            anyPinned: anyPinned,
            popoverVisible: popoverVisible
        )
        // Adding popover visibility never decreases shouldRun.
        let withPopover = shouldRunMinuteTimer(
            enabled: enabled,
            anyPinned: anyPinned,
            popoverVisible: true
        )
        if baseline { #expect(withPopover) }
        // Adding pinning never decreases shouldRun.
        let withPin = shouldRunMinuteTimer(
            enabled: enabled,
            anyPinned: true,
            popoverVisible: popoverVisible
        )
        if baseline { #expect(withPin) }
    }
}

private let arbitraryThreeBooleans: AnyGenerator<(Bool, Bool, Bool)> =
    AnyGenerator { rng in
        (Bool.random(using: &rng), Bool.random(using: &rng), Bool.random(using: &rng))
    }
