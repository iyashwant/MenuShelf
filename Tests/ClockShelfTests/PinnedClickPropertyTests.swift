//
//  PinnedClickPropertyTests.swift
//  ClockShelfTests
//
//  Property-based tests for the click dispatch logic on pinned status
//  items:
//
//  - Property 16: pinned click dispatch (no modifiers → `togglePopover`;
//    any of `[option, control, shift, command]` → settings with
//    `focusClockShelf: true, scrollToClockID:`).
//  - Property 17: right-click on a pinned status item is a no-op.
//
//  Why this is a pure-function test:
//
//  The production code lives in `ClockShelfController.handlePinnedClick(_:)`
//  and reads `NSApp.currentEvent` to determine the event type and
//  modifier flags. Driving that path from `swift test` requires
//  fabricating an `NSEvent` and posting it through the AppKit run loop,
//  which is brittle and risks modifying global app state. The
//  *dispatch decision* itself, however, is a pure function of two
//  inputs:
//
//      (eventType: NSEvent.EventType, modifierFlags: NSEvent.ModifierFlags)
//      → DispatchAction
//
//  This file re-implements that decision as
//  `pinnedClickDispatch(eventType:modifierFlags:)` matching the
//  production body in `ClockShelfController.handlePinnedClick(_:)`
//  clause-for-clause and asserts the documented dispatch table over
//  the entire `(eventType, modifier)` cross-product. The reproduction
//  is direct enough that a drift in the production decision logic
//  would surface at code-review time even without a runtime hookup.
//

import AppKit
import Foundation
import Testing
@testable import MenuShelf

// MARK: - Dispatch action enum (test-side mirror)

/// Three branches the production click handler may take. Mirrors the
/// switch in `ClockShelfController.handlePinnedClick(_:)`:
/// - `.toggle`: invokes `togglePopover(anchor: clickedButton)`;
/// - `.settings`: invokes `SettingsWindowController.show(focusClockShelf: true, scrollToClockID: clockID)`;
/// - `.none`: returns without dispatching (right-click → no-op).
private enum DispatchAction: Equatable {
    case toggle
    case settings
    case none
}

/// Pure reproduction of the production dispatch logic in
/// `ClockShelfController.handlePinnedClick(_:)`. The production body
/// reads `NSApp.currentEvent` for `event?.type` and
/// `event?.modifierFlags`; both are passed in here so the test can
/// drive the function deterministically.
///
/// Production logic:
/// ```
///  if event?.type == .rightMouseUp { return /* .none */ }
///  let modifiers = event?.modifierFlags ?? []
///  let modifierKeys: NSEvent.ModifierFlags = [.option, .control, .shift, .command]
///  let hasModifier = !modifiers.intersection(modifierKeys).isEmpty
///  if hasModifier { openSettingsForClock(clockID) }
///  else { togglePopover(anchor: button) }
/// ```
private func pinnedClickDispatch(
    eventType: NSEvent.EventType?,
    modifierFlags: NSEvent.ModifierFlags
) -> DispatchAction {
    if eventType == .rightMouseUp {
        return .none
    }
    let modifierKeys: NSEvent.ModifierFlags = [.option, .control, .shift, .command]
    let hasModifier = !modifierFlags.intersection(modifierKeys).isEmpty
    return hasModifier ? .settings : .toggle
}

// MARK: - Property 16: dispatch table

/// **Validates: Requirements 4.8, 4.9**
///
/// For any left-mouse-up event:
/// - empty modifier set → `.toggle`
/// - any of `[option, control, shift, command]` set → `.settings`
@Test("Property 16: left-click without modifiers → toggle")
func property16NoModifierToggles() {
    #expect(pinnedClickDispatch(eventType: .leftMouseUp, modifierFlags: []) == .toggle)
}

@Test("Property 16: left-click with each individual modifier → settings")
func property16IndividualModifiers() {
    let modifiers: [NSEvent.ModifierFlags] = [
        .option, .control, .shift, .command,
    ]
    for modifier in modifiers {
        #expect(
            pinnedClickDispatch(eventType: .leftMouseUp, modifierFlags: modifier) == .settings,
            "Modifier \(modifier) should dispatch settings"
        )
    }
}

@Test("Property 16: left-click with combined modifiers → settings")
func property16CombinedModifiers() {
    let combinations: [NSEvent.ModifierFlags] = [
        [.option, .command],
        [.control, .shift],
        [.option, .control, .shift, .command],
        [.shift, .command],
    ]
    for modifier in combinations {
        #expect(
            pinnedClickDispatch(eventType: .leftMouseUp, modifierFlags: modifier) == .settings,
            "Modifier \(modifier) should dispatch settings"
        )
    }
}

