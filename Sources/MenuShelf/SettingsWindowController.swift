import AppKit
import SwiftUI

final class SettingsWindowController: NSObject, NSWindowDelegate {
    private let store: PreferencesStore
    private var window: NSWindow?

    init(store: PreferencesStore) {
        self.store = store
    }

    @objc func showFromMenu(_ sender: Any?) {
        show()
    }

    func show(
        selectedFolderID: UUID? = nil,
        selectedMenuViewID: UUID? = nil,
        selectedAppleScriptID: UUID? = nil,
        focusClipboardShelf: Bool = false,
        focusWorldClock: Bool = false,
        scrollToClockID: UUID? = nil
    ) {
        if let selectedMenuViewID {
            store.selectedMenuViewID = selectedMenuViewID
        }

        if let selectedFolderID {
            store.selectedFolderID = selectedFolderID
        }

        if let selectedAppleScriptID {
            store.selectedAppleScriptID = selectedAppleScriptID
            NotificationCenter.default.post(name: .menuShelfFocusAppleScripts, object: selectedAppleScriptID)
        }

        if focusClipboardShelf {
            NotificationCenter.default.post(name: .menuShelfFocusClipboardShelf, object: nil)
        }

        if focusWorldClock {
            NotificationCenter.default.post(name: .menuShelfFocusWorldClock, object: nil)
        }

        if let scrollToClockID {
            NotificationCenter.default.post(
                name: .menuShelfScrollToWorldClock,
                object: nil,
                userInfo: ["clockID": scrollToClockID]
            )
        }

        if window == nil {
            let rootView = SettingsView()
                .environmentObject(store)

            let hostingController = NSHostingController(rootView: rootView)
            let contentSize = NSSize(width: 840, height: 620)
            let styleMask: NSWindow.StyleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
            let initialContentRect = NSRect(origin: .zero, size: contentSize)

            let settingsWindow = NSWindow(
                contentRect: initialContentRect,
                styleMask: styleMask,
                backing: .buffered,
                defer: false
            )
            settingsWindow.contentViewController = hostingController
            settingsWindow.title = ""
            settingsWindow.minSize = NSSize(width: 760, height: 520)
            settingsWindow.titlebarAppearsTransparent = true
            settingsWindow.titleVisibility = .hidden
            settingsWindow.isReleasedWhenClosed = false
            settingsWindow.delegate = self

            // Remove any stale saved frame from previous builds.
            NSWindow.removeFrame(usingName: "MenuShelfSettings")

            // Set the content size explicitly, then center on screen.
            settingsWindow.setContentSize(contentSize)
            settingsWindow.center()

            window = settingsWindow
        }

        NSRunningApplication.current.activate(options: [.activateAllWindows, .activateIgnoringOtherApps])
        window?.makeKeyAndOrderFront(nil)
        window?.orderFrontRegardless()
        DiagnosticsLogger.shared.log("Settings window ordered front")
    }

    // Closing the settings window is the user's signal that they're done editing
    // for now; flush any debounced save immediately so the file on disk matches
    // what they see in the UI.
    func windowWillClose(_ notification: Notification) {
        store.flushPendingSave()
    }
}


extension Notification.Name {
    /// Posted when the settings window should switch to the AppleScripts pane
    /// and focus a specific script. Object is the target UUID.
    static let menuShelfFocusAppleScripts = Notification.Name("menuShelfFocusAppleScripts")

    /// Posted when the settings window should switch to the Clipboard Shelf pane.
    static let menuShelfFocusClipboardShelf = Notification.Name("menuShelfFocusClipboardShelf")

    /// Posted when the settings window should switch to the World Clock pane.
    static let menuShelfFocusWorldClock = Notification.Name("menuShelfFocusWorldClock")

    /// Posted when the World Clock settings view should scroll to a specific
    /// clock row. `userInfo["clockID"]` carries the target `UUID`.
    static let menuShelfScrollToWorldClock = Notification.Name("menuShelfScrollToWorldClock")
}
