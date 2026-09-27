//
//  ClipboardShelfSettingsView.swift
//  MenuShelf
//
//  Settings pane for the Clipboard Shelf feature. Mirrors the structure of
//  `BrowserFlipSettingsView`: a single scrolling pane built from
//  `SettingsCard`/`SettingsToggle`/`SettingsRow`/`SettingsBlockRow`. All
//  bindings flow through `store.updateClipboardShelfSettings { ... }`
//  except the popup hotkey, which is owned by the vendored
//  `KeyboardShortcuts` package and bound by `KeyboardShortcuts.Recorder`.
//

import AppKit
import KeyboardShortcuts
import SwiftUI

struct ClipboardShelfSettingsView: View {
    @EnvironmentObject private var store: PreferencesStore

    var body: some View {
        SettingsPane(
            "Clipboard Shelf",
            subtitle: "Save your clipboard history to a fast searchable popup."
        ) {
            enableCard
            if store.settings.resolvedClipboardShelf.enableClipboardShelf {
                appearanceCard
                hotkeyCard
                behaviorCard
                captureCard
                screenshotsCard
                popupCard
                ignoreCard
                storageCard
            }
        }
    }

    // MARK: - Cards

    private var appearanceCard: some View {
        SettingsCard("Appearance") {
            SettingsRow(
                "Menu Surface",
                helper: "Where the Clipboard Shelf surfaces inside menu views. Popover shows a single click target; Submenu lists recent items inline."
            ) {
                Picker("", selection: Binding(
                    get: { store.settings.resolvedClipboardShelf.resolvedPresentationMode },
                    set: { value in
                        store.updateClipboardShelfSettings { $0.presentationMode = value }
                    }
                )) {
                    ForEach(ClipboardShelfPresentationMode.allCases) { mode in
                        Text(mode.label).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }
        }
    }

    private var enableCard: some View {
        SettingsCard("Clipboard Shelf") {
            SettingsToggle(
                "Enable Clipboard Shelf",
                helper: "Polls the system pasteboard while enabled and surfaces the popup from any menu view that has a Clipboard Shelf entry.",
                isOn: Binding(
                    get: { store.settings.resolvedClipboardShelf.enableClipboardShelf },
                    set: { store.setEnableClipboardShelf($0) }
                )
            )
        }
    }

    private var hotkeyCard: some View {
        SettingsCard("Hotkey") {
            SettingsRow(
                "Open popup hotkey",
                helper: "Press to toggle the Clipboard Shelf popup."
            ) {
                KeyboardShortcuts.Recorder(for: .popup)
            }
        }
    }

    private var behaviorCard: some View {
        SettingsCard("Behavior") {
            SettingsRow("Sort by") {
                Picker("", selection: clipboardSettingsBinding(\.sortBy)) {
                    ForEach(ClipboardShelfSortKey.allCases) { key in
                        Text(key.label).tag(key)
                    }
                }
                .labelsHidden()
            }

            SettingsRow("Search mode") {
                Picker("", selection: clipboardSettingsBinding(\.searchMode)) {
                    ForEach(ClipboardShelfSearchMode.allCases) { mode in
                        Text(mode.label).tag(mode)
                    }
                }
                .labelsHidden()
            }

            SettingsToggle(
                "Paste by default",
                helper: "Activating an item pastes it into the previously focused app. Off means copy only.",
                isOn: clipboardSettingsBinding(\.pasteByDefault)
            )

            SettingsToggle(
                "Remove formatting by default",
                helper: "Strip rich-text formatting before paste or copy.",
                isOn: clipboardSettingsBinding(\.removeFormattingByDefault)
            )

            SettingsRow("Pin to") {
                Picker("", selection: clipboardSettingsBinding(\.pinTo)) {
                    ForEach(ClipboardShelfPinPosition.allCases) { position in
                        Text(position.label).tag(position)
                    }
                }
                .labelsHidden()
            }

            SettingsRow(
                "Number of hotkey rows",
                helper: "How many rows are reachable via ⌘1-⌘9 in the popup. 0 disables row hotkeys."
            ) {
                Stepper(
                    value: clipboardSettingsBinding(\.numberOfUsableHotKey, clamping: 0...50),
                    in: 0...50
                ) {
                    Text("\(store.settings.resolvedClipboardShelf.numberOfUsableHotKey)")
                }
            }

            SettingsRow(
                "Paste delay (ms)",
                helper: "Milliseconds to wait before posting the synthetic ⌘V."
            ) {
                Stepper(
                    value: clipboardSettingsBinding(\.pasteDelayMs, clamping: 0...1000),
                    in: 0...1000,
                    step: 10
                ) {
                    Text("\(store.settings.resolvedClipboardShelf.pasteDelayMs)")
                }
            }

            SettingsToggle(
                "Reduce animations in the popup",
                isOn: clipboardSettingsBinding(\.reduceAnimations)
            )

            SettingsToggle(
                "Clear non-pinned history on quit",
                isOn: clipboardSettingsBinding(\.clearOnQuit)
            )

            SettingsToggle(
                "Also clear pinned items on quit",
                isOn: clipboardSettingsBinding(\.clearPinnedOnQuit)
            )

            SettingsToggle(
                "Pause clipboard capture",
                helper: "Stop recording new copies until you toggle this off.",
                isOn: clipboardSettingsBinding(\.ignoreEvents)
            )
        }
    }

    private var captureCard: some View {
        SettingsCard("Capture") {
            SettingsRow(
                "History size",
                helper: "Maximum non-pinned items kept on disk. Pinned items are never evicted."
            ) {
                Stepper(
                    value: clipboardSettingsBinding(\.size, clamping: 1...1000),
                    in: 1...1000,
                    step: 10
                ) {
                    Text("\(store.settings.resolvedClipboardShelf.size)")
                }
            }

            SettingsRow(
                "Polling interval (s)",
                helper: "How often to read the system pasteboard. Smaller values capture faster but use more CPU."
            ) {
                Stepper(
                    value: clipboardCheckIntervalBinding,
                    in: 0.1...5.0,
                    step: 0.1,
                    format: .number.precision(.fractionLength(1))
                ) {
                    Text(String(format: "%.1f", store.settings.resolvedClipboardShelf.clipboardCheckInterval))
                }
            }

            SettingsBlockRow {
                Text("Pasteboard types to capture")
                    .font(.subheadline)
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], alignment: .leading) {
                    ForEach(supportedPasteboardTypes, id: \.0) { item in
                        Toggle(item.1, isOn: pasteboardTypeBinding(rawValue: item.0))
                            .toggleStyle(.checkbox)
                    }
                }
            }
        }
    }

