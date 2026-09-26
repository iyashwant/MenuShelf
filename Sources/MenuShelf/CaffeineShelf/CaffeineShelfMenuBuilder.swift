//
//  CaffeineShelfMenuBuilder.swift
//  MenuShelf
//
//  Inline menu view item that surfaces the CaffeineShelf popup directly
//  from a MenuShelf menu view. Mirrors `ClockShelfMenuBuilder` so the
//  rest of the menu code stays free of caffeine-shelf-specific concerns.
//

import AppKit

extension MenuBuilder {
    /// Append a CaffeineShelf menu item to `menu` as a parent `NSMenuItem`
    /// whose `submenu` is populated lazily by `CaffeineShelfMenuDelegate`.
    ///
    /// Unlike ClockShelf and ClipboardShelf, CaffeineShelf has no rich popover
    /// UI to offer as an alternative surface — its standalone popup is the very
    /// same NSMenu, presented by temporarily swapping the host status item's
    /// menu. Embedding that as a click target meant the host menu view closed
    /// and reopened as the caffeine menu, and silently no-opped whenever the
    /// menu view had no resolvable status item. So an embedded CaffeineShelf is
    /// always a real submenu, matching Browser Flip and Bookmark Shelf.
    func addCaffeineShelfMenuItem(
        _ config: CaffeineShelfMenuItemConfig,
        to menu: NSMenu,
        currentSection: inout String?,
        menuViewID: UUID,
        enabled: Bool
    ) {
        let trimmedSection = config.sectionName?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let section = trimmedSection, !section.isEmpty, section != currentSection {
            if currentSection != nil || menu.items.last?.isSeparatorItem == false {
                menu.addItem(.separator())
            }
            addDisabled(section, to: menu)
            currentSection = section
        }

        let icon = NSImage(systemSymbolName: "cup.and.saucer", accessibilityDescription: nil)
            ?? NSImage(systemSymbolName: "cup.and.saucer.fill", accessibilityDescription: nil)

        let parent = NSMenuItem(
            title: config.displayTitle,
            action: nil,
            keyEquivalent: ""
        )
        parent.image = icon
        parent.representedObject = nil
        if !enabled {
            parent.toolTip = "CaffeineShelf is disabled in MenuShelf settings."
        }

        let submenu = NSMenu(title: config.displayTitle)
        submenu.autoenablesItems = false

        // The delegate re-populates on every open so duration checkmarks and
        // the awake status line reflect live controller state. The retainer
        // keeps it alive because `NSMenu.delegate` is weak.
        let delegate = CaffeineShelfMenuDelegate(builder: self)
        submenu.delegate = delegate
        MenuDelegateRetainer.shared.retain(delegate, for: submenu)
        parent.submenu = submenu
        menu.addItem(parent)
    }

    /// Lazy populate path used by `CaffeineShelfMenuDelegate`. Re-reads the
    /// latest settings on every open so checkmarks reflect the current session.
    @MainActor
    func populateCaffeineShelfSubmenu(_ menu: NSMenu) {
        menu.removeAllItems()
        menu.autoenablesItems = false

        let settings = store.settings.resolvedCaffeineShelf

        if !settings.enableCaffeineShelf {
            addDisabled("CaffeineShelf is disabled", to: menu)
            menu.addItem(.separator())
            menu.addItem(actionItem(
                "Open Settings…",
                kind: .openCaffeineShelfSettings
            ))
            return
        }

        CaffeineShelfMenu.shared.populate(menu)
    }
}
