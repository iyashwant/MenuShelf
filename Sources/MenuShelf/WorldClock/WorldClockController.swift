//
//  WorldClockController.swift
//  MenuShelf
//
//  Single integration seam between MenuShelf and the World Clock module.
//  Owns the floating popover panel, the per-clock pinned `NSStatusItem`s,
//  the minute-aligned refresh tick, and the global popup hotkey
//  registration. Everything outside `Sources/MenuShelf/WorldClock/`
//  talks to this controller and nothing else from the module.
//

import AppKit
import Combine
import Foundation
import KeyboardShortcuts

@MainActor
final class WorldClockController {
    static let shared = WorldClockController()

    private init() {}

    // MARK: - Internal state

    /// Floating popover hosting the SwiftUI tree. Lazily allocated on
    /// first `showPopover(anchor:)` and reused for every subsequent
    /// open/close cycle so the SwiftUI tree (and its `@Observable`
    /// state subscriptions) survives across dismissals.
    private var panel: WorldClockPanel?

    /// `@Observable` backing for the popover SwiftUI tree. The
    /// controller owns one instance for its lifetime; SwiftUI rows
    /// observe `tickToken` and `timeTravelOffset` so a single shared
    /// state object drives every redraw.
    private let popoverState = WorldClockPopoverState()

    /// One entry per `ClockConfig.pinToMenuBar == true`. Ordering lives
    /// in `pinnedOrder` so the controller can recreate items
    /// left-to-right matching `ClockConfig.sortOrder` (Requirement 4.11).
    private var pinnedItems: [UUID: PinnedClockContext] = [:]

    /// Companion to `pinnedItems` carrying the visual menu-bar order.
    private var pinnedOrder: [UUID] = []

    /// Wall-clock-minute-aligned `Timer`. Alive iff the feature is
    /// enabled and at least one observer exists (popover visible or any
    /// pinned clock). See the pause/resume table in the design.
    private var minuteTimer: Timer?

    /// 100ms `DispatchWorkItem` coalescer used by the time-travel
    /// slider so a continuous drag does not redraw on every frame.
    private var coalesceWorkItem: DispatchWorkItem?

    /// Snapshot of the last settings passed through `apply(settings:)`,
    /// used as the diff base for the next reconcile pass.
    private var lastAppliedSettings: WorldClockSettings?

    /// Token returned by `KeyboardShortcuts.onKeyDown(for:)` so the
    /// hotkey can be detached on `stop()`.
    private var lastSubscriptionToken: Any?

    // MARK: - Helper types

    /// Bookkeeping for a single pinned `NSStatusItem`. Carries the
    /// originating `clockID` so click handling can resolve back to the
    /// source `ClockConfig` without walking the settings array.
    private struct PinnedClockContext {
        let clockID: UUID
        let item: NSStatusItem
    }

    // MARK: - Lifecycle

    /// Idempotent. Builds the floating panel, the pinned status items,
    /// the minute-aligned timer, and registers the popup hotkey when
    /// called for the first time. Subsequent calls forward to
    /// `apply(settings:)`.
    func start(with settings: WorldClockSettings) {
        // Register the global popup hotkey before the diff-based
        // reconcile so a hotkey press immediately after `start(with:)`
        // returns finds a wired callback (Requirement 9.1). The
        // registration token is stashed on `lastSubscriptionToken` so
        // `stop()` can detach it without holding a strong reference to
        // the closure (`KeyboardShortcuts.onKeyDown` returns `Void`,
        // so the "token" is a sentinel marking that the registration
        // exists; the actual detach happens through
        // `KeyboardShortcuts.disable(.worldClockPopup)`).
        KeyboardShortcuts.onKeyDown(for: .worldClockPopup) { [weak self] in
            self?.handleHotkeyToggle()
        }
        lastSubscriptionToken = KeyboardShortcuts.Name.worldClockPopup

        // Forward to `apply(settings:)` so the very first call also
        // runs the diff-based reconcile and allocates pinned status
        // items for any clock with `pinToMenuBar == true`. Without
        // this, `start(with:)` would only set up the timer and the
        // pinned items would not appear until the next settings
        // change pushed through the Combine subscription.
        apply(settings: settings)
    }

