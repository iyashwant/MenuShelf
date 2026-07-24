//
//  BookmarkShelfMenuBuilder.swift
//  MenuShelf
//
//  Inline menu rendering for the Bookmark Shelf module. Mirrors
//  `ClipboardShelfMenuBuilder` and `ClockShelfMenuBuilder`: the
//  whole-shelf submenu hangs off `MenuViewConfig.bookmarkShelfItem` and
//  per-node rows hang off `MenuViewConfig.bookmarkContentItems`. Every
//  submenu populated here is lazy: an `NSMenuDelegate` instance retained
//  by `MenuDelegateRetainer.shared` re-reads the latest
//  `BookmarkShelfStorage.nodes` snapshot on each open so star toggles,
//  add/remove/move operations, and import flushes show up immediately
//  without a full status-item rebuild (Requirement 9.4 / AGENTS.md
//  §"Lazy menu loading").
//

import AppKit
import Foundation

// MARK: - BookmarkShelfMenuDelegate

/// Lazy-populates a Bookmark Shelf submenu when it is about to open so
/// the inline tree always reflects the latest `BookmarkShelfStorage`
/// snapshot. Co-located with the builder extension so the rendering
/// logic and the lazy-populate logic stay in one place, mirroring the
/// `ClockShelfMenuDelegate` / `ClipboardShelfMenuBuilder` pairing.
final class BookmarkShelfMenuDelegate: NSObject, NSMenuDelegate {
    weak var builder: MenuBuilder?
    /// `nil` means "root" — used by the inline whole-shelf submenu and
    /// by per-node folder content rows that scope the children to a
    /// specific folder id.
    let parentNodeID: UUID?
    let menuViewID: UUID

    init(builder: MenuBuilder, parentNodeID: UUID?, menuViewID: UUID) {
        self.builder = builder
        self.parentNodeID = parentNodeID
        self.menuViewID = menuViewID
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        builder?.populateBookmarkShelfSubmenu(
            menu,
            parentNodeID: parentNodeID,
            menuViewID: menuViewID
        )
    }
}

// MARK: - MenuBuilder extension

extension MenuBuilder {
    /// Append a Bookmark Shelf inline whole-shelf row to `menu`. When
    /// `enabled == false`, attaches a tiny "Open Bookmark Shelf
    /// Settings…" submenu instead of the live tree (Requirement 9.9).
    /// When `enabled == true`, attaches a delegate-driven submenu
    /// rooted at the tree root (`parentNodeID == nil`).
    func addBookmarkShelfMenuItem(
        _ config: BookmarkShelfMenuItemConfig,
        to menu: NSMenu,
        currentSection: inout String?,
        menuViewID: UUID,
        enabled: Bool
    ) {
        // Section header logic — identical to
        // `addClipboardShelfMenuItem` / `addClockShelfMenuItem`.
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

        let parent = NSMenuItem(
            title: config.displayTitle,
            action: nil,
            keyEquivalent: ""
        )
        parent.image = NSImage(
            systemSymbolName: "bookmark",
            accessibilityDescription: nil
        )

        let submenu = NSMenu(title: config.displayTitle)
        submenu.autoenablesItems = false

        if !enabled {
            // Disabled-fallback branch (Requirement 9.9). Render a
            // single disabled row and a settings deep-link instead of
            // the live tree.
            addDisabled("Enable Bookmark Shelf in Settings", to: submenu)
            submenu.addItem(.separator())
            submenu.addItem(actionItem(
                "Open Bookmark Shelf Settings…",
                kind: .openBookmarkShelfSettings
            ))
            parent.toolTip = "Bookmark Shelf is disabled in MenuShelf settings."
        } else {
            // Live-tree branch. The delegate re-populates the submenu
            // on every open so the tree reflects the latest snapshot
            // (Requirement 9.4). The retainer keeps the delegate alive
            // because `NSMenu.delegate` is weak (AGENTS.md §"Lazy menu
            // loading").
            let delegate = BookmarkShelfMenuDelegate(
                builder: self,
                parentNodeID: nil,
                menuViewID: menuViewID
            )
            submenu.delegate = delegate
            MenuDelegateRetainer.shared.retain(delegate, for: submenu)
        }

        parent.submenu = submenu
        menu.addItem(parent)
    }

