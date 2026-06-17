//
//  WorldClockPanel.swift
//  MenuShelf
//
//  Floating panel that hosts the World Clock popover SwiftUI tree.
//  Modelled after `Sources/MenuShelf/ClipboardShelf/Vendor/FloatingPanel.swift`
//  but built as a peer (not a subclass) because the vendored panel's
//  delegate methods are riddled with `ClipboardShelfState.shared.preview`
//  calls that are irrelevant to World Clock. Subclassing and overriding
//  every preview-dependent delegate method would be brittle; a peer
//  class with only the bits World Clock needs is much cleaner.
//
//  The panel:
//
//  - Uses `.nonactivatingPanel` so the user's frontmost app keeps focus
//    (important so "Copy Time" can paste back into that app).
//  - Sits at `.statusBar` window level so it draws over normal app
//    windows, matching the menu-bar surface.
//  - Closes on outside click via `resignKey()` (Requirement 3.9).
//  - Calls its `onClose` callback on every dismissal so the controller
//    can reset `Time_Travel_Offset` to zero (Requirement 5.6).
//

import AppKit
import SwiftUI

/// Floating popover hosting `WorldClockPopoverView`. The panel is
/// non-generic because it only ever hosts one view tree.
@MainActor
final class WorldClockPanel: NSPanel, NSWindowDelegate {
    /// Tracks whether the panel is currently shown. Mirrors
    /// `FloatingPanel.isPresented` so the controller can decide
    /// toggle direction without going through `isVisible`, which is
    /// `false` for a brief window during teardown.
    var isPresented: Bool = false

    /// The status button the panel is anchored to. Set by `open(at:)`
    /// before the panel is shown so positioning lines up under the
    /// originating menu-bar item, and so the highlight effect on that
    /// button can be toggled in lockstep with the panel.
    var statusBarButton: NSStatusBarButton?

    /// Callback invoked from `close()` so the controller can reset
    /// `Time_Travel_Offset` to zero on every dismissal (Requirement
    /// 5.6). Stored as `() -> Void` rather than escaping closure
    /// capture into a delegate so the controller can replace the
    /// callback in tests.
    let onClose: () -> Void

    /// Default content size for the popover. Wide enough for two lines
    /// of clock rows plus the time-travel slider and overflow menu.
    static let defaultContentSize = NSSize(width: 320, height: 280)

    init(
        popoverState: WorldClockPopoverState,
        onClose: @escaping () -> Void
    ) {
        self.onClose = onClose

        super.init(
            contentRect: NSRect(origin: .zero, size: Self.defaultContentSize),
            styleMask: [.nonactivatingPanel, .resizable, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )

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
            rootView: WorldClockPopoverView(state: popoverState)
                .ignoresSafeArea()
        )
    }

    /// Position and show the panel anchored to `button` (or the cursor
    /// when `button` is `nil`). The status bar button is highlighted
    /// while the panel is presented so the menu-bar surface matches
    /// the rest of MenuShelf.
    func open(at button: NSStatusBarButton?) {
        statusBarButton = button

        let size = frame.size
        let origin: NSPoint
        if let button {
            origin = anchorOrigin(for: button, size: size)
        } else {
            // Fallback when no anchor is available (Requirement 9.3
            // step 3 — center on the active screen).
            if let visible = NSScreen.main?.visibleFrame {
                origin = NSPoint(
                    x: visible.midX - size.width / 2,
                    y: visible.midY - size.height / 2
                )
            } else {
                var cursor = NSEvent.mouseLocation
                cursor.y -= size.height
                origin = cursor
            }
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

    /// AppKit calls `close()` for outside-clicks (via the `resignKey()`
    /// override below), `Esc`, and explicit programmatic dismissal.
    /// Funnel every path through this override so the `onClose`
    /// callback fires exactly once per dismissal.
    override func close() {
        super.close()
        isPresented = false
        statusBarButton?.isHighlighted = false
        onClose()
    }

    /// Close on outside click so a tap anywhere outside the popover
    /// dismisses it (Requirement 3.9). Guard against alert sheets so
    /// a confirmation dialog presented over the popover does not also
    /// close the popover.
    override func resignKey() {
        super.resignKey()
        if NSApp.alertWindow == nil {
            close()
        }
    }

    /// Allow the panel to take key focus so SwiftUI text inputs inside
    /// the popover (e.g. the future "Edit…" sheet's text fields) can
    /// receive keystrokes.
    override var canBecomeKey: Bool { true }

    // MARK: - Anchor positioning

    /// Compute the origin that places the panel just below the menu-bar
    /// status button. Mirrors `PopupPosition.statusItem` from the
    /// vendored Clipboard Shelf panel: align the panel's top-left with
    /// the button's bottom-left, then nudge left when the panel would
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
