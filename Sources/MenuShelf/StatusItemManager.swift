import AppKit
import Combine
import Foundation

final class StatusItemManager: NSObject {
    private let store: PreferencesStore
    let menuBuilder: MenuBuilder
    private let actionHandler: MenuActionHandler
    private let metadataService: MetadataService
    private let presentationCoordinator: MenuPresentationCoordinator
    private let hotkeyService: GlobalHotkeyService
    enum StatusContext {
        case menuView(NSStatusItem, UUID)
        case standaloneModule(NSStatusItem, StandaloneModuleConfig)
        case fallback(NSStatusItem)

        var item: NSStatusItem {
            switch self {
            case .menuView(let item, _),
                 .standaloneModule(let item, _),
                 .fallback(let item):
                return item
            }
        }
    }

    var statusItems: [StatusContext] = []
    var statusItemsByButton: [ObjectIdentifier: StatusContext] = [:]
    private var cancellable: AnyCancellable?

    /// Returns the `NSStatusBarButton` for the menu view with the given id,
    /// when the view has a visible status item. Used by Clipboard Shelf to
    /// anchor the popup to the originating menu view's icon (Requirement 4.2).
    func statusBarButton(for menuViewID: UUID) -> NSStatusBarButton? {
        for context in statusItems {
            if case .menuView(let item, let id) = context, id == menuViewID {
                return item.button
            }
        }
        return nil
    }

    /// Returns the `NSStatusBarButton` for the standalone module with the
    /// given id, when the module has a visible status item. Used by the
    /// hotkey anchor fallback (Task 8) and the settings deep-link
    /// (Task 9.3).
    func statusBarButton(forStandaloneModuleID id: UUID) -> NSStatusBarButton? {
        for context in statusItems {
            if case .standaloneModule(let item, let module) = context, module.id == id {
                return item.button
            }
        }
        return nil
    }

    /// The subset of settings that affect the menu bar's outward shape: which
    /// status items exist, their titles, icons, styles, and registered hotkeys.
    /// We rebuild only when this changes; menu *contents* refresh lazily through
    /// each menu's delegate, so a TextField edit in settings no longer flickers
    /// every status item.
    private struct MenuBarShape: Equatable {
        struct ViewSignature: Equatable {
            let id: UUID
            let isVisible: Bool
            let title: String
            let menuBarStyle: MenuBarStyle
            let icon: FolderIconConfig
            let iconColorHex: String?
            let shortcut: KeyboardShortcutConfig?
        }

        struct StandaloneModuleSignature: Equatable {
            let id: UUID
            let kind: ModuleKind
            let isVisible: Bool
            let title: String
            let menuBarStyle: MenuBarStyle
            let icon: FolderIconConfig
            let iconColorHex: String?
            let shortcut: KeyboardShortcutConfig?
        }

        let showMenuBarItemWhenEmpty: Bool
        let enableBrowserFlip: Bool
        let views: [ViewSignature]
        let standaloneModules: [StandaloneModuleSignature]

        init(_ settings: AppSettings) {
            self.showMenuBarItemWhenEmpty = settings.showMenuBarItemWhenEmpty
            self.enableBrowserFlip = settings.resolvedBrowserFlip.enableBrowserFlip
            self.views = settings.resolvedMenuViews.map { view in
                ViewSignature(
                    id: view.id,
                    isVisible: view.isVisible,
                    title: view.title,
                    menuBarStyle: view.menuBarStyle,
                    icon: view.icon,
                    iconColorHex: view.iconColorHex,
                    shortcut: view.shortcut
                )
            }
            self.standaloneModules = settings.resolvedStandaloneModules
                .sorted { $0.sortOrder < $1.sortOrder }
                .map { module in
                    StandaloneModuleSignature(
                        id: module.id,
                        kind: module.kind,
                        isVisible: module.isVisible,
                        title: module.title,
                        menuBarStyle: module.menuBarStyle,
                        icon: module.icon,
                        iconColorHex: module.iconColorHex,
                        shortcut: module.shortcut
                    )
                }
        }
    }
    private var lastShape: MenuBarShape?