    /// Append a per-node Bookmark Shelf content row (folder or
    /// bookmark) to `menu`. When the referenced node is missing,
    /// renders a single disabled `"Bookmark unavailable"` placeholder
    /// (Requirement 10.6 — verbatim, never interpolating any title
    /// from the missing node).
    func addBookmarkContentItem(
        _ config: BookmarkContentItemConfig,
        to menu: NSMenu,
        currentSection: inout String?,
        menuViewID: UUID,
        enabled: Bool
    ) {
        // Section header logic mirrors the inline-shelf variant.
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

        if !enabled {
            // Disabled-feature placeholder per Requirement 10.9. No
            // submenu — the row is a single disabled leaf.
            addDisabled("Enable Bookmark Shelf in Settings", to: menu)
            return
        }

        // `BookmarkShelfController.shared` is `@MainActor`-isolated;
        // AppKit calls into the menu builder from the main thread
        // during menu tracking, so the lookup is statically safe.
        let storage = MainActor.assumeIsolated {
            BookmarkShelfController.shared.storageHandle
        }
        guard let storage,
              let node = MainActor.assumeIsolated({
                  storage.nodes.first(where: { $0.id == config.nodeID })
              }) else {
            // Missing-node placeholder per Requirement 10.6. The
            // string is verbatim — no interpolation of any title from
            // the missing node.
            addDisabled("Bookmark unavailable", to: menu)
            return
        }

        switch node.kind {
        case .folder:
            // Folder content row → delegate-driven submenu rooted at
            // `node.id` (Requirement 10.2). The same depth-cap
            // defensive check that `appendFolderRow` uses applies
            // here.
            let parent = NSMenuItem(
                title: config.resolvedTitle(node: node),
                action: nil,
                keyEquivalent: ""
            )
            parent.image = bookmarkShelfIcon(
                for: config.resolvedIcon(node: node),
                fallbackSymbol: "folder"
            )

            let parentDepth = MainActor.assumeIsolated {
                storage.depth(of: node.id)
            }
            if parentDepth >= 5 {
                // Depth-cap defensive check (Requirement 9.6) — leaf
                // without submenu so the cascade cannot exceed the
                // documented limit.
                menu.addItem(parent)
                return
            }

            let submenu = NSMenu(title: parent.title)
            submenu.autoenablesItems = false
            let delegate = BookmarkShelfMenuDelegate(
                builder: self,
                parentNodeID: node.id,
                menuViewID: menuViewID
            )
            submenu.delegate = delegate
            MenuDelegateRetainer.shared.retain(delegate, for: submenu)
            parent.submenu = submenu
            menu.addItem(parent)

        case .bookmark:
            // Bookmark content row → leaf with the same icon and
            // Option-modifier "Open in…" alternate cascade as the
            // inline whole-shelf row (Requirement 10.3, 10.7).
            appendBookmarkRow(node: node, to: menu, menuViewID: menuViewID)
        }
    }

