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

    @AppStorage("menushelf_ask_browsers") private var browsers: [URL] = []

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

        if browsers.isEmpty {
            browsers = MenuShelfPickerOpener.loadBrowsers(oldBrowsers: browsers)
        } else {
            MenuShelfPickerOpener.ensureShortcutsAssigned(for: browsers)
        }

        showPicker(for: processedUrls)
    }

    private func showPicker(for urls: [URL]) {
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

        window.contentView = NSHostingView(rootView: MenuShelfPickerView(urls: urls))

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