    /// Signature of the registered global hotkeys. We split this from MenuBarShape
    /// so a title or icon edit doesn't unregister/re-register Carbon hotkeys, which
    /// is both wasteful and racy (a press during the unregister/register window
    /// can be lost).
    private struct HotkeysSignature: Equatable {
        struct Entry: Equatable {
            let menuViewID: UUID
            let shortcut: KeyboardShortcutConfig?
            let isVisible: Bool
        }

        struct StandaloneModuleEntry: Equatable {
            let standaloneModuleID: UUID
            let kind: ModuleKind
            let shortcut: KeyboardShortcutConfig?
            let isVisible: Bool
        }

        let entries: [Entry]
        let standaloneModuleEntries: [StandaloneModuleEntry]

        init(_ settings: AppSettings) {
            self.entries = settings.resolvedMenuViews.map {
                Entry(menuViewID: $0.id, shortcut: $0.shortcut, isVisible: $0.isVisible)
            }
            self.standaloneModuleEntries = settings.resolvedStandaloneModules
                .sorted { $0.sortOrder < $1.sortOrder }
                .map {
                    StandaloneModuleEntry(
                        standaloneModuleID: $0.id,
                        kind: $0.kind,
                        shortcut: $0.shortcut,
                        isVisible: $0.isVisible
                    )
                }
        }
    }
    private var lastHotkeys: HotkeysSignature?