    /// Tear down every observable surface (panel, pinned items, timer,
    /// hotkey) and reset `Time_Travel_Offset` to zero.
    func stop() {
        minuteTimer?.invalidate()
        minuteTimer = nil

        // Drop any pending coalesced slider redraw so a fresh
        // `start(with:)` does not see a stale offset assignment fire
        // 100ms after teardown.
        coalesceWorkItem?.cancel()
        coalesceWorkItem = nil

        // Hide the popover before tearing down the rest of the
        // observable surface so an outside-click reopen does not race
        // with the teardown.
        panel?.close()

        // Remove every pinned `NSStatusItem` from the menu bar within
        // 1s of the controller stopping, satisfying Requirement 4.12
        // (no pinned items survive while `enableWorldClock == false`)
        // and Requirement 4.10 (a removed clock's status item is
        // released within 1s when the feature is disabled).
        for ctx in pinnedItems.values {
            NSStatusBar.system.removeStatusItem(ctx.item)
            // Verbose-only structural log — UUID only, never the
            // clock's label, emoji, time zone identifier, or any
            // formatted time (Requirements 11.3, 11.4).
            logIfVerbose("WorldClock pinned remove id=\(ctx.clockID.uuidString)")
        }
        pinnedItems.removeAll()
        pinnedOrder.removeAll()

        // Drop back to live time so a future `start(with:)` does not
        // resurrect a stale time-travel offset (Requirement 5.6 — the
        // popover dismissal path resets the offset, and `stop()` is
        // the lifecycle-equivalent for the whole feature).
        popoverState.timeTravelOffset = 0
        popoverState.rows = []

        // Detach the global popup hotkey so a press after `stop()`
        // returns is a no-op (Requirement 9.2). `KeyboardShortcuts
        // .disable(_:)` removes the registered callback; clearing the
        // sentinel token afterwards keeps `lastSubscriptionToken` in
        // sync with the registration state so a follow-up
        // `start(with:)` re-registers cleanly.
        KeyboardShortcuts.disable(.worldClockPopup)
        lastSubscriptionToken = nil
    }