    /// Lazy-populate path used by `BookmarkShelfMenuDelegate`. Re-reads
    /// the latest `BookmarkShelfStorage.nodes` snapshot on every open
    /// so add/remove/star/move operations show up immediately
    /// (Requirements 9.4, 9.5, 9.6, 10.8).
    func populateBookmarkShelfSubmenu(
        _ menu: NSMenu,
        parentNodeID: UUID?,
        menuViewID: UUID
    ) {
        menu.removeAllItems()
        menu.autoenablesItems = false

        // `BookmarkShelfController.shared` is `@MainActor`-isolated;
        // AppKit calls into the menu builder from the main thread
        // during menu tracking, so the lookup is statically safe.
        let storage = MainActor.assumeIsolated {
            BookmarkShelfController.shared.storageHandle
        }
        guard let storage else {
            addDisabled("Bookmark Shelf is not running", to: menu)
            // The popup is backed by the same absent storage, so offer
            // only the settings deep-link rather than the full footer.
            if parentNodeID == nil {
                menu.addItem(.separator())
                menu.addItem(actionItem(
                    "Open Settings…",
                    kind: .openBookmarkShelfSettings
                ))
            }
            return
        }

        let nodes = MainActor.assumeIsolated { storage.nodes }
        let bookmarkSettings = store.settings.resolvedBookmarkShelf

        // Favorites section (Requirement 9.5 / 10.8). The slice is
        // every favorite at root, or the favorites scoped to the
        // descendants of `parentNodeID` for non-root submenus.
        if bookmarkSettings.showFavoritesSection {
            let favorites: [BookmarkNode]
            if let parentNodeID {
                let descendants = MainActor.assumeIsolated {
                    storage.descendantIDs(of: parentNodeID)
                }
                favorites = nodes
                    .filter { $0.isFavorite && descendants.contains($0.id) }
                    .sorted { $0.sortOrder < $1.sortOrder }
            } else {
                favorites = nodes
                    .filter { $0.isFavorite }
                    .sorted { $0.sortOrder < $1.sortOrder }
            }
            if !favorites.isEmpty {
                addDisabled("Favorites", to: menu)
                for favorite in favorites {
                    appendBookmarkRow(node: favorite, to: menu, menuViewID: menuViewID)
                }
                menu.addItem(.separator())
            }
        }

        // Children of the current parent. Folders rank above
        // bookmarks within the same `sortOrder` band (Requirement 8.3
        // mirrored to the inline render).
        let children = nodes
            .filter { $0.parentID == parentNodeID }
            .sorted { lhs, rhs in
                if lhs.sortOrder != rhs.sortOrder {
                    return lhs.sortOrder < rhs.sortOrder
                }
                let lhsKindRank = lhs.kind == .folder ? 0 : 1
                let rhsKindRank = rhs.kind == .folder ? 0 : 1
                if lhsKindRank != rhsKindRank {
                    return lhsKindRank < rhsKindRank
                }
                return lhs.id.uuidString < rhs.id.uuidString
            }

        if children.isEmpty {
            addDisabled("Empty", to: menu)
        } else {
            for child in children {
                switch child.kind {
                case .folder:
                    appendFolderRow(node: child, to: menu, menuViewID: menuViewID)
                case .bookmark:
                    appendBookmarkRow(node: child, to: menu, menuViewID: menuViewID)
                }
            }
        }

        // Trailing actions, mirroring the Clipboard/Clock submenus:
        // a route out of the inline tree into the full popup, plus a
        // settings deep-link. Root-only — this same function drives
        // every nested folder cascade via
        // `BookmarkShelfMenuDelegate(parentNodeID:)`, and appending
        // unconditionally would repeat the footer in each one.
        // Appended on the empty path too, so an empty tree is still
        // recoverable from the menu.
        if parentNodeID == nil {
            appendBookmarkShelfFooter(to: menu, menuViewID: menuViewID)
        }
    }

    /// Separator + "Open Bookmark Shelf…" + "Open Settings…" appended to
    /// the root inline submenu. The `.openBookmarkShelf` action carries
    /// the originating `menuViewID` so `MenuActionHandler` can anchor the
    /// popup under this menu view's own status item.
    private func appendBookmarkShelfFooter(to menu: NSMenu, menuViewID: UUID) {
        if menu.items.last?.isSeparatorItem == false {
            menu.addItem(.separator())
        }
        menu.addItem(actionItem(
            "Open Bookmark Shelf…",
            kind: .openBookmarkShelf,
            menuViewID: menuViewID
        ))
        menu.addItem(actionItem(
            "Open Settings…",
            kind: .openBookmarkShelfSettings
        ))
    }

    /// Append a folder row with a delegate-driven cascade. Defensive
    /// depth-cap check at depth 5 leaves the row as a leaf without a
    /// submenu so the cascade cannot exceed the documented limit
    /// (Requirement 9.6).
    func appendFolderRow(
        node: BookmarkNode,
        to menu: NSMenu,
        menuViewID: UUID
    ) {
        // `BookmarkShelfController.shared` is `@MainActor`-isolated;
        // AppKit calls into the menu builder from the main thread
        // during menu tracking, so the lookup is statically safe.
        let storage = MainActor.assumeIsolated {
            BookmarkShelfController.shared.storageHandle
        }
        guard let storage else {
            return
        }

        let item = NSMenuItem(
            title: node.title,
            action: nil,
            keyEquivalent: ""
        )
        item.image = NSImage(
            systemSymbolName: "folder",
            accessibilityDescription: nil
        )

        let nodeDepth = MainActor.assumeIsolated {
            storage.depth(of: node.id)
        }
        if nodeDepth >= 5 {
            // Defensive: the storage layer rejects creating folders
            // below depth 5, but a stale or corrupt tree could still
            // present one. Render it as a leaf so the cascade ends
            // here (Requirement 9.6).
            menu.addItem(item)
            return
        }

        let submenu = NSMenu(title: node.title)
        submenu.autoenablesItems = false
        let delegate = BookmarkShelfMenuDelegate(
            builder: self,
            parentNodeID: node.id,
            menuViewID: menuViewID
        )
        submenu.delegate = delegate
        MenuDelegateRetainer.shared.retain(delegate, for: submenu)
        item.submenu = submenu
        menu.addItem(item)
    }