    init(
        store: PreferencesStore,
        menuBuilder: MenuBuilder,
        actionHandler: MenuActionHandler,
        metadataService: MetadataService,
        presentationCoordinator: MenuPresentationCoordinator,
        hotkeyService: GlobalHotkeyService
    ) {
        self.store = store
        self.menuBuilder = menuBuilder
        self.actionHandler = actionHandler
        self.metadataService = metadataService
        self.presentationCoordinator = presentationCoordinator
        self.hotkeyService = hotkeyService
        super.init()

        cancellable = store.$settings
            // Only rebuild when something the menu bar actually depends on
            // (visible views, titles, icons, hotkeys) changes. Menu *contents*
            // refresh lazily through each menu's NSMenuDelegate, so a TextField
            // edit deeper in settings no longer flickers every status item or
            // re-registers Carbon hotkeys.
            .map(MenuBarShape.init)
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.rebuildStatusItems()
            }
    }

    func rebuildStatusItems() {
        // Track the latest applied shape so direct callers (e.g. AppDelegate.start())
        // stay in sync with the diff-driven sink.
        lastShape = MenuBarShape(store.settings)

        removeAllStatusItems()

        let visibleViews = store.settings.resolvedMenuViews.filter(\.isVisible)
        let visibleModules = store.settings.resolvedStandaloneModules
            .filter(\.isVisible)
            .sorted { $0.sortOrder < $1.sortOrder }
        DiagnosticsLogger.shared.log(
            "Rebuilding status items. visibleViews=\(visibleViews.count) "
            + "visibleStandaloneModules=\(visibleModules.count) "
            + "totalViews=\(store.settings.resolvedMenuViews.count) "
            + "totalStandaloneModules=\(store.settings.resolvedStandaloneModules.count) "
            + "sources=\(store.settings.folders.count)"
        )

        if visibleViews.isEmpty
            && visibleModules.isEmpty
            && store.settings.showMenuBarItemWhenEmpty {
            makeEmptyStatusItem()
        } else {
            for view in visibleViews {
                makeMenuViewStatusItem(view)
            }
            for module in visibleModules {
                makeStandaloneModuleStatusItem(module)
            }
        }

        publishStatusItems()

        // Only re-register Carbon hotkeys when the hotkey set actually changed.
        // A title or icon edit no longer unregisters/re-registers all hotkeys.
        let hotkeys = HotkeysSignature(store.settings)
        if hotkeys != lastHotkeys {
            lastHotkeys = hotkeys
            registerHotkeys()
            registerStandaloneModuleHotkeys()
        }
    }

    private func makeMenuViewStatusItem(_ view: MenuViewConfig) {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        configure(button: item.button, view: view)
        item.menu = menuBuilder.makeMenuViewMenu(for: view)
        statusItems.append(.menuView(item, view.id))
        configureClickHandling(item: item, context: .menuView(item, view.id))
        DiagnosticsLogger.shared.log("Created status item for view \(view.title) title=\(item.button?.title ?? "nil") length=\(item.length) hasImage=\(item.button?.image != nil)")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            DiagnosticsLogger.shared.log(
                "Menu view status item attached view=\(view.title) title=\(item.button?.title ?? "nil") window=\(String(describing: item.button?.window)) windowFrame=\(String(describing: item.button?.window?.frame)) frame=\(String(describing: item.button?.frame)) visible=\(item.isVisible)"
            )
        }
    }

    private func makeEmptyStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItems.append(.fallback(item))

        if let button = item.button {
            button.image = reliableMenuViewSymbol()
            button.title = "MenuShelf"
            button.imagePosition = .imageLeading
            button.isEnabled = true
            button.toolTip = "MenuShelf: Add Folder or App"
        }

        item.menu = menuBuilder.makeGroupedMenu()
        configureClickHandling(item: item, context: .fallback(item))
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            DiagnosticsLogger.shared.log(
                "Empty status item attached window=\(String(describing: item.button?.window)) windowFrame=\(String(describing: item.button?.window?.frame)) frame=\(String(describing: item.button?.frame)) visible=\(item.isVisible) hasImage=\(item.button?.image != nil)"
            )
        }
    }

    private func configure(button: NSStatusBarButton?, view: MenuViewConfig) {
        guard let button else { return }

        button.toolTip = view.title
        button.isEnabled = true

        let title = visibleTitle(for: view)
        let image = statusImage(for: view, size: 18)
        image.isTemplate = shouldTemplateIcon(view)

        switch view.menuBarStyle {
        case .iconOnly:
            button.title = ""
            button.image = image
            button.imagePosition = .imageOnly
        case .titleOnly:
            button.title = title
            button.image = nil
            button.imagePosition = .noImage
        case .iconAndTitle:
            button.title = title
            button.image = image
            button.imagePosition = .imageLeading
        }
    }

    private func removeAllStatusItems() {
        DiagnosticsLogger.shared.log("Removing \(statusItems.count) status items")
        for context in statusItems {
            NSStatusBar.system.removeStatusItem(context.item)
        }
        statusItems.removeAll()
        statusItemsByButton.removeAll()
    }

    func configureClickHandling(item: NSStatusItem, context: StatusContext) {
        guard let button = item.button else { return }
        button.target = self
        button.action = #selector(handleStatusItemClick(_:))
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])

        statusItemsByButton[ObjectIdentifier(button)] = context
    }

    @MainActor
    @objc private func handleStatusItemClick(_ sender: NSStatusBarButton) {
        guard let context = statusItemsByButton[ObjectIdentifier(sender)] else { return }

        let event = NSApp.currentEvent
        let eventType: NSEvent.EventType = event?.type ?? .leftMouseUp
        let modifiers = event?.modifierFlags ?? []
        let isAlternateOpen = eventType == .rightMouseUp || modifiers.contains(.option)

        switch context {
        case .menuView(let item, let menuViewID):
            if isAlternateOpen {
                AppContainer.shared.settingsWindowController.show(selectedMenuViewID: menuViewID)
                return
            }
            presentationCoordinator.presentMenu(forMenuViewID: menuViewID, location: .menuBarItem, anchoredTo: item)

        case .standaloneModule(let item, let module):
            StandaloneModuleClickRouter.shared.dispatch(
                module: module,
                anchorButton: sender,
                anchorItem: item,
                eventType: eventType,
                modifierFlags: modifiers,
                presentationCoordinator: presentationCoordinator
            )

        case .fallback(let item):
            if isAlternateOpen {
                AppContainer.shared.settingsWindowController.show()
                return
            }
            presentationCoordinator.presentGroupedMenu(anchoredTo: item)
        }
    }

    /// Toggle a "running" appearance on the status item for a menu view, used
    /// while an AppleScript is executing. Tints the icon with the system accent
    /// color; clears the tint on completion.
    func setRunningIndicator(menuViewID: UUID, isRunning: Bool) {
        for context in statusItems {
            if case .menuView(let item, let id) = context, id == menuViewID {
                item.button?.contentTintColor = isRunning ? NSColor.controlAccentColor : nil
                return
            }
        }
    }

    /// Tint every visible standalone status item of `kind` with the system
    /// accent color while `isActive`, clearing the tint otherwise. Used by
    /// CaffeineShelf to reflect its keep-awake state on the menu-bar icon. A
    /// module kind can have more than one standalone item, so all matches are
    /// updated rather than returning on the first.
    func setStandaloneModuleActiveIndicator(kind: ModuleKind, isActive: Bool) {
        for context in statusItems {
            if case .standaloneModule(let item, let module) = context, module.kind == kind {
                item.button?.contentTintColor = isActive ? NSColor.controlAccentColor : nil
            }
        }
    }

    private func publishStatusItems() {
        var menuViews: [UUID: NSStatusItem] = [:]
        var fallback: NSStatusItem?
        for context in statusItems {
            switch context {
            case .menuView(let item, let menuViewID):
                menuViews[menuViewID] = item
            case .standaloneModule:
                // Skipped until Task 7 wires standalone-module publication.
                break
            case .fallback(let item):
                fallback = item
            }
        }

        presentationCoordinator.updateStatusItems(fallback: fallback, menuViews: menuViews)
    }

    private func registerHotkeys() {
        hotkeyService.registerShortcuts(for: store.settings.resolvedMenuViews) { [weak self] menuViewID in
            guard let self else { return }
            self.presentationCoordinator.presentMenu(
                forMenuViewID: menuViewID,
                location: self.store.settings.resolvedShortcutOpenLocation
            )
        }
    }

    private func registerStandaloneModuleHotkeys() {
        hotkeyService.registerStandaloneModuleShortcuts(
            for: store.settings.resolvedStandaloneModules
        ) { [weak self] standaloneModuleID in
            MainActor.assumeIsolated {
                guard let self else { return }
                guard let module = self.store.settings.resolvedStandaloneModules
                    .first(where: { $0.id == standaloneModuleID }) else { return }
                let anchor = self.statusBarButton(forStandaloneModuleID: standaloneModuleID)
                StandaloneModuleClickRouter.shared.dispatchHotkey(
                    module: module,
                    anchorButton: anchor,
                    anchorItem: nil,
                    presentationCoordinator: self.presentationCoordinator
                )
            }
        }
    }

    private func shouldTemplateIcon(_ view: MenuViewConfig) -> Bool {
        if view.iconColorHex != nil {
            return false
        }

        switch view.icon {
        case .emoji, .customImage:
            return false
        case .folderIcon, .systemSymbol, .monogram:
            return true
        }
    }

    private func visibleTitle(for view: MenuViewConfig) -> String {
        let title = view.title.trimmingCharacters(in: .whitespacesAndNewlines)
        return title.isEmpty ? "MenuShelf" : title
    }

    private func reliableMenuViewSymbol() -> NSImage? {
        let image = NSImage(systemSymbolName: "menubar.rectangle", accessibilityDescription: "MenuShelf")
            ?? NSImage(systemSymbolName: "folder", accessibilityDescription: "MenuShelf")
        image?.size = NSSize(width: 18, height: 18)
        image?.isTemplate = true
        return image
    }

    private func statusImage(for view: MenuViewConfig, size: CGFloat) -> NSImage {
        if case .folderIcon = view.icon {
            return fallbackMenuViewImage(size: size)
        }

        if let image = menuBuilder.icon(for: view, size: size) {
            image.size = NSSize(width: size, height: size)
            return image
        }

        return fallbackMenuViewImage(size: size)
    }

    func fallbackMenuViewImage(size: CGFloat) -> NSImage {
        let image = NSImage(size: NSSize(width: size, height: size))
        image.lockFocus()

        NSColor.black.setFill()
        let outer = NSBezierPath(roundedRect: NSRect(x: 2, y: 3, width: size - 4, height: size - 6), xRadius: 3, yRadius: 3)
        outer.fill()

        NSColor.white.setFill()
        for index in 0..<3 {
            let y = size - 7 - CGFloat(index * 4)
            NSBezierPath(roundedRect: NSRect(x: 5, y: y, width: size - 10, height: 1.4), xRadius: 0.7, yRadius: 0.7).fill()
        }

        image.unlockFocus()
        image.isTemplate = true
        return image
    }
}
