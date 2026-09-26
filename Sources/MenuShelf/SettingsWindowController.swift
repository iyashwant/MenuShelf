import AppKit
import SwiftUI

final class SettingsWindowController: NSObject, NSWindowDelegate {
    /// Size the window opens at when the display has room for it. The Menu Bar
    /// pane is four columns wide (sidebar + item list + view contents + detail)
    /// and cannot lay out below roughly 1260pt, so opening any narrower than
    /// this just makes SwiftUI stretch the window back out on first display.
    private static let defaultContentSize = NSSize(width: 1280, height: 800)

    /// Gap kept between the window and the edges of the screen's visible area.
    private static let screenMargin: CGFloat = 16

    private let store: PreferencesStore
    private var window: NSWindow?

    /// Guards against re-entering `fitWindowToScreen(_:recentering:)` from the
    /// `windowDidResize(_:)` its own `setFrame` triggers.
    private var isFittingWindow = false

    init(store: PreferencesStore) {
        self.store = store
        super.init()

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screenParametersChanged),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
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

            // The settings panes cannot lay out below ~1260pt wide. AppKit
            // enforces that on first display by resizing the window *after* it
            // has been positioned, anchored at the top-left corner — which is
            // why a window opened at 840pt and centred ended up hanging off the
            // right edge of the screen. Publish the minimum as the window's
            // content minimum (so it can never be resized into clipping) and
            // open at a size that already satisfies it, then keep the frame
            // inside the screen in `fitWindowToScreen(_:recentering:)`.
            hostingController.sizingOptions = [.minSize]

            let styleMask: NSWindow.StyleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
            let initialContentRect = NSRect(origin: .zero, size: Self.defaultContentSize)

            let settingsWindow = NSWindow(
                contentRect: initialContentRect,
                styleMask: styleMask,
                backing: .buffered,
                defer: false
            )
            settingsWindow.contentViewController = hostingController
            settingsWindow.title = ""
            settingsWindow.titlebarAppearsTransparent = true
            settingsWindow.titleVisibility = .hidden
            settingsWindow.isReleasedWhenClosed = false
            settingsWindow.delegate = self

            // Remove any stale saved frame from previous builds.
            NSWindow.removeFrame(usingName: "MenuShelfSettings")

            window = settingsWindow
            fitWindowToScreen(settingsWindow, recentering: true)
        } else if let window {
            // The window survives between openings, so the display it was last
            // placed on may have gone away or changed resolution in the meantime.
            fitWindowToScreen(window, recentering: false)
        }

        // Promote to a regular app so the Dock icon appears while the settings
        // window is on screen. MenuShelf otherwise runs as a menu-bar-only
        // (.accessory) app with no Dock presence.
        NSApp.setActivationPolicy(.regular)

        NSRunningApplication.current.activate(options: [.activateAllWindows])
        window?.makeKeyAndOrderFront(nil)
        window?.orderFrontRegardless()
        if let frame = window?.frame {
            DiagnosticsLogger.shared.log("Settings window ordered front at \(NSStringFromRect(frame))")
        }
    }

    // MARK: - Geometry

    /// Keeps the settings window inside the visible area of its screen.
    ///
    /// With `recentering` the window is sized to `defaultContentSize` (shrunk to
    /// fit if the display is smaller) and centred; otherwise the current size and
    /// position are preserved and only clamped back on screen when they overflow,
    /// so a window the user has resized or moved stays where they put it.
    ///
    /// The size is never taken below the content's own minimum: a window too
    /// small for the panes is worse than one that overhangs a cramped display.
    private func fitWindowToScreen(_ window: NSWindow, recentering: Bool) {
        guard !isFittingWindow else { return }
        guard let visibleFrame = (window.screen ?? NSScreen.main)?.visibleFrame else { return }

        let margin = Self.screenMargin
        let minSize = window.frameRect(forContentRect: NSRect(origin: .zero, size: window.contentMinSize)).size
        let maxWidth = max(visibleFrame.width - margin * 2, minSize.width)
        let maxHeight = max(visibleFrame.height - margin * 2, minSize.height)

        var frame = window.frame

        if recentering {
            frame.size = window.frameRect(
                forContentRect: NSRect(origin: .zero, size: Self.defaultContentSize)
            ).size
        }

        frame.size.width = min(frame.width, maxWidth)
        frame.size.height = min(frame.height, maxHeight)

        if recentering {
            frame.origin = NSPoint(
                x: visibleFrame.midX - frame.width / 2,
                y: visibleFrame.midY - frame.height / 2
            )
        }

        // Prefer showing the top-left of the window when it is larger than the
        // screen, since that is where the sidebar and the pane content start.
        frame.origin.x = max(visibleFrame.minX, min(frame.origin.x, visibleFrame.maxX - frame.width))
        frame.origin.y = min(visibleFrame.maxY - frame.height, max(frame.origin.y, visibleFrame.minY))

        guard frame != window.frame else { return }

        isFittingWindow = true
        window.setFrame(frame, display: window.isVisible)
        isFittingWindow = false
    }

    /// SwiftUI applies the panes' minimum width by resizing the window on first
    /// display, keeping the top-left corner fixed. Re-clamp afterwards so that
    /// growth can never push the window off the edge of the screen.
    ///
    /// Live resizes are left alone — the user dragging an edge is deliberate,
    /// and the pointer cannot leave the screen anyway.
    func windowDidResize(_ notification: Notification) {
        guard let window, window.contentView?.inLiveResize != true else { return }
        fitWindowToScreen(window, recentering: false)
    }

    @objc private func screenParametersChanged() {
        guard let window, window.isVisible else { return }
        fitWindowToScreen(window, recentering: false)
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
