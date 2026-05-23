//
//  ClipboardShelfMenuBuilder.swift
//  MenuShelf
//
//  Inline menu view item that surfaces the Clipboard Shelf popup directly
//  from a MenuShelf menu view. Mirrors `BrowserFlipMenuBuilder` so the
//  rest of the menu code stays free of clipboard-shelf-specific concerns.
//

import AppKit

extension MenuBuilder {
    /// Append a Clipboard Shelf menu item to `menu`. Single-click opens
    /// the floating popup (or the settings pane focused on the
    /// Clipboard Shelf section when the feature is currently disabled).
    func addClipboardShelfMenuItem(
        _ config: ClipboardShelfMenuItemConfig,
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

        let item = actionItem(
            config.displayTitle,
            kind: .openClipboardShelf,
            menuViewID: menuViewID
        )
        let icon = NSImage(systemSymbolName: "clipboard", accessibilityDescription: nil)
            ?? NSImage(systemSymbolName: "doc.on.clipboard", accessibilityDescription: nil)
        item.image = icon
        if !enabled {
            item.toolTip = "Clipboard Shelf is disabled in MenuShelf settings."
        }
        menu.addItem(item)
    }
}
