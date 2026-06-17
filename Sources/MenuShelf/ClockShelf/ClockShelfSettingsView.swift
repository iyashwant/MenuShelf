//
//  WorldClockSettingsView.swift
//  MenuShelf
//
//  Settings pane for the World Clock feature. Mirrors the structure of
//  `ClipboardShelfSettingsView`: a single scrolling pane built from
//  `SettingsCard`/`SettingsToggle`/`SettingsRow`. All bindings flow
//  through `store.updateWorldClockSettings { ... }` except the popup
//  hotkey, which is owned by `KeyboardShortcuts` and bound by
//  `KeyboardShortcuts.Recorder`.
//

import AppKit
import KeyboardShortcuts
import SwiftUI

struct WorldClockSettingsView: View {
    @EnvironmentObject private var store: PreferencesStore

    /// Drives the time-zone picker sheet. Holds either `.add` (the
    /// footer "Add Clock" button) or `.change(UUID)` (the per-row
    /// "Time zone" button).
    @State private var sheetMode: TimeZoneSheetMode?

    var body: some View {
        SettingsPane(
            "World Clock",
            subtitle: "Multi-time-zone clocks in your menu bar."
        ) {
            enableCard

            if store.settings.resolvedWorldClock.enableWorldClock {
                clocksCard
                appearanceCard
                hotkeyCard
            }
        }
        .sheet(item: $sheetMode) { mode in
            TimeZonePickerSheet(mode: mode) { identifier in
                switch mode {
                case .add:
                    store.addWorldClock(timeZoneIdentifier: identifier)
                case .change(let id):
                    if var clock = store.settings.resolvedWorldClock
                        .clocks.first(where: { $0.id == id }) {
                        clock.timeZoneIdentifier = identifier
                        store.updateWorldClock(clock)
                    }
                }
                sheetMode = nil
            } onCancel: {
                sheetMode = nil
            }
        }
    }

    // MARK: - Cards

    private var enableCard: some View {
        SettingsCard("World Clock") {
            SettingsToggle(
                "Enable World Clock",
                helper: "Show the World Clock popover, populate menu views that have a World Clock entry, and pin status items for any pinned clocks.",
                isOn: Binding(
                    get: { store.settings.resolvedWorldClock.enableWorldClock },
                    set: { store.setEnableWorldClock($0) }
                )
            )
        }
    }

