//
//  BookmarkShelfExampleTests.swift
//  ClockShelfTests
//
//  Example-based tests for deterministic configuration and UI/wiring
//  facts in the Bookmark Shelf spec. Each `@Test` covers one criterion
//  the product MUST not regress. Property-based coverage lives in the
//  optional `BookmarkShelfPropertyTests.swift` companion (tasks 18.*);
//  this file is required because it pins values the rest of the
//  feature relies on.
//

import Foundation
import KeyboardShortcuts
import Testing
@testable import MenuShelf

// MARK: - ModuleKind

@Test("ModuleKind.allCases declared in order [.browserFlip, .clipboardShelf, .clockShelf, .bookmarkShelf]")
func moduleKindAllCasesOrder() {
    #expect(ModuleKind.allCases == [.browserFlip, .clipboardShelf, .clockShelf, .bookmarkShelf])
}

@Test("ModuleKind.bookmarkShelf default symbol/title/bondLabel")
func moduleKindBookmarkShelfDisplay() {
    #expect(ModuleKind.bookmarkShelf.defaultIconSymbol == "bookmark")
    #expect(ModuleKind.bookmarkShelf.defaultTitle == "Bookmark Shelf")
    #expect(ModuleKind.bookmarkShelf.bondLabel == "This icon opens Bookmark Shelf")
}

// MARK: - BookmarkShelfSettings.defaults

@Test("BookmarkShelfSettings.defaults exact field values")
func bookmarkShelfSettingsDefaults() {
    let defaults = BookmarkShelfSettings.defaults
    #expect(defaults.enableBookmarkShelf == false)
    #expect(defaults.popupSize == CGSize(width: 320, height: 420))
    #expect(defaults.popupHotkey == .disabled)
    #expect(defaults.defaultBrowserBundleID == nil)
    #expect(defaults.showFavoritesSection == true)
    #expect(defaults.confirmBeforeDelete == true)
    #expect(defaults.lastImportSourceLabel == nil)
}

// MARK: - AppSettings.defaults

@Test("AppSettings.defaults.schemaVersion == 16")
func appSettingsSchemaVersion16() {
    #expect(AppSettings.defaults.schemaVersion == 16)
}

@Test("AppSettings.defaults.bookmarkShelf == BookmarkShelfSettings.defaults")
func appSettingsDefaultsBookmarkShelf() {
    #expect(AppSettings.defaults.bookmarkShelf == BookmarkShelfSettings.defaults)
    #expect(AppSettings.defaults.resolvedBookmarkShelf == BookmarkShelfSettings.defaults)
}

// MARK: - BookmarkShelfMenuItemConfig

@Test("BookmarkShelfMenuItemConfig.make().displayTitle == \"Bookmark Shelf\"")
func bookmarkShelfMenuItemDisplayTitleFallback() {
    let item = BookmarkShelfMenuItemConfig.make()
    #expect(item.titleOverride == nil)
    #expect(item.displayTitle == "Bookmark Shelf")
}

@Test("BookmarkShelfMenuItemConfig.displayTitle returns trimmed override")
func bookmarkShelfMenuItemDisplayTitleTrimmed() {
    var item = BookmarkShelfMenuItemConfig.make()
    item.titleOverride = "  My Bookmarks  "
    #expect(item.displayTitle == "My Bookmarks")
}

@Test("BookmarkShelfMenuItemConfig.displayTitle falls back when whitespace-only")
func bookmarkShelfMenuItemDisplayTitleFallbackWhitespace() {
    var item = BookmarkShelfMenuItemConfig.make()
    item.titleOverride = "   "
    #expect(item.displayTitle == "Bookmark Shelf")
}

// MARK: - BookmarkContentItemConfig

@Test("BookmarkContentItemConfig.make(nodeID:).resolvedTitle(node: nil) == \"Bookmark unavailable\"")
func bookmarkContentItemMissingNodePlaceholder() {
    let id = UUID()
    let config = BookmarkContentItemConfig.make(nodeID: id)
    #expect(config.nodeID == id)
    #expect(config.resolvedTitle(node: nil) == "Bookmark unavailable")
}

@Test("BookmarkContentItemConfig.resolvedTitle prefers trimmed titleOverride")
func bookmarkContentItemTitleOverride() {
    var config = BookmarkContentItemConfig.make(nodeID: UUID())
    config.titleOverride = "  Custom  "
    #expect(config.resolvedTitle(node: nil) == "Custom")
}

@Test("BookmarkContentItemConfig.resolvedTitle returns node.title when override empty")
func bookmarkContentItemTitleFromNode() {
    let bookmark = BookmarkNode.makeBookmark(
        parentID: nil,
        title: "Hello",
        url: "https://example.com",
        isFavorite: false,
        sortOrder: 0
    )
    let config = BookmarkContentItemConfig.make(nodeID: bookmark.id)
    #expect(config.resolvedTitle(node: bookmark) == "Hello")
}

@Test("BookmarkContentItemConfig.resolvedIcon picks folder symbol for missing node")
func bookmarkContentItemMissingIcon() {
    let config = BookmarkContentItemConfig.make(nodeID: UUID())
    let icon = config.resolvedIcon(node: nil)
    if case .systemSymbol(let name, _) = icon {
        #expect(name == "questionmark.circle")
    } else {
        Issue.record("Expected systemSymbol icon for missing node")
    }
}

// MARK: - BookmarkNodeKind

@Test("BookmarkNodeKind.allCases declared in order [.bookmark, .folder]")
func bookmarkNodeKindAllCasesOrder() {
    #expect(BookmarkNodeKind.allCases == [.bookmark, .folder])
}

// MARK: - MenuViewConfig

@Test("MenuViewConfig.make() has nil bookmarkShelfItem and bookmarkContentItems")
func menuViewMakeBookmarkFieldsNil() {
    let view = MenuViewConfig.make()
    #expect(view.bookmarkShelfItem == nil)
    #expect(view.bookmarkContentItems == nil)
    #expect(view.resolvedBookmarkContentItems.isEmpty)
}

// MARK: - KeyboardShortcuts.Name

@Test("KeyboardShortcuts.Name.bookmarkShelfPopup raw name == \"bookmarkShelfPopup\"")
func bookmarkShelfPopupShortcutName() {
    #expect(KeyboardShortcuts.Name.bookmarkShelfPopup.rawValue == "bookmarkShelfPopup")
}

// MARK: - SettingsWindowController focusBookmarkShelf

@Test("SettingsWindowController.show(focusBookmarkShelf: true) posts menuShelfFocusBookmarkShelf exactly once")
@MainActor
func settingsWindowFocusBookmarkShelfPostsNotificationOnce() async {
    var receivedCount = 0
    let token = NotificationCenter.default.addObserver(
        forName: .menuShelfFocusBookmarkShelf,
        object: nil,
        queue: .main
    ) { _ in
        receivedCount += 1
    }
    defer { NotificationCenter.default.removeObserver(token) }

    AppContainer.shared.settingsWindowController.show(focusBookmarkShelf: true)
    // Allow the main runloop to deliver the posted notification.
    try? await Task.sleep(nanoseconds: 50_000_000)

    #expect(receivedCount == 1)
}