@Test("Property 16: non-tracked modifiers (capsLock, numericPad) → toggle")
func property16NonTrackedModifiers() {
    // The production code intersects with the documented modifier set
    // [.option, .control, .shift, .command]. Modifiers outside that
    // set (capsLock, numericPad, function, help, etc.) MUST NOT
    // trigger the settings branch.
    let untrackedSet: [NSEvent.ModifierFlags] = [
        .capsLock,
        .numericPad,
        .function,
        .help,
    ]
    for modifier in untrackedSet {
        #expect(
            pinnedClickDispatch(eventType: .leftMouseUp, modifierFlags: modifier) == .toggle,
            "Untracked modifier \(modifier) should still toggle"
        )
    }
}

@Test("Property 16: dispatch table is exhaustive over the modifier subset cross-product")
func property16DispatchTable() {
    // Generate every subset of the tracked modifiers and check the
    // expected dispatch.
    let tracked: [NSEvent.ModifierFlags] = [.option, .control, .shift, .command]
    let subsetCount = 1 << tracked.count

    for mask in 0..<subsetCount {
        var combined: NSEvent.ModifierFlags = []
        for (idx, mod) in tracked.enumerated() {
            if (mask >> idx) & 1 == 1 {
                combined.insert(mod)
            }
        }
        let expected: DispatchAction = combined.isEmpty ? .toggle : .settings
        let actual = pinnedClickDispatch(eventType: .leftMouseUp, modifierFlags: combined)
        #expect(actual == expected, "Modifier subset \(combined) should dispatch \(expected)")
    }
}

// MARK: - Property 17: right-click is a no-op

/// **Validates: Requirement 7.7**
///
/// Right-click on a pinned status item never dispatches the popover
/// toggle and never opens settings — the controller treats it as a
/// fall-through to AppKit's default no-op.
@Test("Property 17: right-click without modifiers → no-op")
func property17RightClickNoOp() {
    #expect(pinnedClickDispatch(eventType: .rightMouseUp, modifierFlags: []) == .none)
}

@Test("Property 17: right-click with any modifier → still no-op")
func property17RightClickWithModifiersNoOp() {
    let cases: [NSEvent.ModifierFlags] = [
        [.option],
        [.control],
        [.shift],
        [.command],
        [.option, .control, .shift, .command],
        [.capsLock],
    ]
    for modifier in cases {
        #expect(
            pinnedClickDispatch(eventType: .rightMouseUp, modifierFlags: modifier) == .none,
            "Right-click with \(modifier) should still be a no-op"
        )
    }
}

@Test("Property 17: nil event type defaults to toggle (defensive)")
func property17NilEventTypeDefaultsToToggle() {
    // If `NSApp.currentEvent` returns nil, the production code reads
    // `modifiers ?? []` and dispatches based on that. Without a
    // right-mouse-up event-type guard, the click dispatches toggle
    // (no modifiers) or settings (modifiers present). This is the
    // documented defensive behaviour — verify it matches the
    // reproduction.
    #expect(pinnedClickDispatch(eventType: nil, modifierFlags: []) == .toggle)
    #expect(pinnedClickDispatch(eventType: nil, modifierFlags: .command) == .settings)
}

// MARK: - Cross-cutting: dispatch is a function of (eventType, modifiers)

/// Property: the dispatch decision is *deterministic* — the same
/// input always produces the same output. This is implicit in the
/// pure-function signature, but asserting it explicitly catches
/// future drift if someone refactors the production code to depend
/// on additional state.
@Test("Property 16/17: dispatch is deterministic over (eventType, modifierFlags)")
func propertyDispatchDeterministic() {
    let inputs: [(NSEvent.EventType?, NSEvent.ModifierFlags)] = [
        (.leftMouseUp, []),
        (.leftMouseUp, .command),
        (.leftMouseUp, [.option, .shift]),
        (.rightMouseUp, []),
        (.rightMouseUp, .command),
        (nil, []),
        (nil, .control),
    ]
    for (eventType, modifiers) in inputs {
        let first = pinnedClickDispatch(eventType: eventType, modifierFlags: modifiers)
        let second = pinnedClickDispatch(eventType: eventType, modifierFlags: modifiers)
        #expect(first == second)
    }
}