    private var clocksCard: some View {
        SettingsCard(
            "Clocks",
            footer: "Drag rows to reorder. Pinned clocks appear as menu bar icons; visible clocks appear in the popover."
        ) {
            SettingsBlockRow {
                if sortedClocks.isEmpty {
                    Text("No clocks configured. Use the Add Clock button below to add one.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    ScrollViewReader { proxy in
                        List {
                            ForEach(sortedClocks) { clock in
                                ClockRow(
                                    clock: clock,
                                    onChangeTimeZone: { sheetMode = .change(clock.id) },
                                    onRemove: { store.removeWorldClock(id: clock.id) },
                                    onUpdate: { store.updateWorldClock($0) }
                                )
                                .id(clock.id)
                            }
                            .onMove { source, destination in
                                store.moveWorldClock(from: source, to: destination)
                            }
                        }
                        .listStyle(.inset)
                        .frame(minHeight: 220, maxHeight: 380)
                        .onReceive(
                            NotificationCenter.default.publisher(
                                for: .menuShelfScrollToWorldClock
                            )
                        ) { notification in
                            // Triggered by
                            // `SettingsWindowController.show(scrollToClockID:)`
                            // when the row context menu's "Edit…" item
                            // is invoked from the popover. Scroll the
                            // matching row into view so the user lands
                            // on the clock they right-clicked.
                            guard let id = notification.userInfo?["clockID"] as? UUID,
                                  sortedClocks.contains(where: { $0.id == id })
                            else { return }
                            withAnimation {
                                proxy.scrollTo(id, anchor: .center)
                            }
                        }
                    }
                }

                HStack {
                    Button {
                        sheetMode = .add
                    } label: {
                        Label("Add Clock", systemImage: "plus")
                    }
                    .controlSize(.small)
                    .disabled(sortedClocks.count >= 32)

                    if sortedClocks.count >= 32 {
                        Text("Up to 32 clocks supported.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()
                }
            }
        }
    }

    private var appearanceCard: some View {
        SettingsCard("Appearance") {
            SettingsRow(
                "Menu Surface",
                helper: "Where the World Clock surfaces inside menu views. Popover shows a single click target; Submenu lists clocks inline."
            ) {
                Picker("", selection: Binding(
                    get: { store.settings.resolvedWorldClock.resolvedPresentationMode },
                    set: { value in
                        store.updateWorldClockSettings { $0.presentationMode = value }
                    }
                )) {
                    ForEach(WorldClockPresentationMode.allCases) { mode in
                        Text(mode.label).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 200)
            }

            SettingsToggle(
                "Use 24-hour time",
                helper: "Format pinned status item titles, popover rows, and submenu rows in 24-hour time regardless of the system locale.",
                isOn: Binding(
                    get: { store.settings.resolvedWorldClock.use24HourTime },
                    set: { value in
                        store.updateWorldClockSettings { $0.use24HourTime = value }
                    }
                )
            )

            SettingsRow(
                "Popover text size",
                helper: "Point size of clock rows in the World Clock popover (11-22 pt)."
            ) {
                Stepper(
                    value: popoverTextSizeBinding,
                    in: 11...22
                ) {
                    Text("\(store.settings.resolvedWorldClock.resolvedPopoverTextSize)")
                }
            }
        }
    }

    private var hotkeyCard: some View {
        SettingsCard("Hotkey") {
            SettingsRow(
                "Open popover hotkey",
                helper: "Press to toggle the World Clock popover from anywhere."
            ) {
                KeyboardShortcuts.Recorder(for: .worldClockPopup)
            }

            if let conflict = currentConflict {
                SettingsBlockRow {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Hotkey conflicts with \(conflict.ownerName).")
                                .font(.callout.weight(.semibold))
                            Text("Both shortcuts will fire at the same time. Pick a different chord or update the conflicting owner.")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer()
                    }
                }
            }
        }
    }

    // MARK: - Helpers

    private var sortedClocks: [ClockConfig] {
        store.settings.resolvedWorldClock.clocks
            .sorted { $0.sortOrder < $1.sortOrder }
    }

    private var popoverTextSizeBinding: Binding<Int> {
        Binding(
            get: { store.settings.resolvedWorldClock.resolvedPopoverTextSize },
            set: { value in
                let clamped = min(max(value, 11), 22)
                store.updateWorldClockSettings { $0.popoverTextSize = clamped }
            }
        )
    }

    /// Detect a `(keyCode, modifierFlags)` collision between the recorded
    /// World Clock popover hotkey and any menu view, standalone module, or
    /// the Clipboard Shelf popup hotkey. Delegates to the shared
    /// `StandaloneModuleHotkeyConflict.scan(...)` helper so the world-clock
    /// banner and the standalone-modules banner stay in lockstep.
    ///
    /// The World Clock popup itself is excluded from `knownPopupHotkeys` so
    /// it does not report itself (Requirement 8.5).
    private var currentConflict: StandaloneModuleHotkeyConflict? {
        guard let recorded = KeyboardShortcuts.getShortcut(for: .worldClockPopup),
              let recordedKey = recorded.key?.rawValue else {
            return nil
        }
        let recordedConfig = KeyboardShortcutConfig(
            isEnabled: true,
            keyEquivalent: "",
            modifierFlags: recorded.modifiers.rawValue,
            keyCode: UInt16(recordedKey)
        )

        var knownPopups: [StandaloneModuleHotkeyConflict.KnownPopupHotkey] = []
        if let popup = KeyboardShortcuts.getShortcut(for: .popup),
           let popupKey = popup.key?.rawValue {
            knownPopups.append(.clipboardShelfPopup(
                keyCode: UInt16(popupKey),
                modifierFlags: popup.modifiers.rawValue
            ))
        }
        if let bookmark = KeyboardShortcuts.getShortcut(for: .bookmarkShelfPopup),
           let bookmarkKey = bookmark.key?.rawValue {
            knownPopups.append(.bookmarkShelfPopup(
                keyCode: UInt16(bookmarkKey),
                modifierFlags: bookmark.modifiers.rawValue
            ))
        }

        return StandaloneModuleHotkeyConflict.scan(
            recorded: recordedConfig,
            currentEntryID: nil,
            menuViews: store.settings.resolvedMenuViews,
            standaloneModules: store.settings.resolvedStandaloneModules,
            knownPopupHotkeys: knownPopups
        )
    }
}

// MARK: - Sheet mode

/// Identifies whether the time-zone picker sheet is currently being used
/// to add a new clock or to retarget an existing one.
private enum TimeZoneSheetMode: Identifiable, Equatable {
    case add
    case change(UUID)

    var id: String {
        switch self {
        case .add: "add"
        case .change(let id): "change-\(id.uuidString)"
        }
    }
}

// MARK: - Clock row

private struct ClockRow: View {
    let clock: ClockConfig
    let onChangeTimeZone: () -> Void
    let onRemove: () -> Void
    let onUpdate: (ClockConfig) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                TextField("🌐", text: emojiBinding)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 48)
                    .help("Single-character emoji shown in the popover and submenu.")

                TextField("Label", text: labelBinding)
                    .textFieldStyle(.roundedBorder)

                Button {
                    onChangeTimeZone()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "globe")
                        Text(clock.timeZoneIdentifier)
                            .lineLimit(1)
                    }
                }
                .controlSize(.small)
                .help("Change the time zone for this clock.")

                Button(role: .destructive) {
                    onRemove()
                } label: {
                    Image(systemName: "minus.circle")
                }
                .buttonStyle(.borderless)
                .help("Remove this clock.")
            }

            HStack(spacing: 16) {
                Toggle("Pin to menu bar", isOn: pinToMenuBarBinding)
                    .toggleStyle(.switch)
                    .controlSize(.small)
                Toggle("Show in popover", isOn: showInPopoverBinding)
                    .toggleStyle(.switch)
                    .controlSize(.small)
                Spacer()
            }
        }
        .padding(.vertical, 4)
    }

    // MARK: - Bindings

    private var emojiBinding: Binding<String> {
        Binding(
            get: { clock.emoji ?? "" },
            set: { newValue in
                var updated = clock
                let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
                updated.emoji = trimmed.isEmpty ? nil : String(trimmed.prefix(1))
                onUpdate(updated)
            }
        )
    }

    private var labelBinding: Binding<String> {
        Binding(
            get: { clock.label ?? "" },
            set: { newValue in
                var updated = clock
                updated.label = newValue.isEmpty ? nil : newValue
                onUpdate(updated)
            }
        )
    }

    private var pinToMenuBarBinding: Binding<Bool> {
        Binding(
            get: { clock.pinToMenuBar },
            set: { newValue in
                var updated = clock
                updated.pinToMenuBar = newValue
                onUpdate(updated)
            }
        )
    }

    private var showInPopoverBinding: Binding<Bool> {
        Binding(
            get: { clock.showInPopover },
            set: { newValue in
                var updated = clock
                updated.showInPopover = newValue
                onUpdate(updated)
            }
        )
    }
}

