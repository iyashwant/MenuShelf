import AppKit
import Foundation

/// Keeps `NSMenuDelegate` instances alive only as long as their menus are alive.
/// `NSMenu.delegate` is a weak reference, so the delegate would otherwise be
/// deallocated immediately. We bind delegate lifetime to the menu's lifetime
/// using `NSMapTable.weakToStrongObjects`, so every menu rebuild naturally
/// releases the previous delegate when ARC frees the old menu.
final class MenuDelegateRetainer {
    static let shared = MenuDelegateRetainer()
    private let table = NSMapTable<NSMenu, NSObject>.weakToStrongObjects()
    private let lock = NSLock()

    func retain(_ delegate: NSObject, for menu: NSMenu) {
        lock.lock()
        table.setObject(delegate, forKey: menu)
        lock.unlock()
    }
}

final class FolderMenuDelegate: NSObject, NSMenuDelegate {
    weak var builder: MenuBuilder?
    let configID: UUID
    let configOverride: FolderConfig?
    let menuView: MenuViewConfig?
    let folderURL: URL?
    let isRoot: Bool
    let visited: Set<String>

    init(builder: MenuBuilder, configID: UUID, configOverride: FolderConfig?, menuView: MenuViewConfig?, folderURL: URL?, isRoot: Bool, visited: Set<String>) {
        self.builder = builder
        self.configID = configID
        self.configOverride = configOverride
        self.menuView = menuView
        self.folderURL = folderURL
        self.isRoot = isRoot
        self.visited = visited
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        DiagnosticsLogger.shared.log("FolderMenuDelegate.menuNeedsUpdate configID=\(configID) isRoot=\(isRoot)")
        builder?.populateFolderMenu(menu, configID: configID, configOverride: configOverride, menuView: menuView, folderURL: folderURL, isRoot: isRoot, visited: visited)
    }

    /// Folder contents never carry key equivalents — file/folder rows and the
    /// folder footer all use empty `keyEquivalent`. Returning false here tells
    /// AppKit not to populate this submenu when searching for a matching key
    /// equivalent on a keypress while the menu is open. Without this, every
    /// keystroke triggered a recursive `menuNeedsUpdate` walk through the
    /// entire folder tree (each call enumerating the directory and loading
    /// resource values + icons), saturating the main thread and freezing the
    /// menu.
    func menuHasKeyEquivalent(
        _ menu: NSMenu,
        for event: NSEvent,
        target: AutoreleasingUnsafeMutablePointer<AnyObject?>,
        action: UnsafeMutablePointer<Selector?>
    ) -> Bool {
        false
    }

    func menuWillOpen(_ menu: NSMenu) {
        DiagnosticsLogger.shared.log("FolderMenuDelegate.menuWillOpen configID=\(configID)")
    }

    func menuDidClose(_ menu: NSMenu) {
        DiagnosticsLogger.shared.log("FolderMenuDelegate.menuDidClose configID=\(configID)")
    }
}

/// Delegate that lazily repopulates a menu view's top-level NSMenu when it is
/// about to be opened. Without this, the status item caches a stale snapshot
/// of the view's contents until the next status item rebuild (which only
/// happens for title/icon/visibility/hotkey changes).
final class MenuViewMenuDelegate: NSObject, NSMenuDelegate {
    weak var builder: MenuBuilder?
    let menuViewID: UUID
    let includeManagement: Bool

    init(builder: MenuBuilder, menuViewID: UUID, includeManagement: Bool) {
        self.builder = builder
        self.menuViewID = menuViewID
        self.includeManagement = includeManagement
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        builder?.populateMenuViewMenu(menu, menuViewID: menuViewID, includeManagement: includeManagement)
    }
}

/// Delegate for the fallback "grouped" menu shown when no menu views exist.
final class GroupedMenuDelegate: NSObject, NSMenuDelegate {
    weak var builder: MenuBuilder?

    init(builder: MenuBuilder) {
        self.builder = builder
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        builder?.populateGroupedMenu(menu)
    }
}

final class MenuBuilder {
    let store: PreferencesStore
    private let fileAccessService: FileAccessService
    private let metadataService: MetadataService
    private let actionHandler: MenuActionHandler

    init(store: PreferencesStore, fileAccessService: FileAccessService, metadataService: MetadataService, actionHandler: MenuActionHandler) {
        self.store = store
        self.fileAccessService = fileAccessService
        self.metadataService = metadataService
        self.actionHandler = actionHandler
    }

    func makeRootMenu(for config: FolderConfig) -> NSMenu {
        if config.resolvedItemKind == .app {
            return makeAppMenu(for: config)
        }

        let menu = NSMenu(title: config.displayName)
        menu.autoenablesItems = false
        attachFolderDelegate(to: menu, configID: config.id, configOverride: config, menuView: nil, folderURL: nil, isRoot: true, visited: [])
        return menu
    }

    func makeMenuViewMenu(for view: MenuViewConfig) -> NSMenu {
        // Top-level entry point: install a delegate so the menu refreshes lazily
        // when the user opens it. This keeps the cached NSMenu on each status item
        // up to date with view contents (sources, shortcuts, applescripts, browser
        // flip, etc.) without depending on the StatusItemManager rebuilding the
        // status items, which only fires for menu bar shape changes.
        if let directMenu = makeDirectSingleFolderMenu(for: view) {
            return directMenu
        }

        let menu = NSMenu(title: view.title)
        menu.autoenablesItems = false
        let delegate = MenuViewMenuDelegate(builder: self, menuViewID: view.id, includeManagement: true)
        menu.delegate = delegate
        MenuDelegateRetainer.shared.retain(delegate, for: menu)
        return menu
    }

    /// Lazy populate path used by `MenuViewMenuDelegate` when the menu opens.
    /// Re-resolves the latest `MenuViewConfig` from the store every time, so the
    /// menu reflects the current settings without needing a status item rebuild.
    func populateMenuViewMenu(_ menu: NSMenu, menuViewID: UUID, includeManagement: Bool) {
        menu.removeAllItems()
        menu.autoenablesItems = false

        guard let view = store.menuView(id: menuViewID) else {
            addDisabled("View Removed", to: menu)
            return
        }

        // Re-evaluate the direct single-folder shortcut on every open. If the
        // view qualifies, populate the folder contents in place so the cached
        // status item menu still reflects the current state.
        if includeManagement, let source = directSingleFolderSource(for: view) {
            populateFolderMenu(menu, configID: source.id, configOverride: source, menuView: view, folderURL: nil, isRoot: true, visited: [])
            return
        }

        populateMenuViewBody(menu, for: view, includeManagement: includeManagement, visitedMenuViewIDs: [view.id])
    }

    private func makeMenuViewMenu(for view: MenuViewConfig, includeManagement: Bool, visitedMenuViewIDs: Set<UUID>) -> NSMenu {
        if includeManagement, let directMenu = makeDirectSingleFolderMenu(for: view) {
            return directMenu
        }

        let menu = NSMenu(title: view.title)
        menu.autoenablesItems = false
        populateMenuViewBody(menu, for: view, includeManagement: includeManagement, visitedMenuViewIDs: visitedMenuViewIDs)
        return menu
    }

