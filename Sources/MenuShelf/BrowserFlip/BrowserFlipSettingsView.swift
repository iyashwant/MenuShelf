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
}