    /// Push a new settings snapshot through. When `enableWorldClock`
    /// is `false` this collapses to `stop()`. Otherwise the call
    /// reconciles `pinnedItems` against the new desired set, refreshes
    /// every surviving title in place, and recomputes the timer
    /// pause/resume decision.
    func apply(settings: WorldClockSettings) {
        guard settings.enableWorldClock else {
            // Tear down every pinned item and pause the timer. We
            // still record the snapshot so a subsequent `apply(...)`
            // call with `enableWorldClock == true` rebuilds from a
            // known baseline (Requirement 4.12).
            stop()
            lastAppliedSettings = settings
            return
        }

        // Step 1: compute the desired pinned set in `sortOrder` order.
        // Sort ascending so the controller's internal `pinnedOrder`
        // tracks `ClockConfig.sortOrder` left-to-right (Requirement
        // 4.11). macOS does not let third-party apps reposition
        // existing status items between releases, so the visual order
        // only realigns on teardown-and-recreate; the controller
        // still keeps its book matching `sortOrder` so future
        // reconciles produce correct positions whenever items are
        // dropped and re-allocated.
        let desired = settings.clocks
            .filter { $0.pinToMenuBar }
            .sorted { $0.sortOrder < $1.sortOrder }
        let desiredIDs = Set(desired.map(\.id))

        // Step 2: tear down any `id` no longer present in `desired`,
        // including clocks whose `pinToMenuBar` flipped from `true`
        // to `false` (Requirement 4.7) and clocks the user removed
        // entirely (Requirement 4.10).
        let removedIDs = pinnedItems.keys.filter { !desiredIDs.contains($0) }
        for clockID in removedIDs {
            if let ctx = pinnedItems[clockID] {
                NSStatusBar.system.removeStatusItem(ctx.item)
            }
            pinnedItems.removeValue(forKey: clockID)
            // Verbose-only structural log — UUID only, never the
            // clock's label, emoji, time zone identifier, or any
            // formatted time (Requirements 11.3, 11.4).
            logIfVerbose("WorldClock pinned remove id=\(clockID.uuidString)")
        }

        // Step 3: allocate `NSStatusItem(withLength:
        // NSStatusItem.variableLength)` for every newly-pinned
        // `ClockConfig` (Requirement 4.2, 4.6) and wire its click
        // handler (Task 5.3 — Requirements 4.8, 4.9). The
        // `sendAction(on:)` mask matches `StatusItemManager` so
        // right-click falls through to the AppKit default no-op
        // (Requirement 7.7) and only left-mouse-up / right-mouse-up
        // events ever reach `handlePinnedClick(_:)`.
        for clock in desired where pinnedItems[clock.id] == nil {
            let item = NSStatusBar.system.statusItem(
                withLength: NSStatusItem.variableLength
            )
            if let button = item.button {
                button.sendAction(on: [.leftMouseUp, .rightMouseUp])
                button.target = self
                button.action = #selector(handlePinnedClick(_:))
            }
            pinnedItems[clock.id] = PinnedClockContext(
                clockID: clock.id,
                item: item
            )
            // Verbose-only structural log — UUID only, never the
            // clock's label, emoji, time zone identifier, or any
            // formatted time (Requirements 11.3, 11.4).
            logIfVerbose("WorldClock pinned create id=\(clock.id.uuidString)")
        }

        // Step 4: realign `pinnedOrder` to match the desired
        // `sortOrder` exactly. macOS will not visually reorder items
        // already attached to the menu bar, but the controller's
        // internal book stays in spec so any future teardown +
        // re-allocation (e.g. user toggles `pinToMenuBar` off then
        // on) produces a left-to-right order matching `sortOrder`
        // (Requirement 4.11).
        pinnedOrder = desired.map(\.id)

        // Step 5: refresh the snapshot before redrawing titles so the
        // formatter sees the new clocks, labels, emoji, and
        // `use24HourTime` flag.
        lastAppliedSettings = settings

        // Step 6: rewrite every pinned status item's title in place.
        // This covers both the new allocations (which start with an
        // empty title) and the surviving items whose visible state
        // changed (emoji, label, timeZoneIdentifier, time-format
        // settings — Requirement 4.6 surface invariant).
        redrawPinnedTitles()

        // Step 6b: refresh the popover row snapshot when the popover
        // is visible so live settings edits (added clock, emoji
        // change, sort reorder) appear without requiring a popover
        // restart. Skipped while the popover is closed since the
        // snapshot is rebuilt on the next `showPopover(anchor:)`.
        if panel?.isPresented == true {
            rebuildRowSnapshot()
        }

        // Step 7: recompute the timer pause/resume decision (Task 4.2).
        // After a reconcile, `anyPinned` may have flipped in either
        // direction, and the timer state must follow.
        evaluateTimerLifecycle()
    }

    // MARK: - Popover

    /// Toggle the popover. `anchor` is the originating status button
    /// when invoked from a menu click or a pinned clock click; `nil`
    /// falls back to the anchor-resolution chain in Requirement 9.3.
    func togglePopover(anchor: NSStatusBarButton?) {
        if panel?.isPresented == true {
            hidePopover()
        } else {
            showPopover(anchor: anchor)
        }
    }

    /// Show the popover unconditionally (no toggle). Used by the menu
    /// action when the click should always open the popover.
    func showPopover(anchor: NSStatusBarButton?) {
        // Lazily allocate the panel on first show so an idle World Clock
        // pays no panel-allocation cost. The panel and its SwiftUI tree
        // outlive subsequent dismissals so `@Observable` subscriptions
        // are preserved.
        let panel = ensurePanel()

        // Refresh the row snapshot so the popover renders the current
        // clock list. Pulling the snapshot here (rather than on every
        // settings change) keeps `apply(settings:)` cheap when the
        // popover is closed.
        rebuildRowSnapshot()

        panel.open(at: anchor)
        evaluateTimerLifecycle()

        // Verbose-only structural log — counts only, never any
        // user-supplied label, emoji, time string, or timeZone
        // identifier (Requirements 11.3, 11.4).
        logIfVerbose("WorldClock popover open")
    }

