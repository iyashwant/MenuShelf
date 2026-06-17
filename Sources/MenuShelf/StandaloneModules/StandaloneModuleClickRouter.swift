import AppKit
import Foundation

@MainActor
final class StandaloneModuleClickRouter {
    static let shared = StandaloneModuleClickRouter()

    private init() {}

    /// Dispatch a status-item click for a standalone module.
    ///
    /// The matrix is exhaustive over the documented input space and the
    /// branches are disjoint, evaluated top-down:
    ///   - Branch A: right-click → open the bound module's settings pane.
    ///   - Branch B: option + left-click → open the bound module's
    ///     settings pane.
    ///   - Branch C: bound feature disabled → focus the feature's
    ///     settings pane.
    ///   - Branch D: otherwise → dispatch to the bound module's surface.
    func dispatch(
        module: StandaloneModuleConfig,
        anchorButton: NSStatusBarButton?,
        anchorItem: NSStatusItem?,
        eventType: NSEvent.EventType,
        modifierFlags: NSEvent.ModifierFlags,
        presentationCoordinator: MenuPresentationCoordinator
    ) {
        // Branch A: right-click opens the bound module's settings pane
        // (Requirement 6.4).
        if eventType == .rightMouseUp {
            openSettingsDeepLink(module: module)
            return
        }

        // Branch B: option + left-click opens the bound module's
        // settings pane (Requirement 6.5).
        if eventType == .leftMouseUp && modifierFlags.contains(.option) {
            openSettingsDeepLink(module: module)
            return
        }

        let settings = AppContainer.shared.store.settings

        // Branch C: when the bound feature is disabled, jump to that
        // feature's settings pane instead of presenting an empty
        // surface (Requirements 6.8, 6.9, 6.10, 10.2, 10.3).
        switch module.kind {
        case .clipboardShelf:
            if !settings.resolvedClipboardShelf.enableClipboardShelf {
                DiagnosticsLogger.shared.log(
                    "Standalone module click ignored — feature disabled. id=\(module.id.uuidString) kind=\(module.kind.rawValue)"
                )
                AppContainer.shared.settingsWindowController.show(
                    focusClipboardShelf: true
                )
                return
            }
        case .clockShelf:
            if !settings.resolvedClockShelf.enableClockShelf {
                DiagnosticsLogger.shared.log(
                    "Standalone module click ignored — feature disabled. id=\(module.id.uuidString) kind=\(module.kind.rawValue)"
                )
                AppContainer.shared.settingsWindowController.show(
                    focusClockShelf: true
                )
                return
            }
        case .browserFlip:
            if !settings.resolvedBrowserFlip.enableBrowserFlip {
                DiagnosticsLogger.shared.log(
                    "Standalone module click ignored — feature disabled. id=\(module.id.uuidString) kind=\(module.kind.rawValue)"
                )
                AppContainer.shared.settingsWindowController.show(
                    focusBrowserFlip: true
                )
                return
            }
        case .bookmarkShelf:
            if !settings.resolvedBookmarkShelf.enableBookmarkShelf {
                DiagnosticsLogger.shared.log(
                    "Standalone module click ignored — feature disabled. id=\(module.id.uuidString) kind=\(module.kind.rawValue)"
                )
                AppContainer.shared.settingsWindowController.show(
                    focusBookmarkShelf: true
                )
                return
            }
        case .caffeineShelf:
            if !settings.resolvedCaffeineShelf.enableCaffeineShelf {
                DiagnosticsLogger.shared.log(
                    "Standalone module click ignored — feature disabled. id=\(module.id.uuidString) kind=\(module.kind.rawValue)"
                )
                AppContainer.shared.settingsWindowController.show(
                    focusCaffeineShelf: true
                )
                return
            }
        }

        // Branch D: dispatch to the bound module's surface
        // (Requirements 6.1, 6.2, 6.3).
        switch module.kind {
        case .clipboardShelf:
            ClipboardShelfController.shared.togglePopup(anchor: anchorButton)
        case .clockShelf:
            ClockShelfController.shared.togglePopover(anchor: anchorButton)
        case .browserFlip:
            guard let anchorItem else { return }
            presentationCoordinator.presentBrowserFlipStandalonePopup(anchoredTo: anchorItem)
        case .bookmarkShelf:
            BookmarkShelfController.shared.togglePopup(anchor: anchorButton)
        case .caffeineShelf:
            guard let anchorItem else { return }
            presentationCoordinator.presentCaffeineShelfStandalonePopup(anchoredTo: anchorItem)
        }
    }

