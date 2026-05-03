import AppKit
import Carbon
import Foundation

final class GlobalHotkeyService {
    private let signature: OSType = 0x4D_53_48_46 // MSHF
    private var eventHandler: EventHandlerRef?
    private var registrations: [UInt32: EventHotKeyRef] = [:]
    private var menuViewIDsByHotKeyID: [UInt32: UUID] = [:]
    private var nextHotKeyID: UInt32 = 1
    private var onHotKey: ((UUID) -> Void)?

    init() {
        installEventHandler()
    }

    deinit {
        unregisterAll()
        if let eventHandler {
            RemoveEventHandler(eventHandler)
        }
    }

    func registerShortcuts(for menuViews: [MenuViewConfig], onHotKey: @escaping (UUID) -> Void) {
        unregisterAll()
        self.onHotKey = onHotKey

        for view in menuViews {
            guard let shortcut = view.shortcut,
                  shortcut.isEnabled,
                  let keyCode = shortcut.keyCode else {
                continue
            }

            let hotKeyIDValue = nextHotKeyID
            nextHotKeyID += 1

            var carbonHotKeyID = EventHotKeyID(signature: signature, id: hotKeyIDValue)
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
                registrations[hotKeyIDValue] = hotKeyRef
                menuViewIDsByHotKeyID[hotKeyIDValue] = view.id
                DiagnosticsLogger.shared.log("Registered hotkey for \(view.title): \(shortcut.displayString)")
            } else {
                DiagnosticsLogger.shared.log("Failed to register hotkey for \(view.title): \(status)")
            }
        }
    }

    private func unregisterAll() {
        for ref in registrations.values {
            UnregisterEventHotKey(ref)
        }
        registrations.removeAll()
        menuViewIDsByHotKeyID.removeAll()
    }

    private func installEventHandler() {
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )

        let callback: EventHandlerUPP = { _, event, userData in
            guard let event, let userData else { return noErr }

            var hotKeyID = EventHotKeyID()
            let status = GetEventParameter(
                event,
                EventParamName(kEventParamDirectObject),
                EventParamType(typeEventHotKeyID),
                nil,
                MemoryLayout<EventHotKeyID>.size,
                nil,
                &hotKeyID
            )

            guard status == noErr else { return status }

            let service = Unmanaged<GlobalHotkeyService>.fromOpaque(userData).takeUnretainedValue()
            service.handleHotKey(id: hotKeyID.id)
            return noErr
        }

        InstallEventHandler(
            GetApplicationEventTarget(),
            callback,
            1,
            &eventType,
            Unmanaged.passUnretained(self).toOpaque(),
            &eventHandler
        )
    }

    private func handleHotKey(id: UInt32) {
        guard let menuViewID = menuViewIDsByHotKeyID[id] else { return }
        DispatchQueue.main.async { [onHotKey] in
            onHotKey?(menuViewID)
        }
    }

    private func carbonModifiers(from flags: NSEvent.ModifierFlags) -> UInt32 {
        var modifiers: UInt32 = 0
        if flags.contains(.command) { modifiers |= UInt32(cmdKey) }
        if flags.contains(.option) { modifiers |= UInt32(optionKey) }
        if flags.contains(.control) { modifiers |= UInt32(controlKey) }
        if flags.contains(.shift) { modifiers |= UInt32(shiftKey) }
        return modifiers
    }
}
