//
//  BrowserFlipMenuBuilder.swift
//  MenuShelf
//
//  Browser Flip menu construction. Isolated from MenuBuilder so the rest of
//  the menu code can stay free of browser-specific concerns. Includes the
//  "Default Browser" submenu (with "Ask Everytime") and the inline menu view
//  item that surfaces the same submenu directly inside a view.
//

import AppKit

final class BrowserFlipMenuDelegate: NSObject, NSMenuDelegate {
    weak var builder: MenuBuilder?

    init(builder: MenuBuilder) {
        self.builder = builder
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        builder?.populateBrowserFlipMenu(menu)
    }

    func menuWillOpen(_ menu: NSMenu) {
        builder?.store.refreshBrowsers()
    }
}

extension MenuBuilder {
    /// "..." → "Default Browser" submenu used in the management menu.
    func browserFlipMenuItem() -> NSMenuItem {
        let item = NSMenuItem(title: "Default Browser", action: nil, keyEquivalent: "")
        let submenu = NSMenu(title: "Default Browser")
        submenu.autoenablesItems = false
        let delegate = BrowserFlipMenuDelegate(builder: self)
        submenu.delegate = delegate
        MenuDelegateRetainer.shared.retain(delegate, for: submenu)
        item.submenu = submenu
        return item
    }

    /// Lazy populate path used by `BrowserFlipMenuDelegate`.
    func populateBrowserFlipMenu(_ menu: NSMenu) {
        menu.removeAllItems()
        menu.autoenablesItems = false

        store.currentDefaultBrowserID = DefaultBrowserService.shared.currentDefaultBrowserID()

        let visibleBrowsers = store.discoveredBrowsers
            .filter { $0.isVisible }
            .sorted { $0.sortOrder < $1.sortOrder }

        // "Ask Everytime" is MenuShelf itself acting as the default browser.
        // Selecting it sets MenuShelf's own bundle ID as the default http(s)
        // handler — link clicks then trigger MenuShelfPickerController. This
        // is independent of Browser Flip.app being installed; the picker
        // code lives inside MenuShelf.
        let askEverytime = MenuBuilder.askEverytimeBrowser()
        let askItem = actionItem(
            "Ask Everytime",
            kind: .switchBrowser,
            browserInfo: askEverytime
        )
        askItem.keyEquivalent = "0"
        let askIcon = NSWorkspace.shared.icon(forFile: askEverytime.appURL.path)
        askIcon.size = NSSize(width: 16, height: 16)
        askItem.image = askIcon
        askItem.state = (askEverytime.id == store.currentDefaultBrowserID) ? NSControl.StateValue.on : .off
        menu.addItem(askItem)

        let nonSelfVisible = visibleBrowsers.filter { $0.id != askEverytime.id }

        if !nonSelfVisible.isEmpty {
            menu.addItem(.separator())
            for (index, browser) in nonSelfVisible.prefix(9).enumerated() {
                let browserItem = actionItem(
                    browser.name,
                    kind: .switchBrowser,
                    browserInfo: browser
                )
                browserItem.keyEquivalent = String(index + 1)
                let icon = NSWorkspace.shared.icon(forFile: browser.appURL.path)
                icon.size = NSSize(width: 16, height: 16)
                browserItem.image = icon
                browserItem.state = (browser.id == store.currentDefaultBrowserID) ? NSControl.StateValue.on : .off
                menu.addItem(browserItem)
            }
        }

        menu.addItem(.separator())
        menu.addItem(actionItem("Refresh Browsers", kind: .openBrowserFlipSettings))
    }

    /// Returns a synthetic BrowserInfo for MenuShelf itself. Selecting this
    /// from the menu sets MenuShelf as the default http(s) handler, which
    /// triggers MenuShelfPickerController on every link click.
    static func askEverytimeBrowser() -> BrowserInfo {
        let bundleID = Bundle.main.bundleIdentifier ?? "app.menushelf.MenuShelf2"
        let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
            ?? Bundle.main.bundleURL
        return BrowserInfo(id: bundleID, name: "Ask Everytime", appURL: appURL)
    }

    /// Whether the given browser is MenuShelf itself in "Ask Everytime" mode.
    static func isAskEverytime(_ browser: BrowserInfo) -> Bool {
        return browser.id == (Bundle.main.bundleIdentifier ?? "app.menushelf.MenuShelf2")
    }

    /// Inline menu view item that surfaces the same Default Browser submenu
    /// directly inside a menu view (instead of only via "..." → Default Browser).
    func addBrowserFlipMenuItem(_ config: BrowserFlipMenuItemConfig, to menu: NSMenu, currentSection: inout String?) {
        let trimmedSection = config.sectionName?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let section = trimmedSection, !section.isEmpty, section != currentSection {
            if currentSection != nil || menu.items.last?.isSeparatorItem == false {
                menu.addItem(.separator())
            }
            addDisabled(section, to: menu)
            currentSection = section
        }

        let item = NSMenuItem(title: config.displayTitle, action: nil, keyEquivalent: "")
        item.image = NSImage(systemSymbolName: "globe", accessibilityDescription: nil)
        let submenu = NSMenu(title: config.displayTitle)
        submenu.autoenablesItems = false
        let delegate = BrowserFlipMenuDelegate(builder: self)
        submenu.delegate = delegate
        MenuDelegateRetainer.shared.retain(delegate, for: submenu)
        item.submenu = submenu
        menu.addItem(item)
    }
}
