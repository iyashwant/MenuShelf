import AppKit
import Foundation

/// A reportable hotkey conflict surfaced inline in the Standalone Modules
/// detail pane. The `ownerName` is human-readable and matches Requirement
/// 8.4 exactly: `"menu view '<title>'"` / `"standalone module '<title>'"`
/// / `"Clipboard Shelf popup"` / `"World Clock popup"`.
struct StandaloneModuleHotkeyConflict: Equatable {
    let ownerName: String

    /// A known popup hotkey owner (Clipboard Shelf, World Clock).
    /// Carries a `displayLabel` that matches Requirement 8.4 formatting.
    /// The hotkey is provided as a `(keyCode, modifierFlags)` tuple so this
    /// helper does not depend on the `KeyboardShortcuts` package directly.
    /// Callers extract the live values from `KeyboardShortcuts.Name.popup`
    /// / `.worldClockPopup` and build the appropriate value via the
    /// factory helpers below.
    struct KnownPopupHotkey: Equatable {
        let displayLabel: String
        let keyCode: UInt16
        let modifierFlags: UInt

        /// The Clipboard Shelf popup hotkey.
        static func clipboardShelfPopup(keyCode: UInt16, modifierFlags: UInt) -> KnownPopupHotkey {
            KnownPopupHotkey(
                displayLabel: "Clipboard Shelf popup",
                keyCode: keyCode,
                modifierFlags: modifierFlags
            )
        }

        /// The World Clock popup hotkey.
        static func worldClockPopup(keyCode: UInt16, modifierFlags: UInt) -> KnownPopupHotkey {
            KnownPopupHotkey(
                displayLabel: "World Clock popup",
                keyCode: keyCode,
                modifierFlags: modifierFlags
            )
        }

        /// The Bookmark Shelf popup hotkey.
        static func bookmarkShelfPopup(keyCode: UInt16, modifierFlags: UInt) -> KnownPopupHotkey {
            KnownPopupHotkey(
                displayLabel: "Bookmark Shelf popup",
                keyCode: keyCode,
                modifierFlags: modifierFlags
            )
        }
    }

    /// Scan the recorded shortcut against menu views, other standalone
    /// modules, and known popup hotkeys, returning the first conflict in
    /// priority order or nil when no conflict exists. `currentEntryID`
    /// names the standalone module whose recorder is being shown, so it
    /// can be skipped in the standalone-module bucket (Requirement 8.2).
    ///
    /// Priority order matches the design's *Hotkey Conflict Scan* table:
    /// menu views first, then other standalone modules, then known popup
    /// hotkeys (Requirement 8.1, 8.2, 8.3).
    static func scan(
        recorded: KeyboardShortcutConfig?,
        currentEntryID: UUID?,
        menuViews: [MenuViewConfig],
        standaloneModules: [StandaloneModuleConfig],
        knownPopupHotkeys: [KnownPopupHotkey]
    ) -> StandaloneModuleHotkeyConflict? {
        guard let recorded,
              recorded.isEnabled,
              let recordedKeyCode = recorded.keyCode else {
            return nil
        }

        let recordedFlags = NSEvent.ModifierFlags(rawValue: recorded.modifierFlags)
            .intersection(.deviceIndependentFlagsMask).rawValue

        // Priority 1: menu views.
        for view in menuViews {
            guard let shortcut = view.shortcut,
                  shortcut.isEnabled,
                  let keyCode = shortcut.keyCode,
                  keyCode == recordedKeyCode else { continue }
            let flags = NSEvent.ModifierFlags(rawValue: shortcut.modifierFlags)
                .intersection(.deviceIndependentFlagsMask).rawValue
            if flags == recordedFlags {
                return StandaloneModuleHotkeyConflict(ownerName: "menu view '\(view.title)'")
            }
        }

        // Priority 2: other standalone modules (skip self).
        for module in standaloneModules {
            if module.id == currentEntryID { continue }
            guard let shortcut = module.shortcut,
                  shortcut.isEnabled,
                  let keyCode = shortcut.keyCode,
                  keyCode == recordedKeyCode else { continue }
            let flags = NSEvent.ModifierFlags(rawValue: shortcut.modifierFlags)
                .intersection(.deviceIndependentFlagsMask).rawValue
            if flags == recordedFlags {
                return StandaloneModuleHotkeyConflict(ownerName: "standalone module '\(module.title)'")
            }
        }

        // Priority 3: known popup hotkeys (Clipboard Shelf, World Clock).
        for popup in knownPopupHotkeys {
            let flags = NSEvent.ModifierFlags(rawValue: popup.modifierFlags)
                .intersection(.deviceIndependentFlagsMask).rawValue
            if popup.keyCode == recordedKeyCode && flags == recordedFlags {
                return StandaloneModuleHotkeyConflict(ownerName: popup.displayLabel)
            }
        }

        return nil
    }
}
