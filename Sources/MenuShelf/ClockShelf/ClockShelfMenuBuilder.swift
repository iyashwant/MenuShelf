//
//  ClockShelfMenuBuilder.swift
//  MenuShelf
//
//  Inline menu view item that surfaces the Clock Shelf popover (or an
//  inline submenu of clocks, depending on `presentationMode`) directly
//  from a MenuShelf menu view. Mirrors `ClipboardShelfMenuBuilder` so the
//  rest of the menu code stays free of world-clock-specific concerns.
//

import AppKit
import Foundation

// MARK: - ClockShelfMenuDelegate

/// Lazy-populates a Clock Shelf submenu when it is about to open so the
/// inline clock list reflects the latest minute, the current pinned /
/// visible flags, and the current sort order without needing a status
/// item rebuild. Co-located with the builder extension so the rendering
/// logic and the lazy-populate logic stay in one place, mirroring the
/// `BrowserFlipMenuDelegate` / `BrowserFlipMenuBuilder` pairing.
final class ClockShelfMenuDelegate: NSObject, NSMenuDelegate {
    weak var builder: MenuBuilder?
    let menuViewID: UUID

    init(builder: MenuBuilder, menuViewID: UUID) {
        self.builder = builder
        self.menuViewID = menuViewID
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        builder?.populateClockShelfSubmenu(menu, menuViewID: menuViewID)
    }
}

// MARK: - MenuBuilder extension

extension MenuBuilder {
    /// Append a Clock Shelf entry to `menu`. In `.popover` mode the
    /// entry is a single click target dispatching `.openClockShelf`. In
    /// `.submenu` mode the entry is a parent `NSMenuItem` whose
    /// `submenu` is populated lazily by `ClockShelfMenuDelegate`
    /// (Requirements 1.6, 1.7, 1.12, 1.13, 1.14, 3.5.3, 3.5.4).
    func addClockShelfMenuItem(
        _ config: ClockShelfMenuItemConfig,
        to menu: NSMenu,
        currentSection: inout String?,
        menuViewID: UUID,
        enabled: Bool
    ) {
        // Section header logic (Requirement 1.12) — identical structure
        // to `addClipboardShelfMenuItem`, runs in both presentation modes
        // before the branch.
        let trimmedSection = config.sectionName?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let section = trimmedSection, !section.isEmpty,
           section != currentSection {
            if currentSection != nil
                || menu.items.last?.isSeparatorItem == false {
                menu.addItem(.separator())
            }
            addDisabled(section, to: menu)
            currentSection = section
        }

        let presentationMode = store.settings
            .resolvedClockShelf.resolvedPresentationMode

        // SF Symbol `clock` is the documented icon, with a fallback to
        // `clock.fill` per Requirements 1.6 / 1.7 in case the primary
        // symbol is unavailable on the running system.
        let icon = NSImage(systemSymbolName: "clock", accessibilityDescription: nil)
            ?? NSImage(systemSymbolName: "clock.fill", accessibilityDescription: nil)

        switch presentationMode {
        case .popover:
            // Requirement 1.6 — single click target dispatching
            // `.openClockShelf`. Requirement 1.13 — when the feature is
            // disabled, render the item but mark its tooltip so the
            // click flow lands in settings rather than the popover.
            let item = actionItem(
                config.displayTitle,
                kind: .openClockShelf,
                menuViewID: menuViewID
            )
            item.image = icon
            if !enabled {
                item.toolTip = "Clock Shelf is disabled in MenuShelf settings."
            }
            menu.addItem(item)

        case .submenu:
            // Requirement 1.7 — parent item carries the title and the
            // SF Symbol; its submenu is populated lazily by the
            // delegate so the clock list is rebuilt every time the
            // submenu opens. The parent item itself does not dispatch
            // an action — clicks open the submenu, the trailing items
            // dispatch the actual `.openClockShelf` and
            // `.openClockShelfSettings` actions.
            let parent = NSMenuItem(
                title: config.displayTitle,
                action: nil,
                keyEquivalent: ""
            )
            parent.image = icon
            parent.representedObject = nil

            let submenu = NSMenu(title: config.displayTitle)
            submenu.autoenablesItems = false

            let delegate = ClockShelfMenuDelegate(
                builder: self,
                menuViewID: menuViewID
            )
            submenu.delegate = delegate
            // `NSMenu.delegate` is a weak reference — retain the
            // delegate via `MenuDelegateRetainer` so it stays alive for
            // the menu's lifetime (AGENTS.md §"Lazy menu loading").
            MenuDelegateRetainer.shared.retain(delegate, for: submenu)
            parent.submenu = submenu
            menu.addItem(parent)
        }
    }

    /// Lazy populate path used by `ClockShelfMenuDelegate`. Re-reads
    /// the latest `ClockShelfSettings` on every open so the inline
    /// times reflect the current minute, the current pinned/visible
    /// flags, and the current sort order without needing a status item
    /// rebuild (Requirements 1.8, 1.9, 1.10, 1.11, 3.5.4, 3.5.5).
    func populateClockShelfSubmenu(_ menu: NSMenu, menuViewID: UUID) {
        menu.removeAllItems()
        menu.autoenablesItems = false

        let settings = store.settings.resolvedClockShelf

        if !settings.enableClockShelf {
            // Requirement 1.10 — feature-disabled fallback: a single
            // disabled "Clock Shelf is disabled" item, a separator,
            // and the trailing enabled "Open Settings…" action.
            addDisabled("Clock Shelf is disabled", to: menu)
            menu.addItem(.separator())
            menu.addItem(actionItem(
                "Open Settings…",
                kind: .openClockShelfSettings
            ))
            return
        }

        // Requirement 1.8 — one disabled row per clock with
        // `showInPopover == true`, sorted ascending by `sortOrder`.
        let visible = settings.clocks
            .filter { $0.showInPopover }
            .sorted { $0.sortOrder < $1.sortOrder }

        // `Time_Travel_Offset` is always 0 here (Requirement 1.8 — the
        // submenu is informational only and never displays a
        // travelled time).
        let now = Date()
        for clock in visible {
            let timeString = formatClockShelfTime(
                date: now,
                timeZone: clock.resolvedTimeZone,
                use24HourTime: settings.use24HourTime
            )
            let title: String
            if let emoji = clock.emoji?
                .trimmingCharacters(in: .whitespacesAndNewlines),
               !emoji.isEmpty {
                title = "\(emoji) \(clock.displayLabel)  \(timeString)"
            } else {
                title = "\(clock.displayLabel)  \(timeString)"
            }
            let row = NSMenuItem(
                title: title,
                action: nil,
                keyEquivalent: ""
            )
            // Requirement 1.11 — per-clock rows are informational
            // only: disabled, with no `representedObject`, and no
            // per-row context menu.
            row.isEnabled = false
            row.representedObject = nil
            menu.addItem(row)
        }

        // Requirement 1.9 — trailing actions: separator, then
        // "Open Clock Shelf…" (`.openClockShelf`) carrying the
        // originating `menuViewID` so the controller can resolve the
        // anchor, then "Open Settings…" (`.openClockShelfSettings`).
        menu.addItem(.separator())
        menu.addItem(actionItem(
            "Open Clock Shelf…",
            kind: .openClockShelf,
            menuViewID: menuViewID
        ))
        menu.addItem(actionItem(
            "Open Settings…",
            kind: .openClockShelfSettings
        ))
    }
}
