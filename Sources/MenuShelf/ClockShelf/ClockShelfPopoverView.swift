//
//  ClockShelfPopoverView.swift
//  MenuShelf
//
//  SwiftUI tree for the Clock Shelf popover. Composed of:
//
//  - `ClockListSection`: vertical list of `ClockRowView`s, one per
//    clock with `showInPopover == true`.
//  - `TimeTravelSection`: horizontal slider, readout, and Reset button.
//  - `OverflowMenuButton`: trailing "…" menu hosting Add Time Zone…,
//    Open Settings…, and Quit MenuShelf.
//
//  The view is driven by a `ClockShelfPopoverState` instance that the
//  controller owns for the lifetime of the panel. State propagates
//  through `@Observable`'s implicit dependency tracking, so a row
//  redraws whenever `state.timeTravelOffset` or `state.tickToken`
//  changes (Requirements 3.4, 3.5, 3.6, 3.7).
//

import AppKit
import SwiftUI

// MARK: - Root view

/// Root popover view. Owns the layout of the four-part popover surface
/// (list, divider, time-travel section, overflow menu).
struct ClockShelfPopoverView: View {
    /// Observed `@Observable` state so SwiftUI redraws when
    /// `timeTravelOffset` (slider drag), `tickToken` (minute tick), or
    /// `rows` (settings change) flip.
    @Bindable var state: ClockShelfPopoverState

    /// Use24HourTime is read from the resolved `ClockShelfSettings` on
    /// every render so toggling the appearance picker takes effect on
    /// the next minute tick without a popover restart.
    private var use24HourTime: Bool {
        AppContainer.shared.store.settings.resolvedClockShelf.use24HourTime
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ClockListSection(state: state, use24HourTime: use24HourTime)

            Divider()
                .padding(.vertical, 4)

            TimeTravelSection(state: state)

            Divider()
                .padding(.vertical, 4)

            HStack {
                Spacer()
                OverflowMenuButton()
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 8)
        }
        .frame(minWidth: 320)
        .background(.background)
    }
}

// MARK: - Clock list section

/// Vertical list of clock rows. Renders nothing visible when the row
/// snapshot is empty so an "empty" popover collapses to just the
/// time-travel and overflow controls.
private struct ClockListSection: View {
    @Bindable var state: ClockShelfPopoverState
    let use24HourTime: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if state.rows.isEmpty {
                emptyState
            } else {
                ForEach(state.rows) { row in
                    ClockRowView(
                        row: row,
                        state: state,
                        use24HourTime: use24HourTime
                    )
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 12)
    }

    private var emptyState: some View {
        HStack(spacing: 8) {
            Image(systemName: "clock")
                .foregroundStyle(.secondary)
            Text("No clocks configured")
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.vertical, 8)
    }
}

// MARK: - Single row

/// One clock row. Reads from `state.rows[i]` (the value-type snapshot)
/// and observes `state.timeTravelOffset` and `state.tickToken` so the
/// time string redraws on slider moves and minute ticks.
private struct ClockRowView: View {
    let row: ClockShelfRowModel
    @Bindable var state: ClockShelfPopoverState
    let use24HourTime: Bool

    var body: some View {
        HStack(spacing: 8) {
            Text(row.emoji ?? "🌐")
                .font(.system(size: 16))
                .frame(width: 22, alignment: .center)

            Text(row.displayLabel)
                .lineLimit(1)
                .truncationMode(.tail)

            Spacer()

            if let offsetString = dayOffsetString {
                Text(offsetString)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Text(timeString)
                .font(.system(.body, design: .rounded))
                .monospacedDigit()
        }
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .contextMenu {
            ClockRowContextMenu(row: row, displayedTimeString: timeString)
        }
    }

    /// Recomputed every frame; reads `state.timeTravelOffset` and
    /// `state.tickToken` so SwiftUI tracks the dependency.
    private var timeString: String {
        // Touch tickToken so SwiftUI tracks the minute-tick dependency.
        // The value itself is unused — the read is what matters for the
        // observer registration.
        _ = state.tickToken
        let projected = Date().addingTimeInterval(state.timeTravelOffset)
        return formatClockShelfTime(
            date: projected,
            timeZone: row.timeZone,
            use24HourTime: use24HourTime
        )
    }

    /// `+N` / `-N` indicator when the projected calendar day differs
    /// from the user's current calendar day. Returns `nil` when the
    /// days match (Requirement 6.4).
    private var dayOffsetString: String? {
        _ = state.tickToken
        let now = Date()
        let projected = now.addingTimeInterval(state.timeTravelOffset)

        var clockCalendar = Calendar.current
        clockCalendar.timeZone = row.timeZone
        let projectedDayStart = clockCalendar.startOfDay(for: projected)

        let userCalendar = Calendar.current
        let userDayStart = userCalendar.startOfDay(for: now)

        // Compute the day difference using the user's calendar so the
        // subtraction is well-defined (the two start-of-day dates are
        // both expressed in the user's calendar but anchored at
        // different wall-clock midnights).
        let diff = userCalendar.dateComponents(
            [.day],
            from: userDayStart,
            to: projectedDayStart
        ).day ?? 0

        if diff == 0 { return nil }
        if diff > 0 { return "+\(diff)" }
        return "-\(abs(diff))"
    }
}

// MARK: - Context menu

/// Per-row context menu (Requirement 7.1). Items in the documented
/// order: Copy Time, Copy Time Zone Identifier, Edit…, Pin/Unpin,
/// Remove.
private struct ClockRowContextMenu: View {
    let row: ClockShelfRowModel
    let displayedTimeString: String

