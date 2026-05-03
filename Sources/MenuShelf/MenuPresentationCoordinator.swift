import AppKit
import Foundation

final class MenuPresentationCoordinator {
    private let store: PreferencesStore
    private let menuBuilder: MenuBuilder
    private var fallbackStatusItem: NSStatusItem?
    private var statusItemsByMenuViewID: [UUID: NSStatusItem] = [:]

    init(store: PreferencesStore, menuBuilder: MenuBuilder) {
        self.store = store
        self.menuBuilder = menuBuilder
    }

    func updateStatusItems(fallback: NSStatusItem?, menuViews: [UUID: NSStatusItem]) {
        fallbackStatusItem = fallback
        statusItemsByMenuViewID = menuViews
    }

    func presentGroupedMenu(anchoredTo statusItem: NSStatusItem? = nil, atCursor: Bool = false) {
        let menu = menuBuilder.makeGroupedMenu()
        popUp(menu, anchoredTo: statusItem ?? fallbackStatusItem, atCursor: atCursor, currentMenuViewID: nil)
    }

    func presentMenu(forMenuViewID menuViewID: UUID, location: ShortcutOpenLocation? = nil, anchoredTo statusItem: NSStatusItem? = nil) {
        guard let view = store.menuView(id: menuViewID) else { return }

        let menu = menuBuilder.makeMenuViewMenu(for: view)
        let resolvedLocation = location ?? view.resolvedOpenLocation ?? store.settings.resolvedShortcutOpenLocation
        let item = statusItem ?? statusItemsByMenuViewID[menuViewID]
        popUp(menu, anchoredTo: item, atCursor: resolvedLocation == .cursor, currentMenuViewID: menuViewID)
    }

    func presentNextVisibleMenu(after menuViewID: UUID?, reverse: Bool) {
        let visible = store.settings.resolvedMenuViews.filter(\.isVisible)
        guard !visible.isEmpty else { return }

        let currentIndex = menuViewID.flatMap { id in visible.firstIndex { $0.id == id } } ?? 0
        let nextIndex: Int
        if reverse {
            nextIndex = currentIndex == 0 ? visible.count - 1 : currentIndex - 1
        } else {
            nextIndex = currentIndex == visible.count - 1 ? 0 : currentIndex + 1
        }

        presentMenu(forMenuViewID: visible[nextIndex].id, location: .menuBarItem)
    }

    private func popUp(_ menu: NSMenu, anchoredTo statusItem: NSStatusItem?, atCursor: Bool, currentMenuViewID: UUID?) {
        menu.autoenablesItems = false
        let monitor = installSwitchMonitor(for: menu, currentMenuViewID: currentMenuViewID)
        defer {
            if let monitor {
                NSEvent.removeMonitor(monitor)
            }
        }

        if atCursor || statusItem == nil {
            menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
            return
        }

        statusItem?.popUpMenu(menu)
    }

    private func installSwitchMonitor(for menu: NSMenu, currentMenuViewID: UUID?) -> Any? {
        guard currentMenuViewID != nil else { return nil }

        return NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self, weak menu] event in
            guard let self, let menu else { return event }

            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            guard event.keyCode == 48, flags.contains(.control) else {
                return event
            }

            menu.cancelTracking()
            DispatchQueue.main.async {
                self.presentNextVisibleMenu(after: currentMenuViewID, reverse: flags.contains(.shift))
            }
            return nil
        }
    }
}
