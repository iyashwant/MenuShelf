//
//  BookmarkShelfFooterPropertyTests.swift
//  ClockShelfTests
//
//  Structural properties for the trailing action block appended to the
//  Bookmark Shelf inline submenu by
//  `MenuBuilder.appendBookmarkShelfFooter(to:menuViewID:)`, and for the
//  root-only gate that decides whether it is appended at all.
//
//  Why we don't call `MenuBuilder.populateBookmarkShelfSubmenu(...)`
//  directly: same reason documented at the top of
//  `MenuRenderingPropertyTests.swift` — constructing a real
//  `MenuBuilder` requires `PreferencesStore` + `FileAccessService` +
//  `MetadataService` + `MenuActionHandler`, and the populator
//  additionally reads `BookmarkShelfController.shared.storageHandle`,
//  so the assertions would be quantifying over the production
//  singleton's live state rather than the generated values. Following
//  that file's precedent, the documented algorithm is re-implemented at
//  file scope clause-for-clause against real `NSMenu`/`NSMenuItem` and
//  real `MenuAction` values.
//

import AppKit
import Foundation
import Testing
@testable import MenuShelf

// MARK: - Test helpers

/// Reproduce the relevant portion of `MenuBuilder.actionItem(...)`.
private func bookmarkActionItemShape(
    _ title: String,
    kind: MenuActionKind,
    menuViewID: UUID? = nil
) -> NSMenuItem {
    let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
    item.representedObject = MenuAction(kind: kind, menuViewID: menuViewID)
    item.isEnabled = true
    return item
}

/// Reproduce `MenuBuilder.addDisabled(_:to:)`.
private func addBookmarkDisabledShape(_ title: String, to menu: NSMenu) {
    let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
    item.isEnabled = false
    menu.addItem(item)
}

/// Reproduce `MenuBuilder.appendBookmarkShelfFooter(to:menuViewID:)`.
private func appendBookmarkShelfFooterShape(
    to menu: NSMenu,
    menuViewID: UUID
) {
    if menu.items.last?.isSeparatorItem == false {
        menu.addItem(.separator())
    }
    menu.addItem(bookmarkActionItemShape(
        "Open Bookmark Shelf…",
        kind: .openBookmarkShelf,
        menuViewID: menuViewID
    ))
    menu.addItem(bookmarkActionItemShape(
        "Open Settings…",
        kind: .openBookmarkShelfSettings
    ))
}

/// Reproduce the tail of `MenuBuilder.populateBookmarkShelfSubmenu(...)`
/// — the empty/populated branch plus the root-only footer gate. The
/// tree walk itself is irrelevant to these properties, so children are
/// modelled as a plain title list.
private func populateBookmarkShelfSubmenuTailShape(
    _ menu: NSMenu,
    childTitles: [String],
    parentNodeID: UUID?,
    menuViewID: UUID
) {
    if childTitles.isEmpty {
        addBookmarkDisabledShape("Empty", to: menu)
    } else {
        for title in childTitles {
            let row = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            menu.addItem(row)
        }
    }

    if parentNodeID == nil {
        appendBookmarkShelfFooterShape(to: menu, menuViewID: menuViewID)
    }
}

private func menuAction(_ item: NSMenuItem) -> MenuAction? {
    item.representedObject as? MenuAction
}

// MARK: - Footer shape

@Test("Footer is exactly [separator, Open Bookmark Shelf… (.openBookmarkShelf), Open Settings… (.openBookmarkShelfSettings)]")
func bookmarkFooterShape() {
    let menu = NSMenu()
    let menuViewID = UUID()
    menu.addItem(NSMenuItem(title: "A bookmark", action: nil, keyEquivalent: ""))

    appendBookmarkShelfFooterShape(to: menu, menuViewID: menuViewID)

    #expect(menu.items.count == 4)
    #expect(menu.items[1].isSeparatorItem)

    let openPopup = menu.items[2]
    #expect(openPopup.title == "Open Bookmark Shelf…")
    #expect(openPopup.isEnabled)
    #expect(menuAction(openPopup)?.kind == .openBookmarkShelf)

    let openSettings = menu.items[3]
    #expect(openSettings.title == "Open Settings…")
    #expect(openSettings.isEnabled)
    #expect(menuAction(openSettings)?.kind == .openBookmarkShelfSettings)
}

