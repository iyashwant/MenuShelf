import AppKit
import Foundation

final class MenuDelegateRetainer {
    static let shared = MenuDelegateRetainer()
    private var delegates: [NSObject] = []

    func retain(_ delegate: NSObject) {
        delegates.append(delegate)
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
        builder?.populateFolderMenu(menu, configID: configID, configOverride: configOverride, menuView: menuView, folderURL: folderURL, isRoot: isRoot, visited: visited)
    }
}

final class MenuBuilder {
    private let store: PreferencesStore
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
        if let directMenu = makeDirectSingleFolderMenu(for: view) {
            return directMenu
        }

        let menu = NSMenu(title: view.title)
        menu.autoenablesItems = false

        let showManagementAtTop = shouldShowGlobalManagementMenuAtTop()
        let showManagementAtBottom = shouldShowGlobalManagementMenuAtBottom()

        if showManagementAtTop {
            menu.addItem(managementMenuItem(for: view))
            if !view.items.isEmpty {
                menu.addItem(.separator())
            }
        }

        if view.items.isEmpty {
            addDisabled("No sources in this view", to: menu)
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
        }

        if showManagementAtBottom {
            menu.addItem(.separator())
            menu.addItem(managementMenuItem(for: view))
        }

        return menu
    }

    private func makeDirectSingleFolderMenu(for view: MenuViewConfig) -> NSMenu? {
        let layout = view.resolvedLayout
        guard layout != .sourceList else { return nil }
        guard view.items.count == 1,
              let item = view.items.first,
              var source = store.folder(id: item.sourceID),
              source.resolvedItemKind == .folder else {
            return nil
        }

        if layout == .automatic || layout == .firstFolderContents {
            source.displayName = view.title
            source.icon = view.icon
            source.iconColorHex = view.iconColorHex
            source.menuBarStyle = view.menuBarStyle
            source.menuSettings = view.menuSettings
            let menu = NSMenu(title: view.title)
            menu.autoenablesItems = false
            attachFolderDelegate(to: menu, configID: source.id, configOverride: source, menuView: view, folderURL: nil, isRoot: true, visited: [])
            return menu
        }

        return nil
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

        return menu
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
                item.representedObject = MenuAction(kind: .open, url: access.url, folderID: config.id)
                _ = access
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

        submenu.addItem(actionItem("Add Menu View...", kind: .addMenuView))

        let addFolder = actionItem("Add Folder...", kind: .addFolder, menuViewID: view?.id)
        addFolder.keyEquivalent = "a"
        addFolder.keyEquivalentModifierMask = [.command]
        submenu.addItem(addFolder)
        submenu.addItem(actionItem("Add App...", kind: .addApp, menuViewID: view?.id))
        submenu.addItem(.separator())

        submenu.addItem(toggleMenuViewsMenuItem())
        submenu.addItem(actionItem("Show All Menu Views", kind: .showAllMenuViews))
        submenu.addItem(.separator())

        if let view {
            submenu.addItem(actionItem("View Settings...", kind: .menuViewSettings, menuViewID: view.id))
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
        more.submenu = moreSubmenu
        submenu.addItem(more)

        submenu.addItem(.separator())
        submenu.addItem(actionItem("Quit MenuShelf", kind: .quit))
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
            return
        }

        do {
            let access = try fileAccessService.accessFolder(config)
            let currentURL = folderURL ?? access.url
            let currentPath = currentURL.standardizedFileURL.path

            if visited.contains(currentPath) {
                addDisabled("Symlink Loop Detected", to: menu)
                menu.addItem(actionItem("Show in Finder", kind: .reveal, url: currentURL, folderID: config.id))
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
                addFolderFooter(to: menu, config: config, url: currentURL, isRoot: isRoot)
            }
        } catch FileAccessError.staleBookmark {
            addPermissionMenu(to: menu, config: config)
        } catch FileAccessError.missingFolder {
            addMissingFolderMenu(to: menu, config: config)
        } catch {
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
            menuItem.image = smallIcon(item.icon, size: config.menuSettings.resolvedFileIconSize.pointSize)
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

    private func addFolderFooter(to menu: NSMenu, config: FolderConfig, url: URL, isRoot: Bool) {
        menu.addItem(.separator())
        menu.addItem(actionItem("Open in Finder", kind: .open, url: url, folderID: config.id))
        if isRoot || config.menuSettings.resolvedShowOpenWithForSubfolders {
            menu.addItem(openWithItem(for: url, folderID: config.id))
        }
        menu.addItem(actionItem("Show in Finder", kind: .reveal, url: url, folderID: config.id))
        menu.addItem(actionItem("Copy Path", kind: .copyPath, url: url, folderID: config.id))

        if !isRoot, NSEvent.modifierFlags.contains(.shift) {
            menu.addItem(.separator())
            menu.addItem(sortOrderMenuItem(config: config))
        }

        if isRoot {
            menu.addItem(.separator())
            menu.addItem(actionItem("Add Folder...", kind: .addFolder))
            menu.addItem(actionItem("Add App...", kind: .addApp))
            menu.addItem(actionItem("Folder Settings...", kind: .folderSettings, folderID: config.id))
            menu.addItem(actionItem("Settings...", kind: .openSettings))
            menu.addItem(actionItem("Hide From Menu Bar", kind: .hideFolder, folderID: config.id))
            menu.addItem(actionItem("Remove Folder...", kind: .removeFolder, folderID: config.id))
            menu.addItem(.separator())
            menu.addItem(actionItem("Quit MenuShelf", kind: .quit))
        }
    }

    private func addMenuViewFooter(to menu: NSMenu, view: MenuViewConfig, folderConfig: FolderConfig, url: URL) {
        menu.addItem(.separator())
        menu.addItem(actionItem("Open in Finder", kind: .open, url: url, folderID: folderConfig.id))
        menu.addItem(openWithItem(for: url, folderID: folderConfig.id))
        menu.addItem(actionItem("Show in Finder", kind: .reveal, url: url, folderID: folderConfig.id))
        menu.addItem(actionItem("Copy Path", kind: .copyPath, url: url, folderID: folderConfig.id))

        menu.addItem(.separator())
        menu.addItem(managementMenuItem(for: view))
    }

    private func sortOrderMenuItem(config: FolderConfig) -> NSMenuItem {
        let item = NSMenuItem(title: "Sort Order", action: nil, keyEquivalent: "")
        let submenu = NSMenu(title: "Sort Order")
        submenu.autoenablesItems = false

        for sortKey in SortKey.allCases {
            let sortItem = actionItem(sortKey.label, kind: .setSortKey, folderID: config.id, sortKey: sortKey)
            sortItem.state = config.menuSettings.sortKey == sortKey ? .on : .off
            submenu.addItem(sortItem)
        }

        submenu.addItem(.separator())
        for direction in SortDirection.allCases {
            let directionItem = actionItem(direction.label, kind: .setSortDirection, folderID: config.id, sortDirection: direction)
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
        MenuDelegateRetainer.shared.retain(delegate)
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
        sortDirection: SortDirection? = nil
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
            sortDirection: sortDirection
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
                image = metadataService.icon(for: access.url, size: size)
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
        guard let url = try? URL(
            resolvingBookmarkData: bookmarkData,
            options: [.withSecurityScope, .withoutUI],
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        ) else {
            return NSImage(systemSymbolName: "photo", accessibilityDescription: "Custom icon")
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