    private func populateMenuViewBody(_ menu: NSMenu, for view: MenuViewConfig, includeManagement: Bool, visitedMenuViewIDs: Set<UUID>) {
        let showManagementAtTop = includeManagement && shouldShowGlobalManagementMenuAtTop()
        let showManagementAtBottom = includeManagement && shouldShowGlobalManagementMenuAtBottom()
        let hasContent = !view.items.isEmpty
            || !view.resolvedLinkedMenuViews.isEmpty
            || !view.resolvedShortcutItems.isEmpty
            || !view.resolvedLinkedShortcutsFolders.isEmpty
            || !view.resolvedAppleScriptItems.isEmpty
            || view.browserFlipItem != nil
            || view.clipboardShelfItem != nil
            || view.worldClockItem != nil
            || view.bookmarkShelfItem != nil
            || !view.resolvedBookmarkContentItems.isEmpty

        if showManagementAtTop {
            menu.addItem(managementMenuItem(for: view))
            if hasContent {
                menu.addItem(.separator())
            }
        }

        if !hasContent {
            addDisabled("No items in this view", to: menu)
        } else {
            var currentSection: String?
            for viewItem in view.items {
                guard let source = store.folder(id: viewItem.sourceID) else { continue }
                if let section = viewItem.sectionName, section != currentSection {
                    if currentSection != nil {
                        menu.addItem(.separator())
                    }
                    addDisabled(section, to: menu)
                    currentSection = section
                }

                menu.addItem(menuViewRootItem(for: sourceConfig(source, item: viewItem, fallbackSettings: view.menuSettings)))
            }

            if !view.items.isEmpty,
               (!view.resolvedLinkedMenuViews.isEmpty || !view.resolvedShortcutItems.isEmpty || !view.resolvedLinkedShortcutsFolders.isEmpty || !view.resolvedAppleScriptItems.isEmpty || view.browserFlipItem != nil || view.clipboardShelfItem != nil || view.worldClockItem != nil) {
                menu.addItem(.separator())
                currentSection = nil
            }

            addLinkedMenuViews(view.resolvedLinkedMenuViews, to: menu, currentSection: &currentSection, visitedMenuViewIDs: visitedMenuViewIDs)
            if !view.resolvedLinkedMenuViews.isEmpty,
               (!view.resolvedShortcutItems.isEmpty || !view.resolvedLinkedShortcutsFolders.isEmpty || !view.resolvedAppleScriptItems.isEmpty || view.browserFlipItem != nil || view.clipboardShelfItem != nil || view.worldClockItem != nil),
               menu.items.last?.isSeparatorItem == false {
                menu.addItem(.separator())
                currentSection = nil
            }
            addShortcutItems(view.resolvedShortcutItems, to: menu, currentSection: &currentSection)
            if !view.resolvedShortcutItems.isEmpty,
               (!view.resolvedAppleScriptItems.isEmpty || !view.resolvedLinkedShortcutsFolders.isEmpty || view.browserFlipItem != nil || view.clipboardShelfItem != nil || view.worldClockItem != nil),
               menu.items.last?.isSeparatorItem == false {
                menu.addItem(.separator())
                currentSection = nil
            }
            addAppleScriptItems(view.resolvedAppleScriptItems, to: menu, currentSection: &currentSection, menuViewID: view.id)
            if !view.resolvedAppleScriptItems.isEmpty,
               (!view.resolvedLinkedShortcutsFolders.isEmpty || view.browserFlipItem != nil || view.clipboardShelfItem != nil || view.worldClockItem != nil),
               menu.items.last?.isSeparatorItem == false {
                menu.addItem(.separator())
                currentSection = nil
            }
            addLinkedShortcutFolders(view.resolvedLinkedShortcutsFolders, to: menu, currentSection: &currentSection)
            if !view.resolvedLinkedShortcutsFolders.isEmpty,
               (view.browserFlipItem != nil || view.clipboardShelfItem != nil || view.worldClockItem != nil),
               menu.items.last?.isSeparatorItem == false {
                menu.addItem(.separator())
                currentSection = nil
            }
            if let browserFlipItem = view.browserFlipItem {
                addBrowserFlipMenuItem(browserFlipItem, to: menu, currentSection: &currentSection)
            }
            if let clipboardShelfItem = view.clipboardShelfItem {
                if view.browserFlipItem != nil, menu.items.last?.isSeparatorItem == false {
                    menu.addItem(.separator())
                    currentSection = nil
                }
                addClipboardShelfMenuItem(
                    clipboardShelfItem,
                    to: menu,
                    currentSection: &currentSection,
                    menuViewID: view.id,
                    enabled: store.settings.resolvedClipboardShelf.enableClipboardShelf
                )
            }
            if let worldClockItem = view.worldClockItem {
                if (view.browserFlipItem != nil || view.clipboardShelfItem != nil),
                   menu.items.last?.isSeparatorItem == false {
                    menu.addItem(.separator())
                    currentSection = nil
                }
                addWorldClockMenuItem(
                    worldClockItem,
                    to: menu,
                    currentSection: &currentSection,
                    menuViewID: view.id,
                    enabled: store.settings.resolvedWorldClock.enableWorldClock
                )
            }
            if let bookmarkShelfItem = view.bookmarkShelfItem {
                if (view.browserFlipItem != nil
                    || view.clipboardShelfItem != nil
                    || view.worldClockItem != nil),
                   menu.items.last?.isSeparatorItem == false {
                    menu.addItem(.separator())
                    currentSection = nil
                }
                addBookmarkShelfMenuItem(
                    bookmarkShelfItem,
                    to: menu,
                    currentSection: &currentSection,
                    menuViewID: view.id,
                    enabled: store.settings.resolvedBookmarkShelf.enableBookmarkShelf
                )
            }
            for contentItem in view.resolvedBookmarkContentItems {
                addBookmarkContentItem(
                    contentItem,
                    to: menu,
                    currentSection: &currentSection,
                    menuViewID: view.id,
                    enabled: store.settings.resolvedBookmarkShelf.enableBookmarkShelf
                )
            }
        }

        if showManagementAtBottom {
            menu.addItem(.separator())
            menu.addItem(managementMenuItem(for: view))
        }
    }

    private func directSingleFolderSource(for view: MenuViewConfig) -> FolderConfig? {
        let layout = view.resolvedLayout
        guard layout != .sourceList else { return nil }
        guard view.resolvedLinkedMenuViews.isEmpty,
              view.resolvedShortcutItems.isEmpty,
              view.resolvedLinkedShortcutsFolders.isEmpty,
              view.resolvedAppleScriptItems.isEmpty,
              view.browserFlipItem == nil,
              view.clipboardShelfItem == nil,
              view.worldClockItem == nil else {
            return nil
        }
        guard view.items.count == 1,
              let item = view.items.first,
              var source = store.folder(id: item.sourceID),
              source.resolvedItemKind == .folder else {
            return nil
        }

        guard layout == .automatic || layout == .firstFolderContents else {
            return nil
        }

        source.displayName = view.title
        source.icon = view.icon
        source.iconColorHex = view.iconColorHex
        source.menuBarStyle = view.menuBarStyle
        source.menuSettings = view.menuSettings
        return source
    }

    private func makeDirectSingleFolderMenu(for view: MenuViewConfig) -> NSMenu? {
        guard let source = directSingleFolderSource(for: view) else { return nil }
        let menu = NSMenu(title: view.title)
        menu.autoenablesItems = false
        attachFolderDelegate(to: menu, configID: source.id, configOverride: source, menuView: view, folderURL: nil, isRoot: true, visited: [])
        return menu
    }

