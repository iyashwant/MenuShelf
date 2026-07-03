//
//  ClipboardShelfMenu.swift
//  MenuShelf
//
//  Action target for inline Clipboard Shelf submenu rows. A single shared
//  instance is retained for the app lifetime so it stays alive as the menu's
//  target while the menu is tracking.
//

import AppKit
import Defaults
import Foundation

@MainActor
final class ClipboardShelfMenu: NSObject {
    static let shared = ClipboardShelfMenu()

    private override init() { super.init() }

    @objc func handleSelectItem(_ sender: NSMenuItem) {
        guard let item = sender.representedObject as? HistoryItem else { return }

        let modifierFlags = NSApp.currentEvent?.modifierFlags
            .intersection(.deviceIndependentFlagsMask)
            .subtracting([.capsLock, .numericPad, .function]) ?? []

        let delayMs = AppContainer.shared.store.settings.resolvedClipboardShelf.pasteDelayMs
        let delaySeconds = TimeInterval(delayMs) / 1000.0

        DispatchQueue.main.asyncAfter(deadline: .now() + delaySeconds) { [item, modifierFlags] in
            self.activate(item: item, modifierFlags: modifierFlags)
        }
    }

    private func activate(item: HistoryItem, modifierFlags: NSEvent.ModifierFlags) {
        if modifierFlags.isEmpty {
            Clipboard.shared.copy(item, removeFormatting: Defaults[.removeFormattingByDefault])
            if Defaults[.pasteByDefault] {
                Clipboard.shared.paste()
            }
        } else {
            switch HistoryItemAction(modifierFlags) {
            case .copy:
                Clipboard.shared.copy(item)
            case .paste:
                Clipboard.shared.copy(item)
                Clipboard.shared.paste()
            case .pasteWithoutFormatting:
                Clipboard.shared.copy(item, removeFormatting: true)
                Clipboard.shared.paste()
            case .unknown:
                return
            }
        }
    }
}