    /// Hide the popover within 200ms and reset `Time_Travel_Offset`
    /// to zero (Requirement 5.6). The reset is also wired through the
    /// panel's `onClose` callback so an outside-click dismissal goes
    /// through the same path.
    func hidePopover() {
        panel?.close()
        // The panel's `onClose` callback resets the offset, but call
        // through here too so a programmatic `hidePopover()` from a
        // code path that bypasses the AppKit close machinery (e.g. a
        // test harness) still drops back to live time.
        resetTimeTravelOffset()
        evaluateTimerLifecycle()
    }

    /// Global hotkey callback. Toggles the popover and, when showing,
    /// resolves the anchor in the priority order documented in the
    /// design's *Anchor fallback chain* (Requirements 9.3, 9.4):
    ///
    /// 1. The first button in `pinnedOrder` (the leftmost pinned
    ///    `NSStatusItem` matching `ClockConfig.sortOrder`).
    /// 2. The status button for the first menu view in
    ///    `resolvedMenuViews` whose `worldClockItem != nil`, resolved
    ///    via `AppContainer.shared.statusItemManager.statusBarButton(for:)`.
    /// 3. `nil`, which lets `WorldClockPanel.open(at:)` fall back to
    ///    centering on the active screen.
    ///
    /// When the popover is already visible, the press hides it
    /// regardless of the resolved anchor — the `togglePopover` flow
    /// owns the show/hide decision and `hidePopover()` ignores
    /// anchors.
    private func handleHotkeyToggle() {
        if panel?.isPresented == true {
            hidePopover()
            return
        }

        // Step 1: leftmost pinned status item.
        if let firstPinnedID = pinnedOrder.first,
           let button = pinnedItems[firstPinnedID]?.item.button {
            showPopover(anchor: button)
            return
        }

        // Step 2: first menu view in `resolvedMenuViews` order whose
        // `worldClockItem != nil`. Reaching directly into
        // `AppContainer.shared` keeps the controller's API
        // unchanged; the dependency on `AppContainer` already exists
        // in `openSettingsForClock(_:)` above.
        let resolvedViews = AppContainer.shared.store.settings.resolvedMenuViews
        if let menuView = resolvedViews.first(where: { $0.worldClockItem != nil }),
           let button = AppContainer.shared.statusItemManager
               .statusBarButton(for: menuView.id) {
            showPopover(anchor: button)
            return
        }

        // Step 3: no anchor — `WorldClockPanel.open(at:)` centers the
        // panel on the active screen.
        showPopover(anchor: nil)
    }

    /// Lazily build the popover panel on first `showPopover`. The
    /// `onClose` callback wired here calls `resetTimeTravelOffset()`
    /// so dismissals from any path (outside click, Esc, programmatic
    /// `close()`) all drop back to live time within 200ms (Requirement
    /// 5.6).
    private func ensurePanel() -> WorldClockPanel {
        if let panel { return panel }
        let panel = WorldClockPanel(
            popoverState: popoverState,
            onClose: { [weak self] in
                Task { @MainActor [weak self] in
                    self?.resetTimeTravelOffset()
                    self?.evaluateTimerLifecycle()
                    // Verbose-only structural log — fired once per
                    // close cycle (programmatic, outside-click, or
                    // Esc) since AppKit drives this callback for
                    // every dismissal path. Counts only (Requirements
                    // 11.3, 11.4).
                    self?.logIfVerbose("WorldClock popover close")
                }
            }
        )
        self.panel = panel
        return panel
    }

    /// Refresh `popoverState.rows` from the last-applied settings
    /// snapshot. Filters by `showInPopover` and sorts ascending by
    /// `sortOrder` so the popover row order matches the spec.
    private func rebuildRowSnapshot() {
        guard let settings = lastAppliedSettings else {
            popoverState.rows = []
            return
        }
        let visible = settings.clocks
            .filter { $0.showInPopover }
            .sorted { $0.sortOrder < $1.sortOrder }
        popoverState.rows = visible.map { clock in
            WorldClockRowModel(
                id: clock.id,
                displayLabel: clock.displayLabel,
                emoji: clock.emoji,
                timeZone: clock.resolvedTimeZone,
                showInPopover: clock.showInPopover
            )
        }
    }

    // MARK: - Time travel