    func makeAppMenu(for config: FolderConfig) -> NSMenu {
        let menu = NSMenu(title: config.displayName)
        menu.autoenablesItems = false

        do {
            let access = try fileAccessService.accessItem(config)
            let url = access.url
            let openItem = actionItem("Open \(config.displayName)", kind: .open, url: url, folderID: config.id)
            openItem.image = icon(for: config, size: 16)
            menu.addItem(openItem)
            menu.addItem(.separator())
            menu.addItem(actionItem("Show in Finder", kind: .reveal, url: url, folderID: config.id))
            menu.addItem(actionItem("Copy Path", kind: .copyPath, url: url, folderID: config.id))
            menu.addItem(.separator())
            menu.addItem(actionItem("Item Settings...", kind: .folderSettings, folderID: config.id))
            menu.addItem(actionItem("Hide From Menu Bar", kind: .hideFolder, folderID: config.id))
            menu.addItem(actionItem("Remove App...", kind: .removeFolder, folderID: config.id))
            menu.addItem(.separator())
            menu.addItem(actionItem("Quit MenuShelf", kind: .quit))
            _ = access
        } catch FileAccessError.staleBookmark {
            addPermissionMenu(to: menu, config: config)
        } catch FileAccessError.missingFolder {
            addMissingFolderMenu(to: menu, config: config)
        } catch {
            addDisabled("App unavailable", to: menu)
            addDisabled(error.localizedDescription, to: menu)
            menu.addItem(.separator())
            menu.addItem(actionItem("Choose New Location...", kind: .reselectFolder, folderID: config.id))
            menu.addItem(actionItem("Remove App...", kind: .removeFolder, folderID: config.id))
        }

        return menu
    }

    func makeGroupedMenu() -> NSMenu {
        let menu = NSMenu(title: "MenuShelf")
        menu.autoenablesItems = false
        let delegate = GroupedMenuDelegate(builder: self)
        menu.delegate = delegate
        MenuDelegateRetainer.shared.retain(delegate, for: menu)
        return menu
    }

    /// Lazy populate path used by `GroupedMenuDelegate` when the fallback
    /// "MenuShelf" menu opens. Rebuilding on each open keeps it in sync with
    /// folder add/remove and visibility changes without a status item rebuild.
    func populateGroupedMenu(_ menu: NSMenu) {
        menu.removeAllItems()
        menu.autoenablesItems = false

        let visibleItems = store.settings.folders.filter(\.isVisible)
        let showManagementAtTop = shouldShowGlobalManagementMenuAtTop()
        let showManagementAtBottom = shouldShowGlobalManagementMenuAtBottom()

        DiagnosticsLogger.shared.log("Building grouped menu with \(visibleItems.count) visible items")

        if showManagementAtTop {
            menu.addItem(managementMenuItem())
            if !visibleItems.isEmpty {
                menu.addItem(.separator())
            }
        }

        if visibleItems.isEmpty {
            addDisabled("No items added", to: menu)
        } else {
            for config in visibleItems {
                menu.addItem(groupedRootItem(for: config))
            }
        }

        if showManagementAtBottom {
            menu.addItem(.separator())
            menu.addItem(managementMenuItem())
        }
    }

    private func groupedRootItem(for config: FolderConfig) -> NSMenuItem {
        menuViewRootItem(for: config)
    }

    private func menuViewRootItem(for config: FolderConfig) -> NSMenuItem {
        let item = NSMenuItem(title: config.displayName, action: nil, keyEquivalent: "")
        if store.settings.resolvedShowTopLevelFolderIcons {
            item.image = icon(for: config, size: store.settings.resolvedTopLevelFolderIconSize.pointSize)
        }

        switch config.resolvedItemKind {
        case .folder:
            item.submenu = makeRootMenu(for: config)
        case .app:
            do {
                let access = try fileAccessService.accessItem(config)
                item.action = #selector(MenuActionHandler.handleMenuAction(_:))
                item.target = actionHandler
                // We only need `access.url` as a value here — the scope is
                // re-acquired by `MenuActionHandler.withFolderAccess(_:)`
                // when the user selects the item. No need to extend the
                // lifetime past this block.
                item.representedObject = MenuAction(kind: .open, url: access.url, folderID: config.id)
            } catch {
                item.title = "\(config.displayName) Unavailable"
                item.submenu = makeAppMenu(for: config)
            }
        }

        return item
    }

    private func sourceConfig(_ source: FolderConfig, item: MenuViewItem, fallbackSettings: MenuSettings) -> FolderConfig {
        var config = source
        if let titleOverride = item.titleOverride, !titleOverride.isEmpty {
            config.displayName = titleOverride
        }
        if let iconOverride = item.iconOverride {
            config.icon = iconOverride
        }
        if item.iconColorHexOverride != nil {
            config.iconColorHex = item.iconColorHexOverride
        }
        config.menuSettings = item.menuSettingsOverride ?? source.menuSettings
        if config.menuSettings == .defaults {
            config.menuSettings = fallbackSettings
        }
        return config
    }

    private func managementMenuItem(for view: MenuViewConfig? = nil) -> NSMenuItem {
        let item = NSMenuItem(title: "...", action: nil, keyEquivalent: "")
        let submenu = NSMenu(title: "MenuShelf")
        submenu.autoenablesItems = false

        submenu.addItem(actionItem("Add Item...", kind: .openSettings))
        if let view {
            submenu.addItem(addExistingMenuViewMenuItem(for: view))
        }
        submenu.addItem(.separator())

        submenu.addItem(toggleMenuViewsMenuItem())
        submenu.addItem(.separator())

        if let view {
            submenu.addItem(actionItem("Duplicate View", kind: .duplicateMenuView, menuViewID: view.id))
            submenu.addItem(actionItem("Hide View", kind: .hideMenuView, menuViewID: view.id))
            submenu.addItem(actionItem("Remove View...", kind: .removeMenuView, menuViewID: view.id))
            submenu.addItem(.separator())
        }

        let settings = actionItem("Settings...", kind: .openSettings)
        settings.keyEquivalent = ","
        settings.keyEquivalentModifierMask = [.command]
        submenu.addItem(settings)

        let more = NSMenuItem(title: "More", action: nil, keyEquivalent: "")
        let moreSubmenu = NSMenu(title: "More")
        moreSubmenu.autoenablesItems = false
        moreSubmenu.addItem(actionItem("Make All Menu Bar Items Icon Only", kind: .setAllIconOnly))
        moreSubmenu.addItem(actionItem("Open Shortcuts", kind: .openShortcutsApp))
        moreSubmenu.addItem(actionItem("Refresh Shortcuts", kind: .refreshShortcuts))
        more.submenu = moreSubmenu
        submenu.addItem(more)

        if store.settings.resolvedBrowserFlip.enableBrowserFlip {
            // Don't double-render: if the current view already has its own
            // Default Browser entry inline, skip the one in "..." → "Default
            // Browser". Falls through for views without an inline entry, and
            // for the global / non-view-scoped management menu.
            let viewHasInlineDefaultBrowser = (view?.browserFlipItem != nil)
            if !viewHasInlineDefaultBrowser {
                submenu.addItem(.separator())
                submenu.addItem(browserFlipMenuItem())
            }
        }

        submenu.addItem(.separator())
        submenu.addItem(actionItem("Quit MenuShelf", kind: .quit))
        item.submenu = submenu
        return item
    }