    private var store: PreferencesStore { AppContainer.shared.store }

    /// Resolve the live `ClockConfig` so the menu reflects the current
    /// `pinToMenuBar` value. The popover row model is a snapshot — it
    /// captures `id` but not the live pin state, which can change while
    /// the context menu is open (e.g. via the settings pane).
    private var liveClock: ClockConfig? {
        store.settings.resolvedClockShelf.clocks.first { $0.id == row.id }
    }

    var body: some View {
        Button("Copy Time") {
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(displayedTimeString, forType: .string)
        }

        Button("Copy Time Zone Identifier") {
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(row.timeZone.identifier, forType: .string)
        }

        Button("Edit…") {
            // Open the settings window focused on the Clock Shelf pane
            // and scroll the Clocks list to this row. The
            // `scrollToClockID` parameter on
            // `SettingsWindowController.show(...)` posts the
            // `.menuShelfScrollToClockShelf` notification carrying the
            // target UUID; `ClockShelfSettingsView` observes that
            // notification and drives a `ScrollViewReader` to the
            // matching row.
            AppContainer.shared.settingsWindowController.show(
                focusClockShelf: true,
                scrollToClockID: row.id
            )
        }

        if let live = liveClock {
            Button(live.pinToMenuBar ? "Unpin from Menu Bar" : "Pin to Menu Bar") {
                var updated = live
                updated.pinToMenuBar.toggle()
                store.updateClockShelf(updated)
            }
        }

        Divider()

        Button("Remove Clock", role: .destructive) {
            store.removeClockShelf(id: row.id)
        }
    }
}

// MARK: - Time travel section

/// Slider (-24h…+24h, 15-minute steps), readout, and Reset button.
/// The slider's `offsetBinding` flows through
/// `ClockShelfController.shared.setTimeTravelOffset(_:)` so the
/// controller's 100ms coalescer governs redraw cadence (Requirements
/// 5.1, 5.2, 5.3, 5.4, 5.5).
private struct TimeTravelSection: View {
    @Bindable var state: ClockShelfPopoverState

    private var offsetBinding: Binding<Double> {
        Binding(
            get: { state.timeTravelOffset },
            set: { newValue in
                ClockShelfController.shared.setTimeTravelOffset(newValue)
            }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Time Travel")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Text(readout)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 8) {
                // No `step:` here — the controller's
                // `quantizeAndClampOffset(_:)` already snaps the value
                // to 15-minute increments. Passing `step:` to
                // SwiftUI's Slider causes AppKit to render a row of
                // tick marks under the track (192 dashes across the
                // full -24h…+24h range), which reads as a band of
                // tiny text on macOS. Quantizing in the binding setter
                // gives the same behaviour without the visual noise.
                Slider(
                    value: offsetBinding,
                    in: -86_400...86_400
                )
                .accessibilityLabel("Time Travel")

                Button("Reset") {
                    ClockShelfController.shared.resetTimeTravelOffset()
                }
                .buttonStyle(.borderless)
                .disabled(state.timeTravelOffset == 0)
            }
        }
        .padding(.horizontal, 12)
    }

    /// Formatter producing "Now", "+H:MM", or "-H:MM" with zero-padded
    /// minutes (Requirement 5.4).
    private var readout: String {
        timeTravelReadout(state.timeTravelOffset)
    }
}

/// Format the slider readout. Pulled out as a free function so it can
/// be unit-tested directly from any property test that needs to assert
/// the string shape.
func timeTravelReadout(_ offset: TimeInterval) -> String {
    if offset == 0 { return "Now" }
    let totalMinutes = Int(abs(offset) / 60)
    let hours = totalMinutes / 60
    let minutes = totalMinutes % 60
    let sign = offset > 0 ? "+" : "-"
    return String(format: "%@%d:%02d", sign, hours, minutes)
}

// MARK: - Overflow menu

/// Trailing "…" menu (Requirements 3.10, 3.11). Three items in the
/// documented order: Add Time Zone…, Open Settings…, Quit MenuShelf.
/// Cmd+`+` is bound to "Add Time Zone…" so the overflow flow is
/// keyboard-reachable while the popover is open.
private struct OverflowMenuButton: View {
    var body: some View {
        Menu {
            Button("Add Time Zone…") {
                openAddTimeZone()
            }
            .keyboardShortcut("+", modifiers: .command)

            Button("Open Settings…") {
                AppContainer.shared.settingsWindowController.show(focusClockShelf: true)
            }

            Divider()

            Button("Quit MenuShelf") {
                NSApp.terminate(nil)
            }
        } label: {
            Image(systemName: "ellipsis.circle")
                .imageScale(.large)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    /// "Add Time Zone…" opens the settings window focused on the World
    /// Clock pane. The settings pane already provides the searchable
    /// "Add Clock" sheet, so reusing that surface keeps the popover
    /// minimal. A future revision could surface a dedicated sheet
    /// directly inside the popover.
    private func openAddTimeZone() {
        AppContainer.shared.settingsWindowController.show(focusClockShelf: true)
    }
}