    private var screenshotsCard: some View {
        let settings = store.settings.resolvedClipboardShelf
        let systemFolder = ClipboardShelfScreenshots.systemScreenshotFolder()
        let hasSystemFolder = settings.resolvedScreenshotFolders.contains { isSameFolder($0.path, systemFolder.path) }
        let days = settings.resolvedScreenshotMaxAgeDays

        return SettingsCard("Screenshots") {
            SettingsToggle(
                "Show recent screenshots",
                helper: "Images saved in these folders appear in the popup next to copied items. They aren't added to your clipboard history and can't be deleted from the popup.",
                isOn: Binding(
                    get: { settings.resolvedShowScreenshots },
                    set: { setShowScreenshots($0, systemFolder: systemFolder) }
                )
            )

            if settings.resolvedShowScreenshots {
                SettingsBlockRow {
                    Text("Folders")
                        .font(.subheadline)

                    ForEach(settings.resolvedScreenshotFolders) { folder in
                        screenshotFolderRow(folder, isSystemFolder: isSameFolder(folder.path, systemFolder.path))
                    }

                    if !hasSystemFolder {
                        HStack(spacing: 8) {
                            Text("macOS saves screenshots to \(abbreviatedPath(systemFolder.path)).")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Spacer()
                            Button("Add") {
                                addScreenshotFolder(startingAt: systemFolder)
                            }
                        }
                    }

                    HStack {
                        Button("Add Folder…") {
                            addScreenshotFolder(startingAt: nil)
                        }
                        Spacer()
                    }
                }

                SettingsRow(
                    "Show images from the last",
                    helper: "Older images drop out of the popup. They stay in their folders."
                ) {
                    Stepper(
                        value: Binding(
                            get: { days },
                            set: { value in store.updateClipboardShelfSettings { $0.screenshotMaxAgeDays = value } }
                        ),
                        in: ClipboardShelfSettings.screenshotMaxAgeRange
                    ) {
                        Text(days == 1 ? "1 day" : "\(days) days")
                    }
                }
            }
        }
    }