    private func addExistingMenuViewMenuItem(for view: MenuViewConfig) -> NSMenuItem {
        let item = NSMenuItem(title: "Add Existing View", action: nil, keyEquivalent: "")
        let submenu = NSMenu(title: "Add Existing View")
        submenu.autoenablesItems = false

        let candidates = store.settings.resolvedMenuViews.filter { candidate in
            candidate.id != view.id && !view.resolvedLinkedMenuViews.contains { $0.menuViewID == candidate.id }
        }

        if candidates.isEmpty {
            addDisabled("No available views", to: submenu)
        } else {
            for candidate in candidates {
                let candidateItem = actionItem(
                    candidate.title,
                    kind: .addLinkedMenuView,
                    menuViewID: view.id,
                    linkedMenuViewID: candidate.id
                )
                candidateItem.image = icon(for: candidate, size: 16)
                candidateItem.isEnabled = store.canLinkMenuView(candidate.id, toMenuViewID: view.id)
                submenu.addItem(candidateItem)
            }
        }

        item.submenu = submenu
        return item
    }

    private func toggleMenuViewsMenuItem() -> NSMenuItem {
        let item = NSMenuItem(title: "Toggle Menu Views", action: nil, keyEquivalent: "")
        let submenu = NSMenu(title: "Toggle Menu Views")
        submenu.autoenablesItems = false

        let views = store.settings.resolvedMenuViews
        if views.isEmpty {
            addDisabled("No menu views added", to: submenu)
        } else {
            for view in views {
                let viewItem = actionItem(
                    view.title,
                    kind: .setMenuViewVisibility,
                    menuViewID: view.id,
                    boolValue: !view.isVisible
                )
                viewItem.state = view.isVisible ? .on : .off
                viewItem.image = icon(for: view, size: 16)
                submenu.addItem(viewItem)

                let showOnly = actionItem("Show Only \(view.title)", kind: .showOnlyMenuView, menuViewID: view.id)
                showOnly.image = NSImage(systemSymbolName: "line.3.horizontal.decrease.circle", accessibilityDescription: nil)
                submenu.addItem(showOnly)
            }
        }

        item.submenu = submenu
        return item
    }

    private func shouldShowGlobalManagementMenuAtTop() -> Bool {
        switch store.settings.resolvedMoreMenuBehavior {
        case .visibleAtTop:
            return true
        case .hiddenUntilOption:
            return NSEvent.modifierFlags.contains(.option)
        case .visibleAtBottom:
            return false
        }
    }

    private func shouldShowGlobalManagementMenuAtBottom() -> Bool {
        switch store.settings.resolvedMoreMenuBehavior {
        case .visibleAtBottom:
            return true
        case .hiddenUntilOption, .visibleAtTop:
            return false
        }
    }

    func populateFolderMenu(_ menu: NSMenu, configID: UUID, configOverride: FolderConfig? = nil, menuView: MenuViewConfig? = nil, folderURL: URL?, isRoot: Bool, visited: Set<String>) {
        menu.removeAllItems()
        menu.autoenablesItems = false

        guard let config = configOverride ?? store.folder(id: configID) else {
            addDisabled("Folder Removed", to: menu)
            DiagnosticsLogger.shared.log("populateFolderMenu: config not found for \(configID)")
            return
        }

        do {
            let access = try fileAccessService.accessFolder(config)
            let currentURL = folderURL ?? access.url
            let currentPath = currentURL.standardizedFileURL.path

            if visited.contains(currentPath) {
                addDisabled("Symlink Loop Detected", to: menu)
                menu.addItem(actionItem("Show in Finder", kind: .reveal, url: currentURL, folderID: config.id))
                DiagnosticsLogger.shared.log("populateFolderMenu: symlink loop at \(currentPath)")
                return
            }

            var nextVisited = visited
            nextVisited.insert(currentPath)

            addFolderHeader(to: menu, config: config, url: currentURL, isRoot: isRoot)

            let listing = try fileAccessService.directoryListing(in: currentURL, config: config, visited: nextVisited)

            if listing.omittedCount > 0, config.menuSettings.showMoreItemPosition == .top {
                addMoreItem(to: menu, listing: listing, url: currentURL, folderID: config.id)
                menu.addItem(.separator())
            }

            if listing.items.isEmpty {
                addDisabled("No Items", to: menu)
            } else {
                for item in listing.items {
                    menu.addItem(menuItem(for: item, config: config, visited: nextVisited))
                }
            }

            if listing.omittedCount > 0, config.menuSettings.showMoreItemPosition == .bottom {
                menu.addItem(.separator())
                addMoreItem(to: menu, listing: listing, url: currentURL, folderID: config.id)
            }

            if let menuView, isRoot {
                addMenuViewFooter(to: menu, view: menuView, folderConfig: config, url: currentURL)
            } else {
                addFolderFooter(to: menu, config: config, url: currentURL, isRoot: isRoot, menuView: menuView)
            }
        } catch FileAccessError.staleBookmark {
            DiagnosticsLogger.shared.log("populateFolderMenu: stale bookmark for \(config.displayName)")
            addPermissionMenu(to: menu, config: config)
        } catch FileAccessError.missingFolder {
            DiagnosticsLogger.shared.log("populateFolderMenu: missing folder \(config.displayName)")
            addMissingFolderMenu(to: menu, config: config)
        } catch {
            DiagnosticsLogger.shared.log("populateFolderMenu: error for \(config.displayName): \(error.localizedDescription)")
            addDisabled("Folder unavailable", to: menu)
            addDisabled(error.localizedDescription, to: menu)
            menu.addItem(.separator())
            menu.addItem(actionItem("Choose New Location...", kind: .reselectFolder, folderID: config.id))
            menu.addItem(actionItem("Remove Folder...", kind: .removeFolder, folderID: config.id))
        }
    }

    private func menuItem(for item: FileMenuItem, config: FolderConfig, visited: Set<String>) -> NSMenuItem {
        let menuItem = NSMenuItem(title: item.displayName, action: nil, keyEquivalent: "")
        if store.settings.resolvedShowFileAndFolderIcons {
            // Fetch the icon lazily here rather than during directory enumeration.
            // `metadataService.icon(for:size:)` caches per (path, size), so a folder
            // that's been opened before pays no syscall cost. This avoids the
            // worst-case "freeze on first open of a 50k-file repo folder" where
            // every entry triggered a synchronous `NSWorkspace.shared.icon` call.
            let size = config.menuSettings.resolvedFileIconSize.pointSize
            menuItem.image = metadataService.icon(for: item.actionURL, size: size)
        }

        if item.hasSymlinkLoop {
            menuItem.title = "Symlink Loop: \(item.displayName)"
            let submenu = NSMenu(title: item.displayName)
            submenu.autoenablesItems = false
            addDisabled("This link points back into a folder already shown above.", to: submenu)
            submenu.addItem(actionItem("Reveal in Finder", kind: .reveal, url: item.url, folderID: config.id))
            menuItem.submenu = submenu
            return menuItem
        }

        if item.aliasIsBroken {
            menuItem.title = "Alias Target Missing: \(item.displayName)"
            let submenu = NSMenu(title: item.displayName)
            submenu.autoenablesItems = false
            addDisabled("Alias Target Missing", to: submenu)
            submenu.addItem(actionItem("Reveal Alias in Finder", kind: .reveal, url: item.url, folderID: config.id))
            menuItem.submenu = submenu
            return menuItem
        }

        if item.isDirectory,
           store.settings.resolvedShowFolderSubmenus,
           config.openBehavior == .browseFoldersAsSubmenus {
            let submenu = NSMenu(title: item.displayName)
            submenu.autoenablesItems = false
            attachFolderDelegate(to: submenu, configID: config.id, configOverride: config, menuView: nil, folderURL: item.actionURL, isRoot: false, visited: visited)
            menuItem.submenu = submenu
            return menuItem
        }

        if item.isDirectory {
            menuItem.action = #selector(MenuActionHandler.handleMenuAction(_:))
            menuItem.target = actionHandler
            menuItem.representedObject = MenuAction(kind: .open, url: item.actionURL, folderID: config.id)
            return menuItem
        }

        if !store.settings.resolvedShowFileSubmenus {
            menuItem.action = #selector(MenuActionHandler.handleMenuAction(_:))
            menuItem.target = actionHandler
            menuItem.representedObject = MenuAction(kind: .open, url: item.actionURL, folderID: config.id)
            return menuItem
        }

        let submenu = makeFileSubmenu(for: item, config: config)
        menuItem.submenu = submenu
        return menuItem
    }

