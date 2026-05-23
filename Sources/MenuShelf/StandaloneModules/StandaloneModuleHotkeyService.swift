import AppKit
import Carbon
import Foundation

extension GlobalHotkeyService {
    /// Register Carbon hotkeys for the visible standalone modules whose
    /// `shortcut` is non-nil and not `.disabled`. Replaces any previously
    /// registered standalone-module hotkeys (the menu-view bucket is
    /// untouched). Stores the active callback for dispatch.
    func registerStandaloneModuleShortcuts(
        for modules: [StandaloneModuleConfig],
        onHotKey: @escaping (UUID) -> Void
    ) {
        unregisterAllStandaloneModuleHotkeys()
        self.onStandaloneModuleHotKey = onHotKey

        for module in modules where module.isVisible {
            guard let shortcut = module.shortcut,
                  shortcut.isEnabled,
                  let keyCode = shortcut.keyCode else {
                continue
            }

            let hotKeyIDValue = nextHotKeyID
            nextHotKeyID += 1

            let carbonHotKeyID = EventHotKeyID(signature: signature, id: hotKeyIDValue)
            var hotKeyRef: EventHotKeyRef?
            let status = RegisterEventHotKey(
                UInt32(keyCode),
                carbonModifiers(from: NSEvent.ModifierFlags(rawValue: shortcut.modifierFlags)),
                carbonHotKeyID,
                GetApplicationEventTarget(),
                0,
                &hotKeyRef
            )

            if status == noErr, let hotKeyRef {
                standaloneModuleRegistrations[hotKeyIDValue] = hotKeyRef
                standaloneModuleIDsByHotKeyID[hotKeyIDValue] = module.id
                DiagnosticsLogger.shared.log(
                    "Registered standalone module hotkey id=\(module.id.uuidString) kind=\(module.kind.rawValue)"
                )
            } else {
                DiagnosticsLogger.shared.log(
                    "Failed to register standalone module hotkey id=\(module.id.uuidString) kind=\(module.kind.rawValue) status=\(status)"
                )
            }
        }
    }

    /// Unregister every standalone-module hotkey. Leaves menu-view
    /// registrations untouched.
    func unregisterAllStandaloneModuleHotkeys() {
        for ref in standaloneModuleRegistrations.values {
            UnregisterEventHotKey(ref)
        }
        standaloneModuleRegistrations.removeAll()
        standaloneModuleIDsByHotKeyID.removeAll()
    }
}