    private func screenshotFolderRow(_ folder: ClipboardShelfScreenshotFolder, isSystemFolder: Bool) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "folder")
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(folder.displayName)
                Text(isSystemFolder ? "macOS screenshot folder · \(abbreviatedPath(folder.path))" : abbreviatedPath(folder.path))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            Button {
                store.updateClipboardShelfSettings { settings in
                    settings.screenshotFolders = settings.resolvedScreenshotFolders.filter { $0.id != folder.id }
                }
            } label: {
                Image(systemName: "minus.circle")
            }
            .buttonStyle(.borderless)
            .help("Stop showing images from this folder")
        }
    }

    /// Turning the feature on with no folders asks for the macOS screenshot
    /// folder first, and stays off if the user cancels.
    private func setShowScreenshots(_ isOn: Bool, systemFolder: URL) {
        guard isOn, store.settings.resolvedClipboardShelf.resolvedScreenshotFolders.isEmpty else {
            store.updateClipboardShelfSettings { $0.showScreenshots = isOn }
            return
        }
        addScreenshotFolder(startingAt: systemFolder)
    }

    private func addScreenshotFolder(startingAt folder: URL?) {
        guard let added = ClipboardShelfScreenshots.requestAccess(to: folder, reusing: store.settings.folders) else {
            return
        }
        store.updateClipboardShelfSettings { settings in
            var folders = settings.resolvedScreenshotFolders
            if !folders.contains(where: { isSameFolder($0.path, added.path) }) {
                folders.append(added)
            }
            settings.screenshotFolders = folders
            settings.showScreenshots = true
        }
    }

    private func isSameFolder(_ lhs: String, _ rhs: String) -> Bool {
        let standardized = { (path: String) in
            URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
        }
        return standardized(lhs) == standardized(rhs)
    }

    private func abbreviatedPath(_ path: String) -> String {
        let home = ClipboardShelfScreenshots.realHomeDirectory.path
        return path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
    }

    private var popupCard: some View {
        SettingsCard("Popup") {
            SettingsRow("Open at") {
                Picker("", selection: clipboardSettingsBinding(\.popupPosition)) {
                    ForEach(ClipboardShelfPopupPosition.allCases) { position in
                        Text(position.label).tag(position)
                    }
                }
                .labelsHidden()
            }

            SettingsRow("Window width") {
                Stepper(
                    value: popupWidthBinding,
                    in: 200...1200,
                    step: 10
                ) {
                    Text("\(Int(store.settings.resolvedClipboardShelf.popupSize.width))")
                }
            }
        }
    }

    private var ignoreCard: some View {
        SettingsCard("Ignored apps and patterns") {
            SettingsBlockRow {
                Text("Ignored bundle identifiers")
                    .font(.subheadline)
                Text("Comma-separated list of app bundle identifiers whose copies should be skipped (e.g. com.agilebits.onepassword7).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                TextEditor(text: ignoredAppsBinding)
                    .font(.system(.body, design: .monospaced))
                    .frame(minHeight: 60, maxHeight: 120)
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .strokeBorder(Color(nsColor: .separatorColor))
                    )
            }

            SettingsBlockRow {
                Text("Ignored regular expressions")
                    .font(.subheadline)
                Text("One regular expression per line. Strings matching any pattern are not recorded.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                TextEditor(text: ignoredRegexBinding)
                    .font(.system(.body, design: .monospaced))
                    .frame(minHeight: 60, maxHeight: 120)
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .strokeBorder(Color(nsColor: .separatorColor))
                    )
            }
        }
    }

    private var storageCard: some View {
        SettingsCard("Storage") {
            SettingsRow(
                "Database",
                helper: "Stored at ~/Library/Application Support/MenuShelf/ClipboardShelf.sqlite."
            ) {
                Text(formattedDatabaseSize)
                    .foregroundStyle(.secondary)
            }

            SettingsBlockRow {
                HStack(spacing: 10) {
                    Button("Clear History…") {
                        confirmClear(includingPinned: false)
                    }

                    Button("Clear All (incl. pinned)…") {
                        confirmClear(includingPinned: true)
                    }

                    Spacer()
                }
            }
        }
    }

    // MARK: - Helpers

    private var supportedPasteboardTypes: [(String, String)] {
        [
            ("public.utf8-plain-text", "Plain text"),
            ("public.rtf", "RTF"),
            ("public.html", "HTML"),
            ("public.png", "PNG"),
            ("public.tiff", "TIFF"),
            ("public.file-url", "File URL")
        ]
    }

    private var formattedDatabaseSize: String {
        let url = URL.applicationSupportDirectory.appending(path: "MenuShelf/ClipboardShelf.sqlite")
        guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).allValues.first?.value as? Int64 else {
            return "Empty"
        }
        return ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
    }

    private func clipboardSettingsBinding<Value>(_ keyPath: WritableKeyPath<ClipboardShelfSettings, Value>) -> Binding<Value> {
        Binding(
            get: { store.settings.resolvedClipboardShelf[keyPath: keyPath] },
            set: { newValue in
                store.updateClipboardShelfSettings { $0[keyPath: keyPath] = newValue }
            }
        )
    }

    private func clipboardSettingsBinding<Value: Comparable>(
        _ keyPath: WritableKeyPath<ClipboardShelfSettings, Value>,
        clamping range: ClosedRange<Value>
    ) -> Binding<Value> {
        Binding(
            get: { store.settings.resolvedClipboardShelf[keyPath: keyPath] },
            set: { newValue in
                let clamped = min(max(newValue, range.lowerBound), range.upperBound)
                store.updateClipboardShelfSettings { $0[keyPath: keyPath] = clamped }
            }
        )
    }

    private var clipboardCheckIntervalBinding: Binding<Double> {
        Binding(
            get: { store.settings.resolvedClipboardShelf.clipboardCheckInterval },
            set: { newValue in
                let clamped = min(max(newValue, 0.1), 5.0)
                store.updateClipboardShelfSettings { $0.clipboardCheckInterval = clamped }
            }
        )
    }

    private var popupWidthBinding: Binding<Int> {
        Binding(
            get: { Int(store.settings.resolvedClipboardShelf.popupSize.width) },
            set: { newValue in
                let clamped = min(max(newValue, 200), 1200)
                store.updateClipboardShelfSettings {
                    $0.popupSize = CGSize(width: CGFloat(clamped), height: $0.popupSize.height)
                }
            }
        )
    }

    private func pasteboardTypeBinding(rawValue: String) -> Binding<Bool> {
        Binding(
            get: { store.settings.resolvedClipboardShelf.enabledPasteboardTypes.contains(rawValue) },
            set: { newValue in
                store.updateClipboardShelfSettings { settings in
                    var types = settings.enabledPasteboardTypes
                    if newValue {
                        if !types.contains(rawValue) { types.append(rawValue) }
                    } else {
                        types.removeAll { $0 == rawValue }
                    }
                    settings.enabledPasteboardTypes = types
                }
            }
        )
    }

    private var ignoredAppsBinding: Binding<String> {
        Binding(
            get: { store.settings.resolvedClipboardShelf.ignoredApplicationBundleIDs.joined(separator: ", ") },
            set: { newValue in
                let entries = newValue
                    .split(whereSeparator: { $0 == "," || $0 == "\n" })
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }
                store.updateClipboardShelfSettings { $0.ignoredApplicationBundleIDs = entries }
            }
        )
    }

    private var ignoredRegexBinding: Binding<String> {
        Binding(
            get: { store.settings.resolvedClipboardShelf.ignoredRegularExpressions.joined(separator: "\n") },
            set: { newValue in
                let entries = newValue
                    .split(whereSeparator: { $0 == "\n" })
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }
                store.updateClipboardShelfSettings { $0.ignoredRegularExpressions = entries }
            }
        )
    }

    private func confirmClear(includingPinned: Bool) {
        let alert = NSAlert()
        alert.messageText = includingPinned
            ? "Clear all Clipboard Shelf history (including pinned)?"
            : "Clear non-pinned Clipboard Shelf history?"
        alert.informativeText = "This cannot be undone."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Clear")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn {
            store.clearClipboardShelfHistory(includingPinned: includingPinned)
        }
    }
}