    private func addShortcutItems(_ shortcuts: [ShortcutMenuItemConfig], to menu: NSMenu, currentSection: inout String?) {
        for shortcut in shortcuts {
            if let section = shortcut.sectionName, !section.isEmpty, section != currentSection {
                if currentSection != nil || menu.items.last?.isSeparatorItem == false {
                    menu.addItem(.separator())
                }
                addDisabled(section, to: menu)
                currentSection = section
            }

            menu.addItem(shortcutMenuItem(for: shortcut))
        }
    }

    private func addLinkedMenuViews(_ linkedMenuViews: [LinkedMenuViewConfig], to menu: NSMenu, currentSection: inout String?, visitedMenuViewIDs: Set<UUID>) {
        for linkedMenuView in linkedMenuViews {
            if let section = linkedMenuView.sectionName, !section.isEmpty, section != currentSection {
                if currentSection != nil || menu.items.last?.isSeparatorItem == false {
                    menu.addItem(.separator())
                }
                addDisabled(section, to: menu)
                currentSection = section
            }

            guard let targetView = store.menuView(id: linkedMenuView.menuViewID) else {
                addDisabled("Missing Menu View", to: menu)
                continue
            }

            let title = linkedMenuView.displayTitle(fallbackTitle: targetView.title)
            if visitedMenuViewIDs.contains(targetView.id) {
                addDisabled("View Loop: \(title)", to: menu)
                continue
            }

            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            item.image = icon(for: linkedMenuView, targetView: targetView, size: 16)

            var nextVisited = visitedMenuViewIDs
            nextVisited.insert(targetView.id)
            item.submenu = makeMenuViewMenu(for: targetView, includeManagement: false, visitedMenuViewIDs: nextVisited)
            menu.addItem(item)
        }
    }

    private func addLinkedShortcutFolders(_ folders: [LinkedShortcutsFolderConfig], to menu: NSMenu, currentSection: inout String?) {
        for folder in folders {
            let shortcuts = store.shortcutsByFolder[folder.folderName]
            if shortcuts == nil {
                store.refreshLinkedShortcutsFolder(folder.folderName, showErrors: false)
            }

            switch folder.displayMode {
            case .submenu:
                let item = NSMenuItem(title: folder.folderName, action: nil, keyEquivalent: "")
                item.image = icon(for: folder, size: 16)
                let submenu = NSMenu(title: folder.folderName)
                submenu.autoenablesItems = false
                if let shortcuts, !shortcuts.isEmpty {
                    for shortcut in shortcuts {
                        submenu.addItem(shortcutMenuItem(for: .make(shortcut: shortcut)))
                    }
                } else if shortcuts == nil {
                    addDisabled("Loading Shortcuts...", to: submenu)
                    submenu.addItem(actionItem("Refresh Shortcuts", kind: .refreshShortcuts))
                } else {
                    addDisabled("No shortcuts in folder", to: submenu)
                }
                item.submenu = submenu
                menu.addItem(item)

            case .inlineSection:
                if currentSection != nil || menu.items.last?.isSeparatorItem == false {
                    menu.addItem(.separator())
                }
                addDisabled(folder.folderName, to: menu)
                currentSection = folder.folderName

                if let shortcuts, !shortcuts.isEmpty {
                    for shortcut in shortcuts {
                        menu.addItem(shortcutMenuItem(for: .make(shortcut: shortcut)))
                    }
                } else if shortcuts == nil {
                    addDisabled("Loading Shortcuts...", to: menu)
                    menu.addItem(actionItem("Refresh Shortcuts", kind: .refreshShortcuts))
                } else {
                    addDisabled("No shortcuts in folder", to: menu)
                }
            }
        }
    }

    private func shortcutMenuItem(for shortcut: ShortcutMenuItemConfig) -> NSMenuItem {
        let item = actionItem(
            shortcut.displayTitle,
            kind: .runShortcut,
            shortcutID: shortcut.shortcutIdentifier,
            shortcutName: shortcut.name
        )
        item.image = icon(for: shortcut, size: 16)

        if let quickKey = shortcut.quickKey?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
           quickKey.count == 1 {
            item.keyEquivalent = quickKey
            item.keyEquivalentModifierMask = []
        }

        return item
    }

    private func addAppleScriptItems(_ items: [AppleScriptMenuItemConfig], to menu: NSMenu, currentSection: inout String?, menuViewID: UUID) {
        for item in items {
            let trimmedSection = item.sectionName?.trimmingCharacters(in: .whitespacesAndNewlines)
            if let section = trimmedSection, !section.isEmpty, section != currentSection {
                if currentSection != nil || menu.items.last?.isSeparatorItem == false {
                    menu.addItem(.separator())
                }
                addDisabled(section, to: menu)
                currentSection = section
            }

            guard let script = store.appleScript(id: item.appleScriptID) else {
                let missing = NSMenuItem(title: "Missing AppleScript", action: nil, keyEquivalent: "")
                missing.toolTip = "The referenced AppleScript no longer exists."
                missing.isEnabled = false
                menu.addItem(missing)
                continue
            }

            menu.addItem(appleScriptMenuItem(for: item, script: script, menuViewID: menuViewID))
        }
    }

    private func appleScriptMenuItem(for item: AppleScriptMenuItemConfig, script: AppleScriptConfig, menuViewID: UUID) -> NSMenuItem {
        let title = item.displayTitle(fallbackName: script.name)
        let menuItem = actionItem(
            title,
            kind: .runAppleScript,
            menuViewID: menuViewID,
            appleScriptID: script.id
        )
        menuItem.image = icon(for: item, fallbackScript: script, size: 16)
        applyQuickKey(item.quickKey, to: menuItem)
        return menuItem
    }

    private func applyQuickKey(_ value: String?, to menuItem: NSMenuItem) {
        guard let raw = value, !raw.isEmpty else {
            menuItem.keyEquivalent = ""
            return
        }
        let scalars = Array(raw.unicodeScalars)
        guard scalars.count == 1 else {
            menuItem.keyEquivalent = ""
            return
        }
        let scalar = scalars[0]
        let category = scalar.properties.generalCategory
        let disallowed: Set<Unicode.GeneralCategory> = [
            .control, .format, .surrogate, .privateUse, .unassigned,
            .spaceSeparator, .lineSeparator, .paragraphSeparator
        ]
        guard !disallowed.contains(category) else {
            menuItem.keyEquivalent = ""
            return
        }
        menuItem.keyEquivalent = String(scalar).lowercased()
        menuItem.keyEquivalentModifierMask = []
    }

