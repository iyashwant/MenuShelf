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

        // Note: a previous implementation tried to add an NSEvent local monitor
        // to capture Ctrl+Tab while the menu was open and cycle to the next
        // visible menu view. AppKit consumes keyboard events during NSMenu
        // tracking, so local monitors don't fire. The cycle-views feature is
        // disabled until we can implement it via a CGEventTap or via the
        // accessibility APIs.

        if atCursor || statusItem == nil {
            menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
            return
        }

        statusItem?.popUpMenu(menu)
    }
}