    /// Dispatch a hotkey trigger for a standalone module.
    ///
    /// Mirrors Branches C and D from `dispatch(...)`. Modifier flags are
    /// not consulted because the trigger is a Carbon hotkey, so Branches
    /// A and B (right-click, option + left-click) do not apply.
    func dispatchHotkey(
        module: StandaloneModuleConfig,
        anchorButton: NSStatusBarButton?,
        anchorItem: NSStatusItem?,
        presentationCoordinator: MenuPresentationCoordinator
    ) {
        let settings = AppContainer.shared.store.settings

        // Branch C (mirror): when the bound feature is disabled, jump
        // to that feature's settings pane instead of presenting an
        // empty surface (Requirements 10.2, 10.3).
        switch module.kind {
        case .clipboardShelf:
            if !settings.resolvedClipboardShelf.enableClipboardShelf {
                DiagnosticsLogger.shared.log(
                    "Standalone module hotkey ignored — feature disabled. id=\(module.id.uuidString) kind=\(module.kind.rawValue)"
                )
                AppContainer.shared.settingsWindowController.show(
                    focusClipboardShelf: true
                )
                return
            }
        case .clockShelf:
            if !settings.resolvedClockShelf.enableClockShelf {
                DiagnosticsLogger.shared.log(
                    "Standalone module hotkey ignored — feature disabled. id=\(module.id.uuidString) kind=\(module.kind.rawValue)"
                )
                AppContainer.shared.settingsWindowController.show(
                    focusClockShelf: true
                )
                return
            }
        case .browserFlip:
            if !settings.resolvedBrowserFlip.enableBrowserFlip {
                DiagnosticsLogger.shared.log(
                    "Standalone module hotkey ignored — feature disabled. id=\(module.id.uuidString) kind=\(module.kind.rawValue)"
                )
                AppContainer.shared.settingsWindowController.show(
                    focusBrowserFlip: true
                )
                return
            }
        case .bookmarkShelf:
            if !settings.resolvedBookmarkShelf.enableBookmarkShelf {
                DiagnosticsLogger.shared.log(
                    "Standalone module hotkey ignored — feature disabled. id=\(module.id.uuidString) kind=\(module.kind.rawValue)"
                )
                AppContainer.shared.settingsWindowController.show(
                    focusBookmarkShelf: true
                )
                return
            }
        case .caffeineShelf:
            if !settings.resolvedCaffeineShelf.enableCaffeineShelf {
                DiagnosticsLogger.shared.log(
                    "Standalone module hotkey ignored — feature disabled. id=\(module.id.uuidString) kind=\(module.kind.rawValue)"
                )
                AppContainer.shared.settingsWindowController.show(
                    focusCaffeineShelf: true
                )
                return
            }
        }

        // Branch D (mirror): dispatch to the bound module's surface
        // (Requirement 6.6).
        switch module.kind {
        case .clipboardShelf:
            ClipboardShelfController.shared.togglePopup(anchor: anchorButton)
        case .clockShelf:
            ClockShelfController.shared.togglePopover(anchor: anchorButton)
        case .browserFlip:
            // Defensive: the HotkeysSignature gate prevents a hotkey
            // on an invisible module from registering, but the helper
            // still accepts a nil anchor item.
            guard let anchorItem else { return }
            presentationCoordinator.presentBrowserFlipStandalonePopup(anchoredTo: anchorItem)
        case .bookmarkShelf:
            BookmarkShelfController.shared.togglePopup(anchor: anchorButton)
        case .caffeineShelf:
            // A hotkey has no anchor, so toggle awake directly rather than
            // presenting the menu — this turns the per-icon shortcut into a
            // global keep-awake toggle.
            CaffeineShelfController.shared.toggle()
        }
    }

    /// Open Settings deep-linked to the bound module's specific
    /// settings pane (Browser Flip, Clipboard Shelf, or Clock Shelf).
    /// Triggered from a right-click or option + left-click on a
    /// standalone module's status item.
    private func openSettingsDeepLink(module: StandaloneModuleConfig) {
        switch module.kind {
        case .clipboardShelf:
            AppContainer.shared.settingsWindowController.show(
                focusClipboardShelf: true
            )
        case .clockShelf:
            AppContainer.shared.settingsWindowController.show(
                focusClockShelf: true
            )
        case .browserFlip:
            AppContainer.shared.settingsWindowController.show(
                focusBrowserFlip: true
            )
        case .bookmarkShelf:
            AppContainer.shared.settingsWindowController.show(
                focusBookmarkShelf: true
            )
        case .caffeineShelf:
            AppContainer.shared.settingsWindowController.show(
                focusCaffeineShelf: true
            )
        }
    }
}

extension MenuPresentationCoordinator {
    /// Build and present the standalone Browser Flip popup anchored at
    /// the given status item. The popup is the same NSMenu that the
    /// in-menu Default Browser surface uses, so the rows are 1:1.
    func presentBrowserFlipStandalonePopup(anchoredTo statusItem: NSStatusItem) {
        guard let button = statusItem.button else { return }

        // Reuse the existing lifecycle hook from
        // BrowserFlipMenuDelegate.menuWillOpen(_:) to refresh the
        // discovered-browsers list before populating the menu
        // (Requirement 7.4).
        store.refreshBrowsers()

        // Build the popup menu with no wrapping "Browser Flip" header
        // item or other enclosing container (Requirements 7.1, 7.3).
        let menu = NSMenu(title: "Browser Flip")
        menu.autoenablesItems = false
        menuBuilder.populateBrowserFlipMenu(menu)

        // Use the same anchor pattern that
        // MenuPresentationCoordinator.popUp(_:anchoredTo:...) uses for
        // menu-view menus: temporarily clear the button's click handler
        // and statusItem.menu, install our menu, synthesize a click,
        // and restore the saved values immediately afterward.
        // performClick(nil) is synchronous so the click handler is
        // restored before the next user click can land
        // (Requirement 7.5 — no third floating panel).
        let savedTarget = button.target
        let savedAction = button.action
        let savedItemMenu = statusItem.menu

        button.target = nil
        button.action = nil
        statusItem.menu = menu

        button.performClick(nil)

        statusItem.menu = savedItemMenu
        button.target = savedTarget
        button.action = savedAction
    }
}
