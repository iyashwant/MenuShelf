//
//  BrowserFlipSettingsView.swift
//  MenuShelf
//
//  Settings tab for the Browser Flip feature. The `.browserFlip` case in
//  `SettingsTab` and the dispatch that constructs this view stay in
//  SettingsView.swift since they're inside an exhaustive switch.
//

import AppKit
import SwiftUI

struct BrowserFlipSettingsView: View {
    @EnvironmentObject private var store: PreferencesStore
    @AppStorage("menushelf_ask_shortcuts") private var shortcuts: [String: String] = [:]
    @AppStorage("menushelf_ask_shortcuts_manual") private var manualShortcuts: [String: Bool] = [:]

    var body: some View {
        SettingsPane("Browser Flip", subtitle: "Switch your default browser from the menu bar.") {
            SettingsCard("Browser Flip") {
                SettingsToggle(
                    "Enable Browser Flip",
                    helper: "Show a Browsers submenu in the management menu so you can switch your default browser quickly.",
                    isOn: Binding(
                        get: { store.settings.resolvedBrowserFlip.enableBrowserFlip },
                        set: { value in store.setEnableBrowserFlip(value) }
                    )
                )
            }

            if store.settings.resolvedBrowserFlip.enableBrowserFlip {
                SettingsCard("Browsers") {
                    if store.discoveredBrowsers.isEmpty {
                        SettingsBlockRow {
                            Text("No browsers discovered yet. Click Refresh to find installed browsers.")
                                .foregroundStyle(.secondary)
                        }
                    } else {
                        List {
                            ForEach(store.discoveredBrowsers) { browser in
                                HStack(spacing: 10) {
                                    Image(nsImage: browserIcon(browser))
                                        .resizable()
                                        .scaledToFit()
                                        .frame(width: 18, height: 18)

                                    Text(MenuBuilder.isAskEverytime(browser) ? "Ask Everytime" : browser.name)
                                        .lineLimit(1)

                                    Spacer()

                                    if browser.id == store.currentDefaultBrowserID {
                                        Text("Default")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }

                                    if browser.isVisible, !MenuBuilder.isAskEverytime(browser) {
                                        shortcutMenu(for: browser)
                                    }

                                    Toggle("", isOn: Binding(
                                        get: { browser.isVisible },
                                        set: { _ in store.setBrowserVisible(browser, visible: !browser.isVisible) }
                                    ))
                                    .toggleStyle(.switch)
                                    .labelsHidden()
                                }
                                .padding(.vertical, 2)
                            }
                            .onMove { source, destination in
                                store.moveBrowser(from: source, to: destination)
                            }
                        }
                        .frame(minHeight: CGFloat(store.discoveredBrowsers.count) * 32 + 16, maxHeight: 300)
                    }

                    SettingsBlockRow {
                        HStack(spacing: 10) {
                            Button("Refresh Browsers") {
                                store.refreshBrowsers()
                            }

                            Button("Reset Hidden") {
                                store.resetHiddenBrowsers()
                            }

                            Spacer()
                        }
                    }
                }

                SettingsCard("Current Default") {
                    SettingsBlockRow {
                        HStack(spacing: 10) {
                            if let name = DefaultBrowserService.shared.currentDefaultBrowserName() {
                                Text(name)
                                    .lineLimit(1)
                            } else {
                                Text("Unknown")
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }

                            Spacer()

                            Button("Refresh") {
                                store.currentDefaultBrowserID = DefaultBrowserService.shared.currentDefaultBrowserID()
                            }
                        }
                    }
                }
            }
        }
    }

    private func browserIcon(_ browser: BrowserInfo) -> NSImage {
        let icon = NSWorkspace.shared.icon(forFile: browser.appURL.path)
        icon.size = NSSize(width: 18, height: 18)
        return icon
    }

    /// Shows the browser's current "Ask Everytime" quick key and lets the
    /// user pin a different one, or hand it back to auto-assignment. Only
    /// shown for visible browsers — a hidden browser has no quick key since
    /// hiding it releases the letter for others to claim.
    @ViewBuilder
    private func shortcutMenu(for browser: BrowserInfo) -> some View {
        let isManual = manualShortcuts[browser.id] == true
        Menu {
            Button {
                store.setBrowserShortcut(browser, letter: nil)
            } label: {
                if !isManual {
                    Label("Automatic", systemImage: "checkmark")
                } else {
                    Text("Automatic")
                }
            }

            Divider()

            ForEach(selectableLetters(for: browser), id: \.self) { letter in
                let isCurrent = shortcuts[browser.id]?.uppercased() == String(letter)
                Button {
                    store.setBrowserShortcut(browser, letter: letter)
                } label: {
                    if isCurrent {
                        Label(String(letter), systemImage: "checkmark")
                    } else {
                        Text(String(letter))
                    }
                }
            }
        } label: {
            Text(shortcuts[browser.id] ?? "–")
                .font(.caption.monospaced())
                .frame(minWidth: 14)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Quick key used to pick \(browser.name) from the \"Ask Everytime\" picker.")
    }

    /// All A–Z letters not already claimed by another currently-visible
    /// browser. Includes this browser's own current letter (if any), since
    /// re-picking it is harmless.
    private func selectableLetters(for browser: BrowserInfo) -> [Character] {
        let usedByOthers = Set(
            store.discoveredBrowsers
                .filter { $0.isVisible && $0.id != browser.id }
                .compactMap { shortcuts[$0.id]?.uppercased().first }
        )
        return (UInt8(ascii: "A")...UInt8(ascii: "Z")).compactMap { code in
            let letter = Character(UnicodeScalar(code))
            return usedByOthers.contains(letter) ? nil : letter
        }
    }
}
