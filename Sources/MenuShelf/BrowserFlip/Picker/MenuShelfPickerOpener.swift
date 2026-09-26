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
    /// Bundle IDs whose letter was chosen explicitly in Settings rather than
    /// auto-picked. Manual picks are never overwritten by reconciliation as
    /// long as the browser stays visible; hiding a browser clears its manual
    /// flag along with its letter, same as an auto pick.
    @AppStorage("menushelf_ask_shortcuts_manual") static var manualShortcuts: [String: Bool] = [:]

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

        reconcileShortcuts(for: urls)
        return urls
    }

    /// Rebuilds quick keys for exactly this set of browsers, in this order.
    /// Any browser not in the list (hidden, removed, or never tracked) has its
    /// letter released — including a manual pick — so a currently-visible
    /// browser can reclaim it. Manual picks for browsers that ARE in the list
    /// are preserved and reserved first; every other browser is then
    /// auto-assigned the first free letter of its name, in order. Calling
    /// this repeatedly with the same list/order is idempotent — churn only
    /// happens when the visible set or its order actually changes.
    static func ensureShortcutsAssigned(for browsers: [URL]) {
        reconcileShortcuts(for: browsers)
    }

    /// Explicitly pins `letter` as the given browser's quick key, or clears
    /// the pin (falling back to auto-assignment) when `letter` is nil.
    /// `visibleBrowsers` is the current Browser Flip visible/ordered list so
    /// the rest of the set can be reconciled around this pin immediately.
    static func setManualShortcut(bundleID: String, letter: Character?, visibleBrowsers: [URL]) {
        if let letter {
            shortcuts[bundleID] = String(letter).uppercased()
            manualShortcuts[bundleID] = true
        } else {
            manualShortcuts.removeValue(forKey: bundleID)
            shortcuts.removeValue(forKey: bundleID)
        }
        reconcileShortcuts(for: visibleBrowsers)
    }

    private static func reconcileShortcuts(for browsers: [URL]) {
        let resolved: [(id: String, name: String)] = browsers.compactMap { url in
            guard let bundle = Bundle(url: url), let id = bundle.bundleIdentifier else { return nil }
            let name = (bundle.infoDictionary?["CFBundleName"] as? String)
                ?? url.deletingPathExtension().lastPathComponent
            return (id, name)
        }
        let presentIDs = Set(resolved.map(\.id))

        var manual = manualShortcuts.filter { presentIDs.contains($0.key) }
        var next: [String: String] = [:]
        var used = Set<String>()

        for (id, _) in resolved where manual[id] == true {
            guard let letter = shortcuts[id] else {
                manual.removeValue(forKey: id)
                continue
            }
            next[id] = letter
            used.insert(letter)
        }

        for (id, name) in resolved where next[id] == nil {
            for raw in name {
                let upper = String(raw).uppercased()
                guard let scalar = upper.unicodeScalars.first,
                      CharacterSet.uppercaseLetters.contains(scalar),
                      !used.contains(upper) else { continue }
                next[id] = upper
                used.insert(upper)
                break
            }
        }

        if next != shortcuts {
            shortcuts = next
        }
        if manual != manualShortcuts {
            manualShortcuts = manual
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
