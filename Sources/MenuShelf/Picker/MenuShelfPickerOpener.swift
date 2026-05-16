//
//  MenuShelfPickerOpener.swift
//  MenuShelf
//
//  Discovers installed browsers (excluding MenuShelf itself) and opens URLs
//  in the chosen browser. Ported from Browserino's BrowserUtil. MIT.
//

import AppKit
import Foundation
import SwiftUI

enum MenuShelfPickerOpener {
    @AppStorage("menushelf_ask_privateArgs") private static var privateArgs: [String: String] = [:]
    @AppStorage("menushelf_ask_shortcuts") static var shortcuts: [String: String] = [:]

    static func loadBrowsers(oldBrowsers: [URL]) -> [URL] {
        guard let probe = URL(string: "https:") else { return [] }

        var urls = NSWorkspace.shared.urlsForApplications(toOpen: probe)

        // Don't show MenuShelf itself in its own picker.
        if let bundleID = Bundle.main.bundleIdentifier,
           let me = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            urls.removeAll { $0 == me }
        }

        // Always include Safari.
        if let safari = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Safari"),
           !urls.contains(safari) {
            urls.append(safari)
        }

        // Preserve previous user-defined ordering.
        var oldPositions: [URL: Int] = [:]
        for (index, browser) in oldBrowsers.enumerated() {
            oldPositions[browser] = index
        }

        urls.sort { a, b in
            if let pa = oldPositions[a], let pb = oldPositions[b] {
                return pa < pb
            } else if oldPositions[a] != nil {
                return true
            } else if oldPositions[b] != nil {
                return false
            }
            return true
        }

        autoAssignShortcuts(for: urls)
        return urls
    }

    static func ensureShortcutsAssigned(for browsers: [URL]) {
        autoAssignShortcuts(for: browsers)
    }

    private static func autoAssignShortcuts(for browsers: [URL]) {
        var current = shortcuts
        var used = Set(current.values.map { $0.uppercased() })

        for browser in browsers {
            guard let bundle = Bundle(url: browser),
                  let bundleID = bundle.bundleIdentifier,
                  current[bundleID] == nil else { continue }

            let name = (bundle.infoDictionary?["CFBundleName"] as? String)
                ?? browser.deletingPathExtension().lastPathComponent

            for raw in name {
                let upper = String(raw).uppercased()
                guard let scalar = upper.unicodeScalars.first,
                      CharacterSet.uppercaseLetters.contains(scalar),
                      !used.contains(upper) else { continue }
                current[bundleID] = upper
                used.insert(upper)
                break
            }
        }

        if current != shortcuts {
            shortcuts = current
        }
    }

    static func openURL(_ urls: [URL], app: URL, isIncognito: Bool) {
        guard let bundle = Bundle(url: app) else { return }
        let configuration = NSWorkspace.OpenConfiguration()

        if isIncognito,
           let bundleID = bundle.bundleIdentifier,
           let privateArg = privateArgs[bundleID] {
            configuration.createsNewApplicationInstance = true
            configuration.arguments = [privateArg] + urls.map(\.absoluteString)
        }

        NSWorkspace.shared.open(
            isIncognito ? [] : urls,
            withApplicationAt: app,
            configuration: configuration
        )
    }
}
