//
//  BookmarkShelfPanel.swift
//  MenuShelf
//
//  Floating `NSPanel` hosting the Bookmark Shelf popup SwiftUI tree.
//  Modelled after `Sources/MenuShelf/WorldClock/WorldClockPanel.swift`
//  (a peer of the Clipboard Shelf vendored `FloatingPanel`, not a
//  subclass) because the Bookmark Shelf popup has no preview pane,
//  no auto-open machinery, and no clipboard-specific delegate hooks.
//
//  - `.nonactivatingPanel` so the user's frontmost app keeps focus.
//  - `.statusBar` window level so the panel draws over normal app
//    windows.
//  - Closes on outside click via `resignKey()`.
//  - Calls its `onClose` callback on every dismissal so the
//    controller can pop the breadcrumb back-stack to root
//    (Requirement 8.11).
//

import AppKit
import SwiftUI

@MainActor
final class BookmarkShelfPanel: NSPanel, NSWindowDelegate {

    /// Tracks whether the panel is currently shown. Mirrors the
    /// `isPresented` flag on the vendored `FloatingPanel` so the
    /// controller can decide toggle direction without going through
    /// `isVisible`, which is `false` for a brief window during
    /// teardown.
    var isPresented: Bool = false

    /// The status button the panel is anchored to. Set by
    /// `openAtAnchor(_:)` before the panel is shown so positioning
    /// lines up under the originating menu-bar item, and so the
    /// highlight effect on that button can be toggled in lockstep
    /// with the panel.
    private var statusBarButton: NSStatusBarButton?

    /// Callback invoked from `close()` so the controller can pop the
    /// breadcrumb back-stack on every dismissal. Stored as a
    /// `() -> Void` rather than via delegate so tests can substitute
    /// a different callback.
    let onClose: () -> Void

    /// Observable state driving the SwiftUI tree. Owned by the panel
    /// so the controller can reach `popupState.popToRoot()` from
    /// `handlePanelClose()` (Task 7.7).
    let popupState: BookmarkShelfPopupState

    /// Pending content size pushed in by `apply(settings:)`. Applied
    /// on the next `openAtAnchor(_:)` so an in-flight size change
    /// does not resize the panel mid-display.
    private var pendingContentSize: CGSize?

    init(
        contentRect: NSRect,
        identifier: String,
        storage: BookmarkShelfStorage,
        onClose: @escaping () -> Void
    ) {
        self.onClose = onClose
        self.popupState = BookmarkShelfPopupState()

        super.init(
            contentRect: contentRect,
            styleMask: [.nonactivatingPanel, .resizable, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )

        self.identifier = NSUserInterfaceItemIdentifier(identifier)

        delegate = self

        animationBehavior = .none
        isFloatingPanel = true
        level = .statusBar
        collectionBehavior = [.auxiliary, .stationary, .moveToActiveSpace, .fullScreenAuxiliary]
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        isMovableByWindowBackground = false
        hidesOnDeactivate = false
        backgroundColor = .clear
        titlebarSeparatorStyle = .none

        // Hide the traffic light buttons. The panel uses
        // `.fullSizeContentView` so the SwiftUI root view paints all
        // the way to the window edges; visible traffic lights would
        // sit on top of that content.
        standardWindowButton(.closeButton)?.isHidden = true
        standardWindowButton(.miniaturizeButton)?.isHidden = true
        standardWindowButton(.zoomButton)?.isHidden = true

        contentView = NSHostingView(
            rootView: BookmarkShelfPopupView(state: popupState, storage: storage)
                .ignoresSafeArea()
        )
    }

    // MARK: - Public API

    /// Position and show the panel anchored to `button` (or centre it
    /// on the active screen when `button` is nil). When the
    /// controller pushed in a new `pendingContentSize` since the last
    /// open, apply it now so the next open uses the new size
    /// (Requirement 7.8).
    func openAtAnchor(_ button: NSStatusBarButton?) {
        statusBarButton = button

        if let size = pendingContentSize {
            setContentSize(NSSize(width: size.width, height: size.height))
            pendingContentSize = nil
        }

        let size = frame.size
        let origin: NSPoint
        if let button {
            origin = anchorOrigin(for: button, size: size)
        } else if let visible = NSScreen.main?.visibleFrame {
            origin = NSPoint(
                x: visible.midX - size.width / 2,
                y: visible.midY - size.height / 2
            )
        } else {
            var cursor = NSEvent.mouseLocation
            cursor.y -= size.height
            origin = cursor
        }
        setFrameOrigin(origin)

        orderFrontRegardless()
        makeKey()
        isPresented = true

        if button != nil {
            DispatchQueue.main.async { [weak self] in
                self?.statusBarButton?.isHighlighted = true
            }
        }
    }

    /// Stash a new popup size for application on the next open. The
    /// controller calls this from `apply(settings:)` when the user
    /// edits the size in the settings pane (Requirement 7.8).
    func updateContentSize(_ size: CGSize) {
        pendingContentSize = size
    }

    // MARK: - AppKit overrides

    /// Funnel every dismissal path (programmatic, outside-click, Esc)
    /// through this override so `onClose` fires exactly once per
    /// dismissal.
    override func close() {
        super.close()
        isPresented = false
        statusBarButton?.isHighlighted = false
        onClose()
    }

    /// Close on outside click. Guard against alert sheets so a
    /// confirmation dialog presented over the popup does not also
    /// close the popup.
    override func resignKey() {
        super.resignKey()
        if NSApp.alertWindow == nil {
            close()
        }
    }

    /// Allow the panel to take key focus so SwiftUI text inputs
    /// inside the popup (the inline "+ Add URL" form) can receive
    /// keystrokes.
    override var canBecomeKey: Bool { true }

    // MARK: - Anchor positioning

    /// Compute the origin that places the panel just below the menu-
    /// bar status button. Mirrors `WorldClockPanel.anchorOrigin(for:
    /// size:)` field-for-field: align the panel's top-left with the
    /// button's bottom-left, then nudge left when the panel would
    /// otherwise spill past the screen's right edge.
    private func anchorOrigin(
        for button: NSStatusBarButton,
        size: NSSize
    ) -> NSPoint {
        guard let screen = NSScreen.main else {
            var cursor = NSEvent.mouseLocation
            cursor.y -= size.height
            return cursor
        }
        let rectInWindow = button.convert(button.bounds, to: nil)
        guard let screenRect = button.window?.convertToScreen(rectInWindow) else {
            return NSPoint(
                x: screen.frame.midX - size.width / 2,
                y: screen.frame.maxY - size.height
            )
        }
        var topLeft = NSPoint(
            x: screenRect.minX,
            y: screenRect.minY - size.height
        )
        if topLeft.x + size.width > screen.frame.maxX {
            topLeft.x = screen.frame.maxX - size.width
        }
        return topLeft
    }
}
