//
//  MenuShelfPickerController.swift
//  MenuShelf
//
//  Owns the picker NSPanel. Called by AppDelegate when MenuShelf receives an
//  http(s) URL open as the system default browser.
//

import AppKit
import SwiftUI
import Foundation

@MainActor
final class MenuShelfPickerController: NSObject, NSWindowDelegate {
    static let shared = MenuShelfPickerController()

    private var pickerWindow: MenuShelfPickerWindow?

    func handle(urls incoming: [URL]) {
        var processedUrls = incoming

        // Decode `menushelf-ask://open?url=<base64>` so other tools can pipe
        // a URL into us without setting us as default first.
        if processedUrls.count == 1 {
            let url = processedUrls.first!
            if url.scheme == "menushelf-ask" && url.host == "open" {
                if let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
                   let queryItems = components.queryItems,
                   let encoded = queryItems.first(where: { $0.name == "url" })?.value,
                   let data = Data(base64Encoded: encoded),
                   let str = String(data: data, encoding: .utf8),
                   let decoded = URL(string: str) {
                    processedUrls = [decoded]
                } else {
                    return
                }
            }
        }

        showPicker(for: processedUrls, browsers: resolvedBrowsers())
    }

    /// The browser list the picker should show, mirroring the Browser Flip
    /// settings page exactly: only visible browsers, in the user's configured
    /// order, with MenuShelf's own "Ask Everytime" entry excluded. Falls back
    /// to live discovery when Browser Flip was never configured so the picker
    /// still works if MenuShelf was made default by other means.
    private func resolvedBrowsers() -> [URL] {
        let saved = AppContainer.shared.store.settings.resolvedBrowserFlip.savedBrowsers
        let ordered = saved
            .filter { $0.isVisible }
            .filter { !MenuBuilder.isAskEverytime($0) }
            .sorted { $0.sortOrder < $1.sortOrder }
            .map { $0.appURL }

        if !ordered.isEmpty {
            MenuShelfPickerOpener.ensureShortcutsAssigned(for: ordered)
            return ordered
        }

        return MenuShelfPickerOpener.loadBrowsers(oldBrowsers: [])
    }

    private func showPicker(for urls: [URL], browsers: [URL]) {
        if pickerWindow == nil {
            pickerWindow = MenuShelfPickerWindow()
        }
        guard let window = pickerWindow else { return }

        let screen = (screenWithMouse() ?? NSScreen.main)?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1440, height: 900)

        window.setFrameOrigin(
            NSPoint(
                x: clamp(
                    min: screen.minX + 20,
                    max: screen.maxX - window.frame.width - 20,
                    value: NSEvent.mouseLocation.x - window.frame.width / 2
                ),
                y: clamp(
                    min: screen.minY + 20,
                    max: screen.maxY - window.frame.height - 20,
                    value: NSEvent.mouseLocation.y - (window.frame.height - 30)
                )
            )
        )

        NSApplication.shared.activate(ignoringOtherApps: true)
        window.deactivateDelay()

        window.contentView = NSHostingView(rootView: MenuShelfPickerView(urls: urls, browsers: browsers))

        window.makeKeyAndOrderFront(nil)
        window.isReleasedWhenClosed = false
        window.delegate = self
    }

    nonisolated func windowDidResignKey(_ notification: Notification) {
        Task { @MainActor in
            guard let window = self.pickerWindow else { return }
            if window.hidesOnDeactivate {
                window.contentView = nil
                window.close()
            }
        }
    }

    private func clamp(min: CGFloat, max: CGFloat, value: CGFloat) -> CGFloat {
        CGFloat.minimum(CGFloat.maximum(min, value), max)
    }

    private func screenWithMouse() -> NSScreen? {
        let mouseLocation = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(mouseLocation, $0.frame, false) }
    }
}
