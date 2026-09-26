//
//  BrowserFlipPreferencesStore.swift
//  MenuShelf
//
//  Browser Flip persistence and discovery operations on PreferencesStore.
//  The two @Published stored properties (`discoveredBrowsers`,
//  `currentDefaultBrowserID`) must remain on the class itself; everything
//  else lives here.
//

import Foundation

extension PreferencesStore {
    /// Append a Browser Flip menu item to the target menu view (creating one
    /// if needed). Skips when the view already has a browser flip item, since
    /// duplicates have no use.
    func addBrowserFlipItem(toMenuViewID menuViewID: UUID?) {
        var views = settings.resolvedMenuViews
        let targetID: UUID

        if let menuViewID, views.contains(where: { $0.id == menuViewID }) {
            targetID = menuViewID
        } else {
            let view = MenuViewConfig.make(title: "MenuShelf", defaults: settings.defaultMenuSettings)
            views.append(view)
            targetID = view.id
            selectedMenuViewID = targetID
        }

        guard let index = views.firstIndex(where: { $0.id == targetID }) else { return }
        guard views[index].browserFlipItem == nil else {
            settings.menuViews = views
            return
        }

        views[index].browserFlipItem = BrowserFlipMenuItemConfig.make()
        views[index].updatedAt = Date()
        settings.menuViews = views
        selectedMenuViewID = targetID

        if !settings.resolvedBrowserFlip.enableBrowserFlip {
            // Auto-enable Browser Flip so the menu actually populates when opened.
            setEnableBrowserFlip(true)
        } else {
            refreshBrowsers()
        }
    }

    func refreshBrowsers() {
        Task.detached(priority: .userInitiated) {
            let newBrowsers = DefaultBrowserService.shared.discoverBrowsers()
            await MainActor.run {
                self.applyBrowserDiscovery(newBrowsers: newBrowsers)
            }
        }
    }

    private func applyBrowserDiscovery(newBrowsers: [BrowserInfo]) {
        let savedBrowsers = settings.resolvedBrowserFlip.savedBrowsers

        var merged: [BrowserInfo] = []
        var usedIDs = Set<String>()

        for saved in savedBrowsers {
            if let discovered = newBrowsers.first(where: { $0.id == saved.id }) {
                var browser = discovered
                browser.isVisible = saved.isVisible
                browser.sortOrder = saved.sortOrder
                merged.append(browser)
                usedIDs.insert(browser.id)
            }
        }

        for discovered in newBrowsers where !usedIDs.contains(discovered.id) {
            var browser = discovered
            browser.sortOrder = merged.count
            merged.append(browser)
        }

        discoveredBrowsers = merged
        updateBrowserFlipSettings { $0.savedBrowsers = merged }
        currentDefaultBrowserID = DefaultBrowserService.shared.currentDefaultBrowserID()
        reconcileQuickKeys()
    }

    func updateBrowserFlipSettings(_ update: (inout BrowserFlipSettings) -> Void) {
        var flip = settings.resolvedBrowserFlip
        update(&flip)
        settings.browserFlip = flip
    }

    func setBrowserVisible(_ browser: BrowserInfo, visible: Bool) {
        if let index = discoveredBrowsers.firstIndex(where: { $0.id == browser.id }) {
            discoveredBrowsers[index].isVisible = visible
            updateBrowserFlipSettings { $0.savedBrowsers = discoveredBrowsers }
            reconcileQuickKeys()
        }
    }

    func resetHiddenBrowsers() {
        for index in discoveredBrowsers.indices {
            discoveredBrowsers[index].isVisible = true
        }
        updateBrowserFlipSettings { $0.savedBrowsers = discoveredBrowsers }
        reconcileQuickKeys()
    }

    func moveBrowser(from source: IndexSet, to destination: Int) {
        discoveredBrowsers.move(fromOffsets: source, toOffset: destination)
        for (index, _) in discoveredBrowsers.enumerated() {
            discoveredBrowsers[index].sortOrder = index
        }
        updateBrowserFlipSettings { $0.savedBrowsers = discoveredBrowsers }
        reconcileQuickKeys()
    }

    /// Explicitly pins `letter` as the browser's "Ask Everytime" quick key,
    /// or clears the pin (falling back to auto-assignment) when nil.
    func setBrowserShortcut(_ browser: BrowserInfo, letter: Character?) {
        MenuShelfPickerOpener.setManualShortcut(
            bundleID: browser.id,
            letter: letter,
            visibleBrowsers: visibleOrderedBrowserURLs()
        )
    }

    /// The browser list the "Ask Everytime" picker shows: only visible
    /// browsers, in the user's configured order, with the synthetic "Ask
    /// Everytime" entry excluded. Mirrors `MenuShelfPickerController`.
    func visibleOrderedBrowserURLs() -> [URL] {
        discoveredBrowsers
            .filter { $0.isVisible }
            .filter { !MenuBuilder.isAskEverytime($0) }
            .sorted { $0.sortOrder < $1.sortOrder }
            .map { $0.appURL }
    }

    /// Releases quick keys held by now-hidden/removed browsers and lets any
    /// still-visible browser reclaim a freed letter. Called after every
    /// visibility, order, or discovery change so the picker's badges never
    /// drift from what Browser Flip settings currently show.
    private func reconcileQuickKeys() {
        MenuShelfPickerOpener.ensureShortcutsAssigned(for: visibleOrderedBrowserURLs())
    }

    func setEnableBrowserFlip(_ enabled: Bool) {
        updateBrowserFlipSettings { $0.enableBrowserFlip = enabled }
        if enabled {
            refreshBrowsers()
        }
    }
}
