import AppKit
import Combine
import Foundation

final class StatusItemManager: NSObject {
    private let store: PreferencesStore
    private let menuBuilder: MenuBuilder
    private let actionHandler: MenuActionHandler
    private let metadataService: MetadataService
    private let presentationCoordinator: MenuPresentationCoordinator
    private let hotkeyService: GlobalHotkeyService
    private struct StatusContext {
        var item: NSStatusItem
        var menuViewID: UUID?
        var isFallback: Bool
    }

    private var statusItems: [StatusContext] = []
    private var statusItemsByButton: [ObjectIdentifier: StatusContext] = [:]
    private var cancellable: AnyCancellable?

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

        let showMenuBarItemWhenEmpty: Bool
        let views: [ViewSignature]

        init(_ settings: AppSettings) {
            self.showMenuBarItemWhenEmpty = settings.showMenuBarItemWhenEmpty
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
        let entries: [Entry]

        init(_ settings: AppSettings) {
            self.entries = settings.resolvedMenuViews.map {
                Entry(menuViewID: $0.id, shortcut: $0.shortcut, isVisible: $0.isVisible)
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
        DiagnosticsLogger.shared.log("Rebuilding status items. visibleViews=\(visibleViews.count) totalViews=\(store.settings.resolvedMenuViews.count) sources=\(store.settings.folders.count)")

        if visibleViews.isEmpty, store.settings.showMenuBarItemWhenEmpty {
            makeEmptyStatusItem()
        } else {
            for view in visibleViews {
                makeMenuViewStatusItem(view)
            }
        }

        publishStatusItems()

        // Only re-register Carbon hotkeys when the hotkey set actually changed.
        // A title or icon edit no longer unregisters/re-registers all hotkeys.
        let hotkeys = HotkeysSignature(store.settings)
        if hotkeys != lastHotkeys {
            lastHotkeys = hotkeys
            registerHotkeys()
        }
    }

    private func makeMenuViewStatusItem(_ view: MenuViewConfig) {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        configure(button: item.button, view: view)
        item.menu = menuBuilder.makeMenuViewMenu(for: view)
        statusItems.append(StatusContext(item: item, menuViewID: view.id, isFallback: false))
        configureClickHandling(item: item, menuViewID: view.id, isFallback: false)
        DiagnosticsLogger.shared.log("Created status item for view \(view.title) title=\(item.button?.title ?? "nil") length=\(item.length) hasImage=\(item.button?.image != nil)")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            DiagnosticsLogger.shared.log(
                "Menu view status item attached view=\(view.title) title=\(item.button?.title ?? "nil") window=\(String(describing: item.button?.window)) windowFrame=\(String(describing: item.button?.window?.frame)) frame=\(String(describing: item.button?.frame)) visible=\(item.isVisible)"
            )
        }
    }

    private func makeEmptyStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItems.append(StatusContext(item: item, menuViewID: nil, isFallback: true))

        if let button = item.button {
            button.image = reliableMenuViewSymbol()
            button.title = "MenuShelf"
            button.imagePosition = .imageLeading
            button.isEnabled = true
            button.toolTip = "MenuShelf: Add Folder or App"
        }

        item.menu = menuBuilder.makeGroupedMenu()
        configureClickHandling(item: item, menuViewID: nil, isFallback: true)
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

    private func configureClickHandling(item: NSStatusItem, menuViewID: UUID?, isFallback: Bool) {
        guard let button = item.button else { return }
        button.target = self
        button.action = #selector(handleStatusItemClick(_:))
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])

        let context = StatusContext(item: item, menuViewID: menuViewID, isFallback: isFallback)
        statusItemsByButton[ObjectIdentifier(button)] = context
    }

    @objc private func handleStatusItemClick(_ sender: NSStatusBarButton) {
        guard let context = statusItemsByButton[ObjectIdentifier(sender)] else { return }

        let event = NSApp.currentEvent
        let isAlternateOpen = event?.type == .rightMouseUp || event?.modifierFlags.contains(.option) == true

        if isAlternateOpen {
            if let menuViewID = context.menuViewID {
                AppContainer.shared.settingsWindowController.show(selectedMenuViewID: menuViewID)
            } else {
                AppContainer.shared.settingsWindowController.show()
            }
            return
        }

        if context.isFallback {
            presentationCoordinator.presentGroupedMenu(anchoredTo: context.item)
        } else if let menuViewID = context.menuViewID {
            presentationCoordinator.presentMenu(forMenuViewID: menuViewID, location: .menuBarItem, anchoredTo: context.item)
        }
    }

    /// Toggle a "running" appearance on the status item for a menu view, used
    /// while an AppleScript is executing. Tints the icon with the system accent
    /// color; clears the tint on completion.
    func setRunningIndicator(menuViewID: UUID, isRunning: Bool) {
        guard let context = statusItems.first(where: { $0.menuViewID == menuViewID }),
              let button = context.item.button else { return }
        button.contentTintColor = isRunning ? NSColor.controlAccentColor : nil
    }

    private func publishStatusItems() {
        var menuViews: [UUID: NSStatusItem] = [:]
        var fallback: NSStatusItem?
        for context in statusItems {
            if let menuViewID = context.menuViewID {
                menuViews[menuViewID] = context.item
            }
            if context.isFallback {
                fallback = context.item
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

    private func fallbackMenuViewImage(size: CGFloat) -> NSImage {
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
