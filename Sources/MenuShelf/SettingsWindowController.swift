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
        focusClockShelf: Bool = false,
        scrollToClockID: UUID? = nil,
        focusStandaloneModules: Bool = false,
        scrollToStandaloneModuleID: UUID? = nil,
        focusBrowserFlip: Bool = false,
        focusBookmarkShelf: Bool = false,
        focusCaffeineShelf: Bool = false
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

        if focusClockShelf {
            NotificationCenter.default.post(name: .menuShelfFocusClockShelf, object: nil)
        }

        if focusStandaloneModules {
            NotificationCenter.default.post(name: .menuShelfFocusStandaloneModules, object: nil)
        }

        if focusBrowserFlip {
            NotificationCenter.default.post(name: .menuShelfFocusBrowserFlip, object: nil)
        }

        // Post the bookmark-shelf focus notification BEFORE any
        // window-creation step so the destination view is mounted when
        // the focus signal arrives (Requirement 18.2).
        if focusBookmarkShelf {
            NotificationCenter.default.post(name: .menuShelfFocusBookmarkShelf, object: nil)
        }

        if focusCaffeineShelf {
            NotificationCenter.default.post(name: .menuShelfFocusCaffeineShelf, object: nil)
        }

        if let scrollToClockID {
            NotificationCenter.default.post(
                name: .menuShelfScrollToClockShelf,
                object: nil,
                userInfo: ["clockID": scrollToClockID]
            )
        }

        if let scrollToStandaloneModuleID {
            NotificationCenter.default.post(
                name: .menuShelfScrollToStandaloneModule,
                object: nil,
                userInfo: ["standaloneModuleID": scrollToStandaloneModuleID]
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

        // Promote to a regular app so the Dock icon appears while the settings
        // window is on screen. MenuShelf otherwise runs as a menu-bar-only
        // (.accessory) app with no Dock presence.
        NSApp.setActivationPolicy(.regular)

        NSRunningApplication.current.activate(options: [.activateAllWindows])
        window?.makeKeyAndOrderFront(nil)
        window?.orderFrontRegardless()
        DiagnosticsLogger.shared.log("Settings window ordered front")
    }

    // Closing the settings window is the user's signal that they're done editing
    // for now; flush any debounced save immediately so the file on disk matches
    // what they see in the UI.
    func windowWillClose(_ notification: Notification) {
        store.flushPendingSave()

        // Drop the Dock icon again once the settings window is gone, returning
        // MenuShelf to its menu-bar-only (.accessory) presentation.
        NSApp.setActivationPolicy(.accessory)
    }
}


extension Notification.Name {
    /// Posted when the settings window should switch to the AppleScripts pane
    /// and focus a specific script. Object is the target UUID.
    static let menuShelfFocusAppleScripts = Notification.Name("menuShelfFocusAppleScripts")

    /// Posted when the settings window should switch to the Clipboard Shelf pane.
    static let menuShelfFocusClipboardShelf = Notification.Name("menuShelfFocusClipboardShelf")

    /// Posted when the settings window should switch to the Clock Shelf pane.
    static let menuShelfFocusClockShelf = Notification.Name("menuShelfFocusClockShelf")

    /// Posted when the Clock Shelf settings view should scroll to a specific
    /// clock row. `userInfo["clockID"]` carries the target `UUID`.
    static let menuShelfScrollToClockShelf = Notification.Name("menuShelfScrollToClockShelf")

    /// Posted when the settings window should switch to the Standalone Modules pane.
    static let menuShelfFocusStandaloneModules = Notification.Name("menuShelfFocusStandaloneModules")

    /// Posted when the Standalone Modules settings view should scroll to a
    /// specific module row. `userInfo["standaloneModuleID"]` carries the
    /// target `UUID`.
    static let menuShelfScrollToStandaloneModule = Notification.Name("menuShelfScrollToStandaloneModule")

    /// Posted when the settings window should switch to the Browser Flip pane.
    static let menuShelfFocusBrowserFlip = Notification.Name("menuShelfFocusBrowserFlip")

    /// Posted when the settings window should switch to the Bookmark Shelf pane.
    static let menuShelfFocusBookmarkShelf = Notification.Name("menuShelfFocusBookmarkShelf")

    /// Posted when the settings window should switch to the CaffeineShelf pane.
    static let menuShelfFocusCaffeineShelf = Notification.Name("menuShelfFocusCaffeineShelf")
}
