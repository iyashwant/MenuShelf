//
//  ClipboardShelfMenuBuilder.swift
//  MenuShelf
//
//  Inline menu view item that surfaces the Clipboard Shelf popup directly
//  from a MenuShelf menu view. Mirrors `ClockShelfMenuBuilder` so the
//  rest of the menu code stays free of clipboard-shelf-specific concerns.
//

import AppKit
import SwiftData

// MARK: - ClipboardShelfMenuDelegate

/// Lazy-populates a Clipboard Shelf submenu when it is about to open so the
/// recent-item list reflects the latest history without a status item rebuild.
final class ClipboardShelfMenuDelegate: NSObject, NSMenuDelegate {
    weak var builder: MenuBuilder?
    let menuViewID: UUID

    init(builder: MenuBuilder, menuViewID: UUID) {
        self.builder = builder
        self.menuViewID = menuViewID
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        builder?.populateClipboardShelfSubmenu(menu, menuViewID: menuViewID)
    }
}

// MARK: - MenuBuilder extension

extension MenuBuilder {
    private static let clipboardSubmenuMaxItems = 15

    /// Append a Clipboard Shelf entry to `menu`. In `.popover` mode the entry
    /// is a single click target dispatching `.openClipboardShelf`. In
    /// `.submenu` mode the entry is a parent `NSMenuItem` whose `submenu` is
    /// populated lazily by `ClipboardShelfMenuDelegate`.
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

        let presentationMode = store.settings
            .resolvedClipboardShelf.resolvedPresentationMode

        let icon = NSImage(systemSymbolName: "clipboard", accessibilityDescription: nil)
            ?? NSImage(systemSymbolName: "doc.on.clipboard", accessibilityDescription: nil)

        switch presentationMode {
        case .popover:
            let item = actionItem(
                config.displayTitle,
                kind: .openClipboardShelf,
                menuViewID: menuViewID
            )
            item.image = icon
            if !enabled {
                item.toolTip = "Clipboard Shelf is disabled in MenuShelf settings."
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

            let delegate = ClipboardShelfMenuDelegate(
                builder: self,
                menuViewID: menuViewID
            )
            submenu.delegate = delegate
            MenuDelegateRetainer.shared.retain(delegate, for: submenu)
            parent.submenu = submenu
            menu.addItem(parent)
        }
    }

    /// Lazy populate path used by `ClipboardShelfMenuDelegate`. Re-reads the
    /// latest history on every open so the inline list stays current.
    @MainActor
    func populateClipboardShelfSubmenu(_ menu: NSMenu, menuViewID: UUID) {
        menu.removeAllItems()
        menu.autoenablesItems = false

        let settings = store.settings.resolvedClipboardShelf

        if !settings.enableClipboardShelf {
            addDisabled("Clipboard Shelf is disabled", to: menu)
            menu.addItem(.separator())
            menu.addItem(actionItem(
                "Open Settings…",
                kind: .openClipboardShelfSettings
            ))
            return
        }

        let items = fetchRecentClipboardItems(sortBy: settings.sortBy)

        if items.isEmpty {
            addDisabled("No clipboard history", to: menu)
        } else {
            let fallbackIcon = NSImage(systemSymbolName: "doc.on.clipboard", accessibilityDescription: nil)
            for item in items {
                let row = NSMenuItem(
                    title: clipboardSubmenuTitle(for: item),
                    action: #selector(ClipboardShelfMenu.handleSelectItem(_:)),
                    keyEquivalent: ""
                )
                row.target = ClipboardShelfMenu.shared
                row.representedObject = item
                row.isEnabled = true
                if let image = item.image {
                    let icon = (image.copy() as? NSImage) ?? image
                    icon.size = NSSize(width: 16, height: 16)
                    row.image = icon
                } else {
                    row.image = fallbackIcon
                }
                menu.addItem(row)
            }
        }

        menu.addItem(.separator())
        menu.addItem(actionItem(
            "Open Clipboard Shelf…",
            kind: .openClipboardShelf,
            menuViewID: menuViewID
        ))
        menu.addItem(actionItem(
            "Open Settings…",
            kind: .openClipboardShelfSettings
        ))
    }

    @MainActor
    private func fetchRecentClipboardItems(sortBy: ClipboardShelfSortKey) -> [HistoryItem] {
        let descriptor = FetchDescriptor<HistoryItem>()
        guard let results = try? Storage.shared.context.fetch(descriptor) else {
            return []
        }
        let sorter = Sorter()
        let sorted = sorter.sort(results, by: mapClipboardSortKey(sortBy))
        return Array(sorted.prefix(Self.clipboardSubmenuMaxItems))
    }

    private func mapClipboardSortKey(_ key: ClipboardShelfSortKey) -> Sorter.By {
        switch key {
        case .firstCopiedAt: .firstCopiedAt
        case .lastCopiedAt: .lastCopiedAt
        case .numberOfCopies: .numberOfCopies
        }
    }

    private func clipboardSubmenuTitle(for item: HistoryItem) -> String {
        var title: String
        let preview = item.previewableText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !preview.isEmpty {
            title = preview.replacingOccurrences(of: "\n", with: " ")
        } else if item.image != nil {
            title = "Image"
        } else if !item.title.isEmpty {
            title = item.title
        } else {
            title = "Clipboard item"
        }

        if let pin = item.pin, !pin.isEmpty {
            title = "\(pin) \(title)"
        }

        if title.count > 80 {
            return String(title.prefix(77)) + "..."
        }
        return title
    }
}