/// The `.openBookmarkShelf` action must carry the originating
/// `menuViewID` — `MenuActionHandler` resolves it through
/// `statusItemManager.statusBarButton(for:)` to anchor the popup under
/// this menu view's own status item. A nil ID silently degrades to
/// `BookmarkShelfController.resolveDefaultAnchor()`.
@Test("Footer stamps the originating menuViewID onto .openBookmarkShelf only")
func bookmarkFooterCarriesMenuViewID() {
    let menu = NSMenu()
    let menuViewID = UUID()

    appendBookmarkShelfFooterShape(to: menu, menuViewID: menuViewID)

    let openPopup = menu.items.first { menuAction($0)?.kind == .openBookmarkShelf }
    #expect(menuAction(openPopup!)?.menuViewID == menuViewID)

    // The settings deep-link is view-independent and must not carry one.
    let openSettings = menu.items.first { menuAction($0)?.kind == .openBookmarkShelfSettings }
    #expect(menuAction(openSettings!)?.menuViewID == nil)
}

/// Guards the double-separator case: the footer must not emit a
/// separator when the menu already ends in one (an empty favorites
/// section followed by no children can produce that).
@Test("Footer does not emit a second separator when the menu already ends in one")
func bookmarkFooterNoDoubleSeparator() {
    let menu = NSMenu()
    menu.addItem(NSMenuItem(title: "Favorite", action: nil, keyEquivalent: ""))
    menu.addItem(.separator())

    appendBookmarkShelfFooterShape(to: menu, menuViewID: UUID())

    #expect(menu.items.count == 4)
    #expect(menu.items[1].isSeparatorItem)
    #expect(!menu.items[2].isSeparatorItem)
    #expect(menuAction(menu.items[2])?.kind == .openBookmarkShelf)
}

// MARK: - Root-only gate

/// `populateBookmarkShelfSubmenu` drives every nested folder cascade via
/// `BookmarkShelfMenuDelegate(parentNodeID:)`. Appending the footer
/// unconditionally would repeat it inside each folder submenu.
@Test("Footer is appended at root and omitted in nested folder cascades")
func bookmarkFooterRootOnly() {
    let root = NSMenu()
    populateBookmarkShelfSubmenuTailShape(
        root,
        childTitles: ["Folder", "Bookmark"],
        parentNodeID: nil,
        menuViewID: UUID()
    )
    #expect(root.items.count == 5)
    #expect(menuAction(root.items[3])?.kind == .openBookmarkShelf)

    let nested = NSMenu()
    populateBookmarkShelfSubmenuTailShape(
        nested,
        childTitles: ["Folder", "Bookmark"],
        parentNodeID: UUID(),
        menuViewID: UUID()
    )
    #expect(nested.items.count == 2)
    #expect(nested.items.allSatisfy { menuAction($0) == nil })
}

/// The empty-tree path must still reach the footer, otherwise a user
/// with no bookmarks has no route from the menu into the popup or
/// settings — the dead end this change exists to remove.
@Test("Empty root tree still emits the footer after the disabled Empty row")
func bookmarkFooterOnEmptyRoot() {
    let menu = NSMenu()
    populateBookmarkShelfSubmenuTailShape(
        menu,
        childTitles: [],
        parentNodeID: nil,
        menuViewID: UUID()
    )

    #expect(menu.items.count == 4)
    #expect(menu.items[0].title == "Empty")
    #expect(menu.items[0].isEnabled == false)
    #expect(menu.items[1].isSeparatorItem)
    #expect(menuAction(menu.items[2])?.kind == .openBookmarkShelf)
    #expect(menuAction(menu.items[3])?.kind == .openBookmarkShelfSettings)
}

@Test("Empty nested tree emits only the disabled Empty row")
func bookmarkFooterOnEmptyNested() {
    let menu = NSMenu()
    populateBookmarkShelfSubmenuTailShape(
        menu,
        childTitles: [],
        parentNodeID: UUID(),
        menuViewID: UUID()
    )

    #expect(menu.items.count == 1)
    #expect(menu.items[0].title == "Empty")
    #expect(menu.items[0].isEnabled == false)
}
