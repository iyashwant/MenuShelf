//
//  ClockShelfShortcutNames.swift
//  MenuShelf
//
//  Vendored `KeyboardShortcuts.Name` registration for the Clock Shelf
//  popup global hotkey. Lives next to the controller so the controller
//  can register/unregister callbacks without reaching into the Clipboard
//  Shelf vendor extensions.
//

import KeyboardShortcuts

extension KeyboardShortcuts.Name {
    /// Global keyboard shortcut that toggles the Clock Shelf popover.
    /// No default chord — users must opt in by recording one in
    /// `ClockShelfSettingsView`.
    static let clockShelfPopup = Self("clockShelfPopup")
}