    /// Append a bookmark row plus its Option-modifier alternate
    /// "Open in…" cascade. The alternate row is configured with
    /// `keyEquivalentModifierMask = .option` so it surfaces only while
    /// Option is held (Requirement 9.8).
    func appendBookmarkRow(
        node: BookmarkNode,
        to menu: NSMenu,
        menuViewID: UUID
    ) {
        let primary = actionItem(
            node.title,
            kind: .openBookmark,
            menuViewID: menuViewID,
            bookmarkNodeID: node.id
        )
        primary.image = NSImage(
            systemSymbolName: "globe",
            accessibilityDescription: nil
        )
        menu.addItem(primary)

        // Alternate row — same primary action title but with an
        // Option-held variant whose submenu is the "Open in…"
        // cascade. AppKit shows alternates only while the configured
        // modifier mask is held; the primary row still dispatches the
        // default-browser flow on a regular click (Requirement 9.8).
        let alternate = NSMenuItem(
            title: "Open in…",
            action: nil,
            keyEquivalent: ""
        )
        alternate.image = primary.image
        alternate.isAlternate = true
        alternate.keyEquivalentModifierMask = .option
        alternate.submenu = buildOpenInSubmenu(forBookmarkNodeID: node.id)
        menu.addItem(alternate)
    }

    /// Build the "Open in…" submenu listing the system default plus
    /// every browser discovered via
    /// `DefaultBrowserService.shared.discoverBrowsers()`. When Browser
    /// Flip has stored visibility metadata, filter the list down to
    /// the visible browsers; otherwise show every discovered browser.
    /// Sort ascending by `(sortOrder, name)` so the order matches the
    /// user's Browser Flip arrangement (Requirements 11.2, 11.3).
    func buildOpenInSubmenu(forBookmarkNodeID nodeID: UUID) -> NSMenu {
        let menu = NSMenu(title: "Open in…")
        menu.autoenablesItems = false

        // First entry — System Default. Reuses `.openBookmark` so the
        // dispatch path is identical to a regular click (Requirement
        // 11.2.a).
        let systemDefault = actionItem(
            "System Default",
            kind: .openBookmark,
            menuViewID: nil,
            bookmarkNodeID: nodeID
        )
        menu.addItem(systemDefault)
        menu.addItem(.separator())

        let discovered = DefaultBrowserService.shared.discoverBrowsers()
        let stored = store.discoveredBrowsers

        let filtered: [BrowserInfo]
        if stored.isEmpty {
            // Browser Flip was never initialized — surface every
            // discovered browser without filtering (Requirement
            // 11.3).
            filtered = discovered
        } else {
            let visibleIDs = Set(
                stored.filter(\.isVisible).map(\.id)
            )
            filtered = discovered.filter { visibleIDs.contains($0.id) }
        }

        let sorted = filtered.sorted { lhs, rhs in
            if lhs.sortOrder != rhs.sortOrder {
                return lhs.sortOrder < rhs.sortOrder
            }
            return lhs.name < rhs.name
        }

        for browser in sorted {
            let item = actionItem(
                browser.name,
                kind: .openBookmarkIn,
                menuViewID: nil,
                bookmarkNodeID: nodeID,
                openInBrowserBundleID: browser.id
            )
            let icon = NSWorkspace.shared.icon(forFile: browser.appURL.path)
            icon.size = NSSize(width: 16, height: 16)
            item.image = icon
            menu.addItem(item)
        }

        return menu
    }

    /// Resolve a `FolderIconConfig` to an `NSImage` for menu rendering.
    /// Falls back to `fallbackSymbol` when the resolved icon cannot be
    /// rendered (e.g. a custom-image bookmark that has gone stale).
    /// Used by the per-node content row variant (`addBookmarkContentItem`).
    fileprivate func bookmarkShelfIcon(
        for icon: FolderIconConfig,
        fallbackSymbol: String
    ) -> NSImage? {
        switch icon {
        case .systemSymbol(let name, _):
            return NSImage(
                systemSymbolName: name,
                accessibilityDescription: nil
            ) ?? NSImage(
                systemSymbolName: fallbackSymbol,
                accessibilityDescription: nil
            )
        case .emoji, .monogram, .customImage, .folderIcon:
            // The richer icon variants have well-tested resolvers in
            // `MenuBuilder.icon(for:size:)` for `FolderConfig`, but
            // they require a backing folder context that bookmarks do
            // not have. For v1 we render the default fallback — the
            // resolver is wide enough to cover future icon variants.
            return NSImage(
                systemSymbolName: fallbackSymbol,
                accessibilityDescription: nil
            )
        }
    }
}