    private func makeFileSubmenu(for item: FileMenuItem, config: FolderConfig) -> NSMenu {
        let menu = NSMenu(title: item.displayName)
        menu.autoenablesItems = false
        let actionURL = item.actionURL
        let metadata = metadataService.enrichedMetadata(for: item)
        let optionPressed = NSEvent.modifierFlags.contains(.option)
        let shouldRevealModifierActions = optionPressed || !config.menuSettings.resolvedEnableModifierActions

        if config.menuSettings.resolvedShowTips {
            let tip = shouldRevealModifierActions
                ? "Tips: Drag the preview to export this file."
                : "Tips: Press Option to reveal copy path and dimensions."
            addDisabled(tip, to: menu)
            menu.addItem(.separator())
        }

        menu.addItem(actionItem("Open", kind: .open, url: actionURL, folderID: config.id))
        menu.addItem(openWithItem(for: actionURL, folderID: config.id))
        if isScriptFile(item) {
            menu.addItem(actionItem("Run Script", kind: .runScript, url: actionURL, folderID: config.id))
        }
        if isTextOrCodeFile(item) {
            menu.addItem(actionItem("Copy Contents", kind: .copyContents, url: actionURL, folderID: config.id))
        }
        menu.addItem(actionItem("Show in Finder", kind: .reveal, url: actionURL, folderID: config.id))
        menu.addItem(.separator())
        menu.addItem(actionItem("Move to Trash...", kind: .moveToTrash, url: actionURL, folderID: config.id))
        menu.addItem(.separator())
        menu.addItem(actionItem("Copy File", kind: .copyFile, url: actionURL, folderID: config.id))

        if shouldRevealModifierActions {
            menu.addItem(actionItem("Copy Path", kind: .copyPath, url: actionURL, folderID: config.id))

            if let dimensions = metadataService.formattedDimensions(metadata.dimensions) {
                menu.addItem(actionItem("Copy Dimensions", kind: .copyDimensions, stringValue: dimensions))
            }
        }

        menu.addItem(actionItem("Share...", kind: .share, url: actionURL, folderID: config.id))
        menu.addItem(actionItem("Get Info", kind: .getInfo, url: actionURL, folderID: config.id))

        if config.menuSettings.showPreview {
            menu.addItem(.separator())
            let previewItem = NSMenuItem(title: "Preview", action: nil, keyEquivalent: "")
            previewItem.view = PreviewMenuItemView(item: item, metadataService: metadataService)
            menu.addItem(previewItem)
        }

        if config.menuSettings.showMetadata {
            menu.addItem(.separator())
            addMetadataRows(to: menu, item: item, metadata: metadata)
        }

        return menu
    }

    private func isTextOrCodeFile(_ item: FileMenuItem) -> Bool {
        if let kind = item.kind {
            if kind.conforms(to: .plainText) || kind.conforms(to: .sourceCode) {
                return true
            }
        }
        let ext = item.url.pathExtension.lowercased()
        let textExtensions: Set<String> = [
            "txt", "md", "markdown", "yml", "yaml", "json", "xml", "html", "htm",
            "css", "js", "ts", "jsx", "tsx", "py", "rb", "sh", "bash", "zsh", "fish",
            "swift", "c", "cpp", "cc", "h", "hpp", "m", "mm", "java", "kt", "kts",
            "go", "rs", "php", "pl", "sql", "r", "scala", "lua", "vim", "config",
            "ini", "plist", "log", "csv", "tsv", "diff", "patch", "toml", "env",
            "gitignore", "gitattributes", "dockerfile", "makefile", "cmake", "gradle",
            "podfile", "cartfile", "brewfile", "gemfile", "rakefile", "vue", "svelte",
            "scss", "sass", "less", "graphql", "gql", "dart", "ps1", "bat",
            "cmd", "vbs", "applescript", "jxa", "prisma", "proto"
        ]
        return textExtensions.contains(ext)
    }

    private func isScriptFile(_ item: FileMenuItem) -> Bool {
        let ext = item.url.pathExtension.lowercased()
        return ext == "sh" || ext == "ps1"
    }

    private func openWithItem(for url: URL, folderID: UUID?) -> NSMenuItem {
        let item = NSMenuItem(title: "Open With", action: nil, keyEquivalent: "")
        let submenu = NSMenu(title: "Open With")
        submenu.autoenablesItems = false

        let apps = NSWorkspace.shared.urlsForApplications(toOpen: url)
            .sorted { FileManager.default.displayName(atPath: $0.path) < FileManager.default.displayName(atPath: $1.path) }
            .prefix(12)

        if apps.isEmpty {
            addDisabled("No compatible apps", to: submenu)
        } else {
            for appURL in apps {
                let appName = FileManager.default.displayName(atPath: appURL.path)
                let appItem = actionItem(appName, kind: .openWithApp, url: url, folderID: folderID, appURL: appURL)
                appItem.image = smallIcon(NSWorkspace.shared.icon(forFile: appURL.path), size: 16)
                submenu.addItem(appItem)
            }
        }

        submenu.addItem(.separator())
        submenu.addItem(actionItem("Other...", kind: .openWithOther, url: url, folderID: folderID))

        item.submenu = submenu
        return item
    }

    private func addFolderHeader(to menu: NSMenu, config: FolderConfig, url: URL, isRoot: Bool) {
        guard config.menuSettings.resolvedShowFolderTitle else { return }

        let title = isRoot ? config.displayName : FileManager.default.displayName(atPath: url.path)
        let titleItem = actionItem(title, kind: .open, url: url, folderID: config.id)
        titleItem.image = isRoot ? icon(for: config, size: 16) : metadataService.icon(for: url, size: 16)
        menu.addItem(titleItem)
        menu.addItem(.separator())
    }

    private func addFolderFooter(to menu: NSMenu, config: FolderConfig, url: URL, isRoot: Bool, menuView: MenuViewConfig? = nil) {
        menu.addItem(.separator())
        menu.addItem(actionItem("Open in Finder", kind: .open, url: url, folderID: config.id))
        menu.addItem(openWithItem(for: url, folderID: config.id))
        menu.addItem(actionItem("Open in Terminal", kind: .openInTerminal, url: url, folderID: config.id))
        menu.addItem(actionItem("Show in Finder", kind: .reveal, url: url, folderID: config.id))
        menu.addItem(actionItem("Copy Path", kind: .copyPath, url: url, folderID: config.id))

        menu.addItem(.separator())
        menu.addItem(sortOrderMenuItem(config: config, menuViewID: menuView?.id))

        if isRoot {
            if store.settings.resolvedShowRootFolderManagementItems {
                menu.addItem(.separator())
                menu.addItem(actionItem("Add Item...", kind: .openSettings))
                menu.addItem(actionItem("Settings...", kind: .openSettings))
                menu.addItem(actionItem("Hide From Menu Bar", kind: .hideFolder, folderID: config.id))
                menu.addItem(actionItem("Remove Folder...", kind: .removeFolder, folderID: config.id))
            }
            menu.addItem(.separator())
            menu.addItem(actionItem("Quit MenuShelf", kind: .quit))
        }
    }

