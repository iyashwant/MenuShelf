//
//  MenuShelfPickerWindow.swift
//  MenuShelf
//
//  "Ask Everytime" picker. Self-contained inside MenuShelf — no dependency
//  on Browser Flip.app being installed. 

import Foundation
import AppKit

final class MenuShelfPickerWindow: NSPanel {
    static let selectorWidth: CGFloat = 250
    static let selectorHeight: CGFloat = 200

    convenience init() {
        self.init(
            contentRect: .init(x: 0, y: 0, width: Self.selectorWidth, height: Self.selectorHeight),
            styleMask: [.nonactivatingPanel, .titled, .fullSizeContentView, .resizable],
            backing: .buffered,
            defer: false
        )

        self.titlebarAppearsTransparent = true
        self.titleVisibility = .hidden
        self.minSize = NSSize(width: Self.selectorWidth, height: Self.selectorHeight)

        self.standardWindowButton(.miniaturizeButton)?.isHidden = true
        self.standardWindowButton(.closeButton)?.isHidden = true
        self.standardWindowButton(.zoomButton)?.isHidden = true

        self.setFrameAutosaveName("menushelf_ask_everytime_picker_size")

        self.collectionBehavior = [.stationary, .ignoresCycle, .fullScreenAuxiliary, .canJoinAllSpaces]
        self.isOpaque = false
        self.level = NSWindow.Level(Int(CGShieldingWindowLevel()))
        self.isMovable = false
        self.deactivateDelay()
    }

    func deactivateDelay() {
        self.hidesOnDeactivate = false
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(100)) {
            NSApplication.shared.activate(ignoringOtherApps: true)
            self.makeKeyAndOrderFront(nil)
            self.hidesOnDeactivate = true
        }
    }

    override var canBecomeKey: Bool { true }
}