// MARK: - Time zone picker sheet

/// Sheet hosted by `WorldClockSettingsView` that lets the user pick a
/// time zone identifier from `TimeZone.knownTimeZoneIdentifiers`. Reused
/// for both "Add Clock" (footer button) and "Change time zone" (per-row
/// button). The list is populated lazily inside `.task` so the 600+
/// identifier catalog never blocks the settings window when it opens.
private struct TimeZonePickerSheet: View {
    let mode: TimeZoneSheetMode
    let onSelect: (String) -> Void
    let onCancel: () -> Void

    @State private var query: String = ""
    @State private var identifiers: [String] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(headline)
                    .font(.headline)
                Spacer()
                Button("Cancel") { onCancel() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, 16)
            .padding(.top, 16)
            .padding(.bottom, 8)

            SearchField(text: $query, placeholder: "Search time zones")
                .frame(height: 26)
                .padding(.horizontal, 16)
                .padding(.bottom, 8)

            Divider()

            List(filtered, id: \.self) { identifier in
                Button {
                    onSelect(identifier)
                } label: {
                    HStack {
                        Text(identifier)
                            .lineLimit(1)
                        Spacer()
                        Text(offsetLabel(for: identifier))
                            .font(.callout.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .listStyle(.inset)
        }
        .frame(minWidth: 460, minHeight: 420)
        .task {
            if identifiers.isEmpty {
                identifiers = TimeZone.knownTimeZoneIdentifiers.sorted()
            }
        }
    }

    private var headline: String {
        switch mode {
        case .add: "Add Clock"
        case .change: "Change Time Zone"
        }
    }

    private var filtered: [String] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return identifiers }
        return identifiers.filter { $0.range(of: trimmed, options: .caseInsensitive) != nil }
    }

    private func offsetLabel(for identifier: String) -> String {
        guard let zone = TimeZone(identifier: identifier) else { return "" }
        let seconds = zone.secondsFromGMT()
        let sign = seconds >= 0 ? "+" : "-"
        let absSeconds = abs(seconds)
        let hours = absSeconds / 3600
        let minutes = (absSeconds % 3600) / 60
        return String(format: "GMT%@%02d:%02d", sign, hours, minutes)
    }
}

// MARK: - NSSearchField wrapper

/// Thin `NSViewRepresentable` over `NSSearchField` so the picker sheet
/// uses the platform's native filter affordances (history, magnifier
/// glyph, clear button) per Requirement 8.6.
private struct SearchField: NSViewRepresentable {
    @Binding var text: String
    var placeholder: String = ""

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSSearchField {
        let field = NSSearchField()
        field.placeholderString = placeholder
        field.delegate = context.coordinator
        field.target = context.coordinator
        field.action = #selector(Coordinator.searchFieldChanged(_:))
        return field
    }

    func updateNSView(_ nsView: NSSearchField, context: Context) {
        if nsView.stringValue != text {
            nsView.stringValue = text
        }
        nsView.placeholderString = placeholder
    }

    final class Coordinator: NSObject, NSSearchFieldDelegate {
        var parent: SearchField

        init(_ parent: SearchField) {
            self.parent = parent
        }

        @objc func searchFieldChanged(_ sender: NSSearchField) {
            parent.text = sender.stringValue
        }

        func controlTextDidChange(_ obj: Notification) {
            guard let field = obj.object as? NSSearchField else { return }
            parent.text = field.stringValue
        }
    }
}