    /// Set the shared `Time_Travel_Offset`. The input is quantized to
    /// the nearest 900 seconds and clamped to `[-86400, +86400]`
    /// before being stored, then a 100ms `DispatchWorkItem` coalescer
    /// fires the downstream redraws (Requirements 5.2, 10.4).
    func setTimeTravelOffset(_ offset: TimeInterval) {
        let quantized = quantizeAndClampOffset(offset)

        // Cancel any pending coalesced work so a continuous slider drag
        // collapses into a single trailing redraw 100ms after the user
        // stops moving (Requirement 10.4).
        coalesceWorkItem?.cancel()

        let workItem = DispatchWorkItem { [weak self] in
            // The work item is scheduled on `DispatchQueue.main`, which
            // serves the main run loop the controller's `@MainActor`
            // isolation runs on. Hop explicitly so the assignments and
            // the helper call observe `@MainActor` isolation.
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.popoverState.timeTravelOffset = quantized
                self.redrawPinnedTitles()
                // SwiftUI rows observe `popoverState.timeTravelOffset`
                // directly through `@Observable`, so the assignment
                // above is sufficient to re-render the popover rows.
            }
        }
        coalesceWorkItem = workItem
        DispatchQueue.main.asyncAfter(
            deadline: .now() + 0.1,
            execute: workItem
        )
    }

    /// Reset `Time_Travel_Offset` to zero and trigger an immediate
    /// redraw of every visible row and pinned status item. Called from
    /// the popover's "Reset" button and on popover dismissal so pinned
    /// status items return to live time within 100ms (Requirement 5.5)
    /// and 200ms (Requirement 5.6) respectively.
    func resetTimeTravelOffset() {
        // Drop any in-flight coalesced slider redraw so the reset is
        // not immediately overwritten by a stale work item.
        coalesceWorkItem?.cancel()
        coalesceWorkItem = nil

        popoverState.timeTravelOffset = 0
        redrawPinnedTitles()
    }

    // MARK: - Time travel helpers

    /// Quantize `offset` to the nearest 900s step and clamp the result
    /// to `[-86400, +86400]`. Performed inside `setTimeTravelOffset`
    /// so an upstream `Slider` configured with a non-quantized step
    /// still cannot drive `Time_Travel_Offset` to an off-step value
    /// (Requirement 5.2).
    private func quantizeAndClampOffset(_ offset: TimeInterval) -> TimeInterval {
        let step: TimeInterval = 900
        let quantized = (offset / step).rounded() * step
        return max(-86400, min(86400, quantized))
    }

    /// Rewrite every pinned status item's title in place using the
    /// current `popoverState.timeTravelOffset` and the last-applied
    /// settings snapshot. Reuses the same logic as the minute-timer
    /// fire path so manual offset changes (slider, reset) and the
    /// scheduled minute boundary share one source of truth.
    private func redrawPinnedTitles() {
        let offset = popoverState.timeTravelOffset
        let now = Date().addingTimeInterval(offset)
        let settings = lastAppliedSettings
        let clocksByID: [UUID: ClockConfig] =
            Dictionary(uniqueKeysWithValues:
                (settings?.clocks ?? []).map { ($0.id, $0) }
            )

        for clockID in pinnedOrder {
            guard let ctx = pinnedItems[clockID],
                  let button = ctx.item.button else { continue }
            let title: String
            if let clock = clocksByID[clockID] {
                title = formatPinnedTitle(
                    clock: clock,
                    date: now,
                    use24HourTime: settings?.use24HourTime ?? false
                )
            } else {
                title = ""
            }
            button.title = title
        }
    }

    // MARK: - Test seam

    /// Returns the `NSStatusBarButton` for the pinned status item
    /// associated with `clockID`, or `nil` when no such item exists.
    /// Exposed so settings deep-links can resolve a clock back to its
    /// menu-bar anchor.
    func statusBarButton(forClockID clockID: UUID) -> NSStatusBarButton? {
        return pinnedItems[clockID]?.item.button
    }

    // MARK: - Pinned status item click handling

    /// AppKit click target for every pinned `NSStatusItem`. Resolves
    /// the originating `clockID` by matching the sender against the
    /// stored `PinnedClockContext`s (the button does not carry the
    /// `UUID` directly), inspects `NSApp.currentEvent` for the event
    /// type and modifier flags, and dispatches one of three branches:
    ///
    /// - right-click → no-op, falls through to AppKit's default
    ///   behaviour (Requirement 7.7);
    /// - left-click without modifiers → toggle the popover anchored to
    ///   the clicked button (Requirement 4.8);
    /// - left-click with any of option / control / shift / command →
    ///   open the settings window deep-linked to the clock's row
    ///   (Requirement 4.9). Option-click is the documented affordance;
    ///   the broader modifier set matches the spirit of "any
    ///   modifier-included left click" called out in the design.
    ///
    /// `sender` is `Any?` per the AppKit selector contract, so it is
    /// cast to `NSStatusBarButton` before resolving the clock.
    @MainActor
    @objc private func handlePinnedClick(_ sender: Any?) {
        guard let button = sender as? NSStatusBarButton else { return }

        // Resolve which `clockID` the button belongs to. The button
        // does not carry the UUID directly, so iterate `pinnedItems`
        // and match by identity.
        let buttonIdentity = ObjectIdentifier(button)
        let resolvedClockID = pinnedItems.first { _, ctx in
            guard let candidate = ctx.item.button else { return false }
            return ObjectIdentifier(candidate) == buttonIdentity
        }?.key

        guard let clockID = resolvedClockID else { return }

        let event = NSApp.currentEvent
        if event?.type == .rightMouseUp {
            // Requirement 7.7 — right-click on a pinned status item
            // is a no-op in v1; no settings deep-link, no popover
            // toggle. Returning here matches AppKit's default no-op.
            return
        }

        let modifiers = event?.modifierFlags ?? []
        let modifierKeys: NSEvent.ModifierFlags = [
            .option, .control, .shift, .command,
        ]
        let hasModifier = !modifiers.intersection(modifierKeys).isEmpty

        if hasModifier {
            openSettingsForClock(clockID)
        } else {
            togglePopover(anchor: button)
        }
    }

    /// Open the settings window focused on the World Clock pane and
    /// scrolled to the row for `clockID`. Wraps the deep-link call so
    /// the click handler stays focused on dispatch.
    private func openSettingsForClock(_ clockID: UUID) {
        AppContainer.shared.settingsWindowController.show(
            focusWorldClock: true,
            scrollToClockID: clockID
        )
    }

    // MARK: - Verbose diagnostics

    /// Forward `message` to `DiagnosticsLogger.shared.log(_:)` when (and
    /// only when) the user has flipped on `enableVerboseDiagnostics` in
    /// settings. Mirrors `ClipboardShelfController.logPopupActivation
    /// (action:source:)` so the World Clock module logs at the same
    /// verbosity level the rest of MenuShelf uses (Requirements 11.3,
    /// 11.4).
    ///
    /// Privacy rails (Requirement 11.3, 11.4): every call site here
    /// passes only structural information — clock counts, UUIDs, and
    /// popover-visible booleans. `clock.label`, `clock.emoji`,
    /// formatted time strings, and `clock.timeZoneIdentifier` MUST
    /// NEVER appear in `message`. Property 28 enforces this from the
    /// outside.
    private func logIfVerbose(_ message: String) {
        guard AppContainer.shared.store.settings
            .resolvedEnableVerboseDiagnostics else { return }
        DiagnosticsLogger.shared.log(message)
    }

    // MARK: - Timer lifecycle

    /// Recompute the minute-timer pause/resume decision from the three
    /// boolean inputs documented in the design's state diagram:
    ///
    /// - `enabled`        = `lastAppliedSettings?.enableWorldClock`
    /// - `anyPinned`      = `!pinnedItems.isEmpty`
    /// - `popoverVisible` = `panel?.isVisible == true`
    ///
    /// The timer is alive iff `enabled && (anyPinned || popoverVisible)`;
    /// otherwise it is invalidated and set to `nil` so an idle, disabled,
    /// or unobserved World Clock costs nothing at runtime
    /// (Requirements 10.1, 10.2, 10.3, 10.5).
    private func evaluateTimerLifecycle() {
        let enabled = lastAppliedSettings?.enableWorldClock ?? false
        let anyPinned = !pinnedItems.isEmpty
        let popoverVisible = panel?.isVisible == true
        let shouldRun = enabled && (anyPinned || popoverVisible)

        if shouldRun {
            if minuteTimer == nil {
                scheduleMinuteTimer()
            }
        } else {
            minuteTimer?.invalidate()
            minuteTimer = nil
        }
    }

    /// Schedule a wall-clock-minute-aligned `Timer` that fires at the
    /// next minute boundary plus a 0.5s shim and repeats every 60s
    /// thereafter. The shim absorbs scheduler jitter so titles never
    /// read as the previous minute (Requirement 3.8 caps the upper
    /// bound at 1s).
    private func scheduleMinuteTimer() {
        let now = Date()
        let nextMinute = Calendar.current.nextDate(
            after: now,
            matching: DateComponents(second: 0),
            matchingPolicy: .strict
        ) ?? now.addingTimeInterval(60)
        let firstFire = nextMinute.addingTimeInterval(0.5)

        let timer = Timer(
            fire: firstFire,
            interval: 60,
            repeats: true
        ) { [weak self] _ in
            // `Timer` callbacks deliver on the main run loop here, but
            // dispatch back to the main actor explicitly so the
            // controller's `@MainActor` isolation is honoured.
            Task { @MainActor [weak self] in
                self?.handleMinuteTimerFire()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        minuteTimer = timer
    }

    /// One tick of the minute timer. Recomputes the projected `now`,
    /// rewrites every pinned status item's title in place, and bumps
    /// `popoverState.tickToken` so SwiftUI rows redraw.
    private func handleMinuteTimerFire() {
        redrawPinnedTitles()
        popoverState.tickToken &+= 1

        // Verbose-only structural log — clock count and popover
        // visibility only, never any user-supplied label, emoji,
        // time zone identifier, or formatted time (Requirements 11.3,
        // 11.4).
        logIfVerbose(
            "WorldClock minute tick clocks=\(pinnedItems.count) "
            + "popover=\(panel?.isPresented == true)"
        )
    }

    /// Compose a pinned status item title from `clock` and `date`.
    /// Delegates the time formatting to the file-scope
    /// `formatWorldClockTime(date:timeZone:use24HourTime:)` helper so
    /// the pinned item path, the popover row pipeline, and the submenu
    /// populator (Task 7.3) all share a single formatter implementation
    /// (Requirements 4.3, 6.5).
    private func formatPinnedTitle(
        clock: ClockConfig,
        date: Date,
        use24HourTime: Bool
    ) -> String {
        let timeString = formatWorldClockTime(
            date: date,
            timeZone: clock.resolvedTimeZone,
            use24HourTime: use24HourTime
        )
        if let emoji = clock.emoji?.trimmingCharacters(in: .whitespacesAndNewlines),
           !emoji.isEmpty {
            return "\(emoji) \(timeString)"
        }
        return timeString
    }
}

// MARK: - Shared time formatter

/// Format `date` for display in the user's preferred World Clock time
/// representation. Reused from the pinned status item title path
/// (Task 5.4), the popover row pipeline (Task 6.3), and the submenu
/// populator (Task 7.3) so every World Clock surface renders identical
/// time strings.
///
/// - Parameters:
///   - date: The instant to render. Callers project the
///     `Time_Travel_Offset` into this value before calling.
///   - timeZone: The clock's resolved IANA `TimeZone`.
///   - use24HourTime: When `true`, force a 24-hour `HH:mm` format
///     regardless of locale (Requirement 3.7). When `false`, render the
///     locale's short time style via `Date.FormatStyle` (Requirement 3.6).
///
/// The helper is intentionally declared at file scope (not inside the
/// `@MainActor` controller) so the popover row pipeline and the
/// submenu populator can call it from their own files in the same
/// module without crossing actor boundaries. `DateFormatter` and
/// `Date.FormatStyle` are both safe to construct per-call here; the
/// World Clock formats at most a few dozen rows at minute boundaries
/// or during slider drags, so the allocation cost is irrelevant.
func formatWorldClockTime(
    date: Date,
    timeZone: TimeZone,
    use24HourTime: Bool
) -> String {
    if use24HourTime {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: date)
    }

    var style = Date.FormatStyle()
        .locale(.current)
        .hour(.defaultDigits(amPM: .abbreviated))
        .minute(.twoDigits)
    style.timeZone = timeZone
    return date.formatted(style)
}