    private func addMenuViewFooter(to menu: NSMenu, view: MenuViewConfig, folderConfig: FolderConfig, url: URL) {
        menu.addItem(.separator())
        menu.addItem(actionItem("Open in Finder", kind: .open, url: url, folderID: folderConfig.id))
        menu.addItem(openWithItem(for: url, folderID: folderConfig.id))
        menu.addItem(actionItem("Open in Terminal", kind: .openInTerminal, url: url, folderID: folderConfig.id))
        menu.addItem(actionItem("Show in Finder", kind: .reveal, url: url, folderID: folderConfig.id))
        menu.addItem(actionItem("Copy Path", kind: .copyPath, url: url, folderID: folderConfig.id))

        menu.addItem(.separator())
        menu.addItem(sortOrderMenuItem(config: folderConfig, menuViewID: view.id))

        menu.addItem(.separator())
        menu.addItem(managementMenuItem(for: view))
    }

    private func sortOrderMenuItem(config: FolderConfig, menuViewID: UUID? = nil) -> NSMenuItem {
        let item = NSMenuItem(title: "Sort Order", action: nil, keyEquivalent: "")
        let submenu = NSMenu(title: "Sort Order")
        submenu.autoenablesItems = false

        for sortKey in SortKey.allCases {
            let sortItem = actionItem(sortKey.label, kind: .setSortKey, folderID: config.id, menuViewID: menuViewID, sortKey: sortKey)
            sortItem.state = config.menuSettings.sortKey == sortKey ? .on : .off
            submenu.addItem(sortItem)
        }

        submenu.addItem(.separator())
        for direction in SortDirection.allCases {
            let directionItem = actionItem(direction.label, kind: .setSortDirection, folderID: config.id, menuViewID: menuViewID, sortDirection: direction)
            directionItem.state = config.menuSettings.sortDirection == direction ? .on : .off
            submenu.addItem(directionItem)
        }

        item.submenu = submenu
        return item
    }

    private func addMetadataRows(to menu: NSMenu, item: FileMenuItem, metadata: FileMetadata) {
        var summaryParts = [metadata.kindDescription]
        if let size = metadataService.formattedSize(metadata.size) {
            summaryParts.append(size)
        }
        if let dimensions = metadataService.formattedDimensions(metadata.dimensions) {
            summaryParts.append(dimensions)
        }
        addDisabled(summaryParts.joined(separator: " - "), to: menu)

        menu.addItem(.separator())

        if let duration = metadataService.formattedDuration(metadata.duration) {
            addDisabled("Duration: \(duration)", to: menu)
        }

        if let created = metadataService.formattedDate(metadata.createdAt) {
            addDisabled("Created: \(created)", to: menu)
        }

        if let modified = metadataService.formattedDate(metadata.modifiedAt) {
            addDisabled("Modified: \(modified)", to: menu)
        }

        if let added = metadataService.formattedDate(metadata.addedAt) {
            addDisabled("Added: \(added)", to: menu)
        }

        if item.isAlias {
            addDisabled("Alias", to: menu)
        }

        if item.isSymlink {
            addDisabled("Symlink", to: menu)
        }
    }

    private func addMoreItem(to menu: NSMenu, listing: DirectoryListing, url: URL, folderID: UUID) {
        addDisabled("Showing first \(listing.items.count) of \(listing.totalCount) items", to: menu)
        menu.addItem(actionItem("Show All in Finder", kind: .open, url: url, folderID: folderID))
    }

    private func addMissingFolderMenu(to menu: NSMenu, config: FolderConfig) {
        addDisabled(config.resolvedItemKind == .app ? "App Missing" : "Folder Missing", to: menu)
        addDisabled(config.originalPathHint, to: menu)
        menu.addItem(.separator())
        menu.addItem(actionItem("Locate Item...", kind: .reselectFolder, folderID: config.id))
        menu.addItem(actionItem(config.resolvedItemKind == .app ? "Remove App..." : "Remove Folder...", kind: .removeFolder, folderID: config.id))
        menu.addItem(actionItem("Settings...", kind: .folderSettings, folderID: config.id))
    }

    private func addPermissionMenu(to menu: NSMenu, config: FolderConfig) {
        addDisabled("Permission Required", to: menu)
        addDisabled(config.originalPathHint, to: menu)
        menu.addItem(.separator())
        menu.addItem(actionItem("Grant Access...", kind: .reselectFolder, folderID: config.id))
        menu.addItem(actionItem(config.resolvedItemKind == .app ? "Remove App..." : "Remove Folder...", kind: .removeFolder, folderID: config.id))
        menu.addItem(actionItem("Settings...", kind: .folderSettings, folderID: config.id))
    }

    private func attachFolderDelegate(to menu: NSMenu, configID: UUID, configOverride: FolderConfig?, menuView: MenuViewConfig?, folderURL: URL?, isRoot: Bool, visited: Set<String>) {
        let delegate = FolderMenuDelegate(builder: self, configID: configID, configOverride: configOverride, menuView: menuView, folderURL: folderURL, isRoot: isRoot, visited: visited)
        menu.delegate = delegate
        MenuDelegateRetainer.shared.retain(delegate, for: menu)
    }

