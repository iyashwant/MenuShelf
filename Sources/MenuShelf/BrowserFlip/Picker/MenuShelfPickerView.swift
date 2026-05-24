//
//  MenuShelfPickerView.swift
//  MenuShelf
//
//  The "Ask Everytime" picker UI. Ported from Browserino's PromptView (MIT)
//  via the BrowserFlip port. Self-contained — no Browser Flip dependency.
//

import AppKit
import SwiftUI

private extension Array where Element: Codable {
    static var emptyEncoded: String { "[]" }
}

extension Array: @retroactive RawRepresentable where Element: Codable {
    public init?(rawValue: String) {
        guard let data = rawValue.data(using: .utf8),
              let result = try? JSONDecoder().decode([Element].self, from: data) else { return nil }
        self = result
    }
    public var rawValue: String {
        guard let data = try? JSONEncoder().encode(self),
              let result = String(data: data, encoding: .utf8) else { return "[]" }
        return result
    }
}

extension Dictionary: @retroactive RawRepresentable where Key == String, Value: Codable {
    public init?(rawValue: String) {
        guard let data = rawValue.data(using: .utf8),
              let result = try? JSONDecoder().decode(Self.self, from: data) else { return nil }
        self = result
    }
    public var rawValue: String {
        guard let data = try? JSONEncoder().encode(self),
              let result = String(data: data, encoding: .utf8) else { return "{}" }
        return result
    }
}

struct MenuShelfPickerItem: View {
    var browser: URL
    var bundle: Bundle
    var shortcut: String?
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack {
                Text(bundle.infoDictionary?["CFBundleName"] as? String ?? browser.deletingPathExtension().lastPathComponent)
                    .font(.system(size: 12, weight: .bold))

                Spacer()

                if let shortcut {
                    Text(shortcut)
                        .font(.caption)
                        .frame(minWidth: 4)
                        .opacity(0.5)
                        .padding(5)
                        .background(Color.secondary.opacity(0.2))
                        .cornerRadius(4)
                }

                Spacer().frame(width: 8)

                Image(nsImage: NSWorkspace.shared.icon(forFile: bundle.bundlePath))
                    .resizable()
                    .frame(width: 24, height: 24)
            }
            .padding(8)
        }
        .msIf(shortcut?.lowercased().first != nil) {
            // `msIf`'s condition guarantees a non-nil first character; resolve
            // it once here so we can avoid force unwraps in the closure.
            let key: KeyEquivalent = shortcut?.lowercased().first.map { KeyEquivalent($0) } ?? KeyEquivalent(" ")
            return $0.keyboardShortcut(key, modifiers: [.shift])
                .background {
                    Button(action: action) {}
                        .opacity(0)
                        .keyboardShortcut(key, modifiers: [])
                }
        }
    }
}

struct MenuShelfPickerView: View {
    @AppStorage("menushelf_ask_browsers") private var browsers: [URL] = []
    @AppStorage("menushelf_ask_hiddenBrowsers") private var hiddenBrowsers: [URL] = []
    @AppStorage("menushelf_ask_shortcuts") private var shortcuts: [String: String] = [:]

    let urls: [URL]

    @State private var opacityAnimation = 0.0
    @State private var selected = 0
    @FocusState private var focused: Bool

    var visibleBrowsers: [URL] {
        browsers.filter { !hiddenBrowsers.contains($0) }
    }

    var body: some View {
        VStack {
            ScrollViewReader { scrollViewProxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(visibleBrowsers.enumerated()), id: \.offset) { index, browser in
                            if let bundle = Bundle(url: browser) {
                                MenuShelfPickerItem(
                                    browser: browser,
                                    bundle: bundle,
                                    shortcut: shortcuts[bundle.bundleIdentifier ?? ""]
                                ) {
                                    MenuShelfPickerOpener.openURL(
                                        urls,
                                        app: browser,
                                        isIncognito: NSEvent.modifierFlags.contains(.shift)
                                    )
                                    NSApplication.shared.keyWindow?.close()
                                }
                                .id(index)
                                .buttonStyle(MSSelectButtonStyle(selected: selected == index))
                            }
                        }
                    }
                }
                .focusable()
                .focused($focused)
                .onMoveCommand { command in
                    if command == .up {
                        selected = max(0, selected - 1)
                        scrollViewProxy.scrollTo(selected, anchor: .center)
                    } else if command == .down {
                        selected = min(visibleBrowsers.count - 1, selected + 1)
                        scrollViewProxy.scrollTo(selected, anchor: .center)
                    }
                }
                .background {
                    Button(action: {
                        guard selected < visibleBrowsers.count else { return }
                        MenuShelfPickerOpener.openURL(
                            urls,
                            app: visibleBrowsers[selected],
                            isIncognito: false
                        )
                        NSApplication.shared.keyWindow?.close()
                    }) {}
                    .opacity(0)
                    .keyboardShortcut(.defaultAction)

                    Button(action: {
                        guard selected < visibleBrowsers.count else { return }
                        MenuShelfPickerOpener.openURL(
                            urls,
                            app: visibleBrowsers[selected],
                            isIncognito: true
                        )
                        NSApplication.shared.keyWindow?.close()
                    }) {}
                    .opacity(0)
                    .keyboardShortcut(.return, modifiers: [.shift])

                    Button(action: {
                        NSApplication.shared.keyWindow?.close()
                    }) {}
                    .opacity(0)
                    .keyboardShortcut(.cancelAction)
                }
                .onAppear {
                    focused.toggle()
                    withAnimation(.interactiveSpring(duration: 0.3)) {
                        opacityAnimation = 1
                    }
                }
            }

            Divider()

            if let host = urls.first?.host() {
                Button(action: {
                    let pasteboard = NSPasteboard.general
                    pasteboard.declareTypes([.string], owner: nil)
                    pasteboard.setString(urls.first?.absoluteString ?? "", forType: .string)
                }) {
                    Text(host)
                }
                .buttonStyle(.plain)
                .keyboardShortcut(KeyEquivalent("c"), modifiers: [.command, .option])
                .msToolTip(urls.first?.absoluteString ?? "")
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(MenuShelfBlurredView())
        .opacity(opacityAnimation)
        .edgesIgnoringSafeArea(.all)
    }
}
