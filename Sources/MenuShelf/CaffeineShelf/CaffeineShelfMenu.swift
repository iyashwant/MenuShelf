//
//  CaffeineShelfMenu.swift
//  MenuShelf
//
//  Builds the left-click NSMenu for a standalone CaffeineShelf status item and
//  hosts the AppKit target/action methods the menu rows invoke. The popup is
//  presented through the same temporary menu-swap trick Browser Flip uses
//  (`presentBrowserFlipStandalonePopup`), so no extra floating window is
//  introduced.
//

import AppKit
import Foundation

/// Menu builder + action target for the standalone CaffeineShelf popup. A
/// single shared instance is retained for the app lifetime so it stays alive
/// as the menu's target while the menu is tracking.
@MainActor
final class CaffeineShelfMenu: NSObject {
    static let shared = CaffeineShelfMenu()

    private override init() { super.init() }

    /// Build a fresh menu reflecting the current awake state as a radio list:
    /// an "Off" row plus the fixed duration list, with the active choice
    /// checked, then Settings. "Off" is checked by default at launch because
    /// the module starts inactive — this is the awake-state off switch, which
    /// is distinct from the "Enable CaffeineShelf" feature toggle in Settings.
    func makeMenu() -> NSMenu {
        let menu = NSMenu(title: "Caffeine Shelf")
        populate(menu)
        return menu
    }

    /// Rebuild `menu` in place so a lazy `NSMenuDelegate` can refresh the
    /// duration list every time the submenu opens.
    func populate(_ menu: NSMenu) {
        menu.removeAllItems()
        menu.autoenablesItems = false

        let controller = CaffeineShelfController.shared

        // Status line for timed sessions ("Awake until 3:45 PM"). The checkmark
        // already conveys an indefinite session, so this is shown only when a
        // session has an expiry.
        if controller.isActive, controller.fireDate != nil,
           let status = controller.menuStatusDescription {
            let info = NSMenuItem(title: status, action: nil, keyEquivalent: "")
            info.isEnabled = false
            menu.addItem(info)
            menu.addItem(.separator())
        }

        // "Off" — checked whenever the Mac is not being kept awake (the launch
        // default), and the action that ends an active session.
        let off = NSMenuItem(title: "Off", action: #selector(handleTurnOff(_:)), keyEquivalent: "")
        off.target = self
        off.state = controller.isActive ? .off : .on
        menu.addItem(off)

        menu.addItem(.separator())

        // Duration radio list — the active duration is checked.
        for option in CaffeineShelfDurationOption.all {
            let item = NSMenuItem(
                title: option.menuLabel,
                action: #selector(handleSelectDuration(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = option.seconds
            if controller.isActive, controller.activeDurationSeconds == option.seconds {
                item.state = .on
            }
            menu.addItem(item)
        }

        // "Custom" — fine-grained durations grouped into Minutes / Hours
        // submenus. Checked when the active duration isn't one of the fixed
        // rows above, so the user can see the selection lives in here.
        let custom = NSMenuItem(title: "Custom", action: nil, keyEquivalent: "")
        let customMenu = NSMenu(title: "Custom")
        customMenu.autoenablesItems = false

        let minutes = NSMenuItem(title: "Minutes", action: nil, keyEquivalent: "")
        minutes.submenu = makeDurationSubmenu(
            CaffeineShelfDurationOption.customMinutes,
            controller: controller
        )
        customMenu.addItem(minutes)

        let hours = NSMenuItem(title: "Hours", action: nil, keyEquivalent: "")
        hours.submenu = makeDurationSubmenu(
            CaffeineShelfDurationOption.customHours,
            controller: controller
        )
        customMenu.addItem(hours)

        custom.submenu = customMenu
        if controller.isActive,
           let active = controller.activeDurationSeconds,
           !CaffeineShelfDurationOption.all.contains(where: { $0.seconds == active }) {
            custom.state = .on
        }
        menu.addItem(custom)

        menu.addItem(.separator())

        // "Keep Awake With Lid Closed" — a mode modifier (not part of the radio
        // list). Toggling it on the first time triggers a one-time admin prompt.
        let lid = NSMenuItem(
            title: "Keep Awake With Lid Closed",
            action: #selector(handleToggleLidClosed(_:)),
            keyEquivalent: ""
        )
        lid.target = self
        lid.state = controller.lidClosedModeEnabled ? .on : .off
        menu.addItem(lid)

        menu.addItem(.separator())

        let settings = NSMenuItem(
            title: "Caffeine Shelf Settings…",
            action: #selector(handleOpenSettings(_:)),
            keyEquivalent: ""
        )
        settings.target = self
        menu.addItem(settings)
    }

    /// Build a flat submenu of plain duration rows (e.g. "20 minutes"), each
    /// targeting `handleSelectDuration` and checked when it's the active one.
    private func makeDurationSubmenu(
        _ options: [CaffeineShelfDurationOption],
        controller: CaffeineShelfController
    ) -> NSMenu {
        let submenu = NSMenu()
        submenu.autoenablesItems = false
        for option in options {
            let item = NSMenuItem(
                title: option.shortLabel,
                action: #selector(handleSelectDuration(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = option.seconds
            if controller.isActive, controller.activeDurationSeconds == option.seconds {
                item.state = .on
            }
            submenu.addItem(item)
        }
        return submenu
    }

    @objc private func handleTurnOff(_ sender: NSMenuItem) {
        CaffeineShelfController.shared.deactivate()
    }

    @objc private func handleToggleLidClosed(_ sender: NSMenuItem) {
        let controller = CaffeineShelfController.shared
        controller.setLidClosedMode(!controller.lidClosedModeEnabled)
    }

    @objc private func handleSelectDuration(_ sender: NSMenuItem) {
        let seconds = (sender.representedObject as? TimeInterval) ?? 0
        // Picking a duration always (re)starts the session for that length.
        CaffeineShelfController.shared.activate(durationSeconds: seconds)
    }

    @objc private func handleOpenSettings(_ sender: NSMenuItem) {
        AppContainer.shared.settingsWindowController.show(focusCaffeineShelf: true)
    }
}

// MARK: - CaffeineShelfMenuDelegate

/// Lazy-populates an inline CaffeineShelf submenu when it is about to open so
/// duration checkmarks and the awake status line reflect the latest state.
final class CaffeineShelfMenuDelegate: NSObject, NSMenuDelegate {
    weak var builder: MenuBuilder?

    init(builder: MenuBuilder) {
        self.builder = builder
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        builder?.populateCaffeineShelfSubmenu(menu)
    }
}

extension MenuPresentationCoordinator {
    /// Present the standalone CaffeineShelf popup anchored at the given status
    /// item. Mirrors `presentBrowserFlipStandalonePopup(anchoredTo:)`: stash the
    /// button's click handler and `statusItem.menu`, install the popup menu,
    /// synthesize a synchronous click, then restore. `performClick(nil)` is
    /// synchronous so the handler is restored before the next user click lands.
    @MainActor
    func presentCaffeineShelfStandalonePopup(anchoredTo statusItem: NSStatusItem) {
        guard let button = statusItem.button else { return }

        let menu = CaffeineShelfMenu.shared.makeMenu()

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
