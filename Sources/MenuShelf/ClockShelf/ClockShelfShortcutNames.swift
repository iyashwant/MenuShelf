//
//  WorldClockShortcutNames.swift
//  MenuShelf
//
//  Vendored `KeyboardShortcuts.Name` registration for the World Clock
//  popup global hotkey. Lives next to the controller so the controller
//  can register/unregister callbacks without reaching into the Clipboard
//  Shelf vendor extensions.
//

import KeyboardShortcuts

extension KeyboardShortcuts.Name {
    /// Global keyboard shortcut that toggles the World Clock popover.
    /// No default chord — users must opt in by recording one in
    /// `WorldClockSettingsView`.
    static let worldClockPopup = Self("worldClockPopup")
}