    func actionItem(
        _ title: String,
        kind: MenuActionKind,
        url: URL? = nil,
        folderID: UUID? = nil,
        menuViewID: UUID? = nil,
        appURL: URL? = nil,
        stringValue: String? = nil,
        boolValue: Bool? = nil,
        sortKey: SortKey? = nil,
        sortDirection: SortDirection? = nil,
        shortcutID: String? = nil,
        shortcutName: String? = nil,
        shortcutTextInput: String? = nil,
        linkedMenuViewID: UUID? = nil,
        appleScriptID: UUID? = nil,
        browserInfo: BrowserInfo? = nil,
        bookmarkNodeID: UUID? = nil,
        openInBrowserBundleID: String? = nil
    ) -> NSMenuItem {
        let item: NSMenuItem

        if kind == .quit {
            item = NSMenuItem(title: title, action: #selector(NSApplication.terminate(_:)), keyEquivalent: "")
            item.target = NSApp
        } else {
            item = NSMenuItem(title: title, action: #selector(MenuActionHandler.handleMenuAction(_:)), keyEquivalent: "")
            item.target = actionHandler
        }

        item.representedObject = MenuAction(
            kind: kind,
            url: url,
            folderID: folderID,
            menuViewID: menuViewID,
            appURL: appURL,
            stringValue: stringValue,
            boolValue: boolValue,
            sortKey: sortKey,
            sortDirection: sortDirection,
            shortcutID: shortcutID,
            shortcutName: shortcutName,
            shortcutTextInput: shortcutTextInput,
            linkedMenuViewID: linkedMenuViewID,
            appleScriptID: appleScriptID,
            browserInfo: browserInfo,
            bookmarkNodeID: bookmarkNodeID,
            openInBrowserBundleID: openInBrowserBundleID
        )
        item.isEnabled = true
        return item
    }

    func addDisabled(_ title: String, to menu: NSMenu) {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        menu.addItem(item)
    }

    func icon(for config: FolderConfig, size: CGFloat) -> NSImage? {
        let image: NSImage?
        switch config.icon {
        case .folderIcon:
            if let access = try? fileAccessService.accessItem(config) {
                // Keep the security scope alive for the full duration of the
                // icon read (AGENTS.md §"Security-scoped bookmarks").
                image = withExtendedLifetime(access) {
                    metadataService.icon(for: access.url, size: size)
                }
            } else {
                let symbol = config.resolvedItemKind == .app ? "app" : "folder"
                image = NSImage(systemSymbolName: symbol, accessibilityDescription: config.displayName)
                image?.size = NSSize(width: size, height: size)
            }
        case .systemSymbol(let name, _):
            let image = NSImage(systemSymbolName: name, accessibilityDescription: config.displayName)
            image?.size = NSSize(width: size, height: size)
            self.applySymbolScale(to: image, size: size)
            return tintedIfNeeded(image, config: config, size: size)
        case .emoji(let emoji):
            image = imageFromText(emoji, size: size)
        case .monogram(let text):
            image = imageFromText(String(text.prefix(1)).uppercased(), size: size)
        case .customImage(let bookmarkData):
            image = customImage(from: bookmarkData, size: size)
        }

        return tintedIfNeeded(image, config: config, size: size)
    }

    func icon(for view: MenuViewConfig, size: CGFloat) -> NSImage? {
        let pseudoSource = FolderConfig(
            id: view.id,
            displayName: view.title,
            bookmarkData: Data(),
            originalPathHint: "",
            itemKind: .folder,
            isVisible: view.isVisible,
            displayModeOverride: nil,
            icon: view.icon,
            menuBarStyle: view.menuBarStyle,
            menuSettings: view.menuSettings,
            shortcut: view.shortcut,
            openBehavior: .browseFoldersAsSubmenus,
            iconColorHex: view.iconColorHex,
            createdAt: view.createdAt,
            updatedAt: view.updatedAt
        )
        return icon(for: pseudoSource, size: size)
    }

    func icon(for shortcut: ShortcutMenuItemConfig, size: CGFloat) -> NSImage? {
        let pseudoSource = FolderConfig(
            id: shortcut.id,
            displayName: shortcut.displayTitle,
            bookmarkData: Data(),
            originalPathHint: "",
            itemKind: .folder,
            isVisible: true,
            displayModeOverride: nil,
            icon: shortcut.icon ?? .systemSymbol(name: "bolt.fill", tint: nil),
            menuBarStyle: .iconOnly,
            menuSettings: .defaults,
            shortcut: .disabled,
            openBehavior: .browseFoldersAsSubmenus,
            iconColorHex: shortcut.iconColorHex,
            createdAt: shortcut.createdAt,
            updatedAt: shortcut.updatedAt
        )
        return icon(for: pseudoSource, size: size)
    }

    func icon(for item: AppleScriptMenuItemConfig, fallbackScript: AppleScriptConfig, size: CGFloat) -> NSImage? {
        let resolvedIcon = item.icon ?? fallbackScript.icon ?? .systemSymbol(name: appleScriptDefaultSymbolName(), tint: nil)
        let pseudoSource = FolderConfig(
            id: item.id,
            displayName: item.displayTitle(fallbackName: fallbackScript.name),
            bookmarkData: Data(),
            originalPathHint: "",
            itemKind: .folder,
            isVisible: true,
            displayModeOverride: nil,
            icon: resolvedIcon,
            menuBarStyle: .iconOnly,
            menuSettings: .defaults,
            shortcut: .disabled,
            openBehavior: .browseFoldersAsSubmenus,
            iconColorHex: item.iconColorHex ?? fallbackScript.iconColorHex,
            createdAt: item.createdAt,
            updatedAt: item.updatedAt
        )
        return icon(for: pseudoSource, size: size)
    }

    private func appleScriptDefaultSymbolName() -> String {
        if NSImage(systemSymbolName: "applescript", accessibilityDescription: nil) != nil {
            return "applescript"
        }
        if NSImage(systemSymbolName: "scroll", accessibilityDescription: nil) != nil {
            return "scroll"
        }
        DiagnosticsLogger.shared.log("AppleScript SF Symbol fallback unavailable on this system")
        return "doc.text"
    }

    func icon(for folder: LinkedShortcutsFolderConfig, size: CGFloat) -> NSImage? {
        let pseudoSource = FolderConfig(
            id: folder.id,
            displayName: folder.folderName,
            bookmarkData: Data(),
            originalPathHint: "",
            itemKind: .folder,
            isVisible: true,
            displayModeOverride: nil,
            icon: folder.icon ?? .systemSymbol(name: "folder", tint: nil),
            menuBarStyle: .iconOnly,
            menuSettings: .defaults,
            shortcut: .disabled,
            openBehavior: .browseFoldersAsSubmenus,
            iconColorHex: folder.iconColorHex,
            createdAt: folder.createdAt,
            updatedAt: folder.updatedAt
        )
        return icon(for: pseudoSource, size: size)
    }

    func icon(for linkedMenuView: LinkedMenuViewConfig, targetView: MenuViewConfig, size: CGFloat) -> NSImage? {
        var view = targetView
        if let iconOverride = linkedMenuView.iconOverride {
            view.icon = iconOverride
        }
        if linkedMenuView.iconColorHexOverride != nil {
            view.iconColorHex = linkedMenuView.iconColorHexOverride
        }
        return icon(for: view, size: size)
    }

    private func smallIcon(_ image: NSImage?, size: CGFloat) -> NSImage? {
        guard let copy = image?.copy() as? NSImage else { return nil }
        copy.size = NSSize(width: size, height: size)
        return copy
    }

    private func imageFromText(_ text: String, size: CGFloat) -> NSImage {
        let image = NSImage(size: NSSize(width: size, height: size))
        image.lockFocus()
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: size * 0.8, weight: .semibold),
            .paragraphStyle: paragraph,
            .foregroundColor: NSColor.labelColor
        ]
        let rect = NSRect(x: 0, y: (size - size * 0.9) / 2, width: size, height: size)
        text.draw(in: rect, withAttributes: attributes)
        image.unlockFocus()
        return image
    }

    private func customImage(from bookmarkData: Data, size: CGFloat) -> NSImage? {
        var isStale = false
        let url: URL
        do {
            url = try URL(
                resolvingBookmarkData: bookmarkData,
                options: [.withSecurityScope, .withoutUI],
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            )
        } catch {
            DiagnosticsLogger.shared.log("Custom icon bookmark resolve failed: \(error.localizedDescription)")
            return NSImage(systemSymbolName: "photo", accessibilityDescription: "Custom icon")
        }

        if isStale {
            DiagnosticsLogger.shared.log("Custom icon bookmark stale for \(url.path)")
        }

        let didStart = url.startAccessingSecurityScopedResource()
        defer {
            if didStart {
                url.stopAccessingSecurityScopedResource()
            }
        }

        guard let image = NSImage(contentsOf: url) else {
            return NSImage(systemSymbolName: "photo", accessibilityDescription: "Custom icon")
        }
        image.size = NSSize(width: size, height: size)
        return image
    }

    private func tintedIfNeeded(_ image: NSImage?, config: FolderConfig, size: CGFloat) -> NSImage? {
        guard let image,
              let hex = config.iconColorHex,
              let color = NSColor(hexString: hex) else {
            image?.size = NSSize(width: size, height: size)
            return image
        }

        let tinted = NSImage(size: NSSize(width: size, height: size))
        tinted.lockFocus()
        color.set()
        NSRect(origin: .zero, size: tinted.size).fill()
        image.draw(in: NSRect(origin: .zero, size: tinted.size), from: .zero, operation: .destinationIn, fraction: 1)
        tinted.unlockFocus()
        tinted.isTemplate = false
        return tinted
    }

    private func applySymbolScale(to image: NSImage?, size: CGFloat) {
        image?.size = NSSize(width: size, height: size)
    }
}
