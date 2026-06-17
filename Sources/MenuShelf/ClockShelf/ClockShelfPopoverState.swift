//
//  ClockShelfPopoverState.swift
//  MenuShelf
//
//  In-memory `@Observable` backing for the Clock Shelf popover SwiftUI
//  tree. Holds the quantized `Time_Travel_Offset`, the row snapshot, and
//  the minute-tick token. Reset on popover dismissal so closing always
//  drops back to live time.
//

import Foundation
import Observation

// MARK: - ClockShelfRowModel

/// Render-ready snapshot of a single clock row in the popover. Built from
/// `ClockConfig` by `ClockShelfController` whenever the visible row set
/// changes; the SwiftUI tree only ever reads these resolved values so
/// formatter work stays out of view bodies.
///
/// `id` matches the originating `ClockConfig.id` so the SwiftUI `ForEach`
/// keeps stable identity across reorders, and so context-menu actions
/// (Edit…, Pin/Unpin, Remove) can resolve the source `ClockConfig`
/// through `store.settings.resolvedClockShelf.clocks.first(where:)`.
struct ClockShelfRowModel: Identifiable, Equatable {
    let id: UUID
    let displayLabel: String
    let emoji: String?
    let timeZone: TimeZone
    let showInPopover: Bool
}

// MARK: - ClockShelfPopoverState

/// Observable state container driving `ClockShelfPopoverView`. The
/// controller owns one instance for the lifetime of the popover panel
/// and resets `timeTravelOffset` on `hidePopover()`/`onClose` so the
/// popover always reopens at live time (Requirements 5.6, 5.7).
@Observable
final class ClockShelfPopoverState {
    /// Shared time-travel offset applied to every visible row. Quantized
    /// to multiples of 900 seconds and clamped to `[-86400, +86400]` by
    /// `ClockShelfController.setTimeTravelOffset(_:)` before assignment,
    /// so SwiftUI bindings always observe an in-spec value.
    var timeTravelOffset: TimeInterval = 0

    /// Bumped by the minute-aligned timer to invalidate row formatters.
    /// SwiftUI rows observe this token so they redraw at each wall-clock
    /// minute boundary even when no other state changes.
    var tickToken: Int = 0

    /// Snapshot of the rows the popover should render this frame. Built
    /// by `ClockShelfController` from the resolved `ClockConfig` list
    /// filtered by `showInPopover` and sorted ascending by `sortOrder`.
    var rows: [ClockShelfRowModel] = []

    /// Identifier the settings flow may pass through
    /// `SettingsWindowController.show(focusClockShelf:scrollToClockID:)`
    /// when "Edit…" is invoked from a row context menu. `nil` when no
    /// row-targeted settings deep-link is pending.
    var focusedClockID: UUID?
}
