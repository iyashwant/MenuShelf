//
//  BookmarkShelfShortcutNames.swift
//  MenuShelf
//
//  Vendored `KeyboardShortcuts.Name` registration for the Bookmark Shelf
//  popup global hotkey. Lives next to the controller so the controller
//  can register/unregister callbacks without reaching into the Clipboard
//  Shelf vendor extensions.
//

import KeyboardShortcuts

extension KeyboardShortcuts.Name {
    /// Global keyboard shortcut that toggles the Bookmark Shelf popup.
    /// No default chord — users must opt in by recording one in
    /// `BookmarkShelfSettingsView`.
    static let bookmarkShelfPopup = Self("bookmarkShelfPopup")
}
