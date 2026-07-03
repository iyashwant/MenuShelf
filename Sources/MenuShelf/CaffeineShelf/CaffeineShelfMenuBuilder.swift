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
    /// Append a CaffeineShelf menu item to `menu`. In `.popover` mode the
    /// entry is a single click target dispatching `.openCaffeineShelf`. In
    /// `.submenu` mode the entry is a parent `NSMenuItem` whose `submenu`
    /// is populated lazily by `CaffeineShelfMenuDelegate`.
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

        let presentationMode = store.settings
            .resolvedCaffeineShelf.resolvedPresentationMode

        let icon = NSImage(systemSymbolName: "cup.and.saucer", accessibilityDescription: nil)
            ?? NSImage(systemSymbolName: "cup.and.saucer.fill", accessibilityDescription: nil)

        switch presentationMode {
        case .popover:
            let item = actionItem(
                config.displayTitle,
                kind: .openCaffeineShelf,
                menuViewID: menuViewID
            )
            item.image = icon
            if !enabled {
                item.toolTip = "CaffeineShelf is disabled in MenuShelf settings."
            }
            menu.addItem(item)

        case .submenu:
            let parent = NSMenuItem(
                title: config.displayTitle,
                action: nil,
                keyEquivalent: ""
            )
            parent.image = icon
            parent.representedObject = nil

            let submenu = NSMenu(title: config.displayTitle)
            submenu.autoenablesItems = false

            let delegate = CaffeineShelfMenuDelegate(builder: self)
            submenu.delegate = delegate
            MenuDelegateRetainer.shared.retain(delegate, for: submenu)
            parent.submenu = submenu
            menu.addItem(parent)
        }
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
