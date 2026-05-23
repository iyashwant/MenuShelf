import AppKit
import SwiftUI

struct StandaloneModulesSettingsView: View {
    @EnvironmentObject private var store: PreferencesStore
    @State private var selection: UUID?
    @State private var pendingScrollID: UUID?

    private var sortedModules: [StandaloneModuleConfig] {
        store.settings.resolvedStandaloneModules
            .sorted { $0.sortOrder < $1.sortOrder }
    }

    var body: some View {
        HSplitView {
            leadingPane
                .frame(minWidth: 240, idealWidth: 280, maxWidth: 340)
                .frame(maxHeight: .infinity)

            detailPane
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onReceive(NotificationCenter.default.publisher(for: .menuShelfScrollToStandaloneModule)) { notification in
            if let id = notification.userInfo?["standaloneModuleID"] as? UUID {
                selection = id
                pendingScrollID = id
            }
        }
    }

    @ViewBuilder
    private var leadingPane: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                List(selection: $selection) {
                    ForEach(sortedModules) { module in
                        StandaloneModuleRow(module: module)
                            .tag(Optional(module.id))
                            .id(module.id)
                            .contextMenu {
                                Button("Delete", role: .destructive) {
                                    store.removeStandaloneModule(id: module.id)
                                    if selection == module.id {
                                        selection = sortedModules.first?.id
                                    }
                                }
                            }
                    }
                    .onMove { source, destination in
                        store.moveStandaloneModules(fromOffsets: source, toOffset: destination)
                    }
                }
                .onChange(of: pendingScrollID) { _, newValue in
                    if let id = newValue {
                        proxy.scrollTo(id, anchor: .center)
                        pendingScrollID = nil
                    }
                }
            }

            Divider()

            HStack(spacing: 8) {
                Menu {
                    ForEach(ModuleKind.allCases) { kind in
                        Button(kind.defaultTitle) {
                            let entry = store.addStandaloneModule(kind: kind)
                            selection = entry.id
                        }
                    }
                } label: {
                    Label("Add", systemImage: "plus")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()

                Button {
                    if let id = selection {
                        store.removeStandaloneModule(id: id)
                        selection = sortedModules.first?.id
                    }
                } label: {
                    Label("Remove", systemImage: "minus")
                }
                .disabled(selection == nil)

                Spacer()
            }
            .padding(10)
        }
    }

    @ViewBuilder
    private var detailPane: some View {
        if sortedModules.isEmpty {
            EmptyStandaloneModulesPanel()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let id = selection,
                  let current = store.settings.resolvedStandaloneModules.first(where: { $0.id == id }) {
            StandaloneModuleDetailView(module: current)
        } else {
            ContentUnavailableView(
                "Select a Standalone Module",
                systemImage: "square.grid.2x2",
                description: Text("Choose an entry from the list, or create a new one.")
            )
        }
    }
}

// MARK: - Row

private struct StandaloneModuleRow: View {
    let module: StandaloneModuleConfig

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: module.isVisible ? "square.grid.2x2" : "square.grid.2x2.fill")
                .foregroundStyle(module.isVisible ? .primary : .secondary)

            VStack(alignment: .leading, spacing: 2) {
                Text(module.title.isEmpty ? module.kind.defaultTitle : module.title)
                    .lineLimit(1)
                Text(module.kind.defaultTitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if module.shortcut?.isEnabled == true {
                Image(systemName: "keyboard")
                    .foregroundStyle(.secondary)
            }

            // Item count is exactly 1 for a standalone module (Requirement 3.3).
            Text("1 item")
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Detail view (Task 10.6 + 10.7 + 10.8)

private struct StandaloneModuleDetailView: View {
    @EnvironmentObject private var store: PreferencesStore
    let module: StandaloneModuleConfig

    var body: some View {
        SettingsPane(
            module.title.isEmpty ? module.kind.defaultTitle : module.title,
            subtitle: module.bondLabel
        ) {
            standaloneModuleCard
            iconCard
            hotkeyCard
        }
    }

    // MARK: Card 1 — bond/title/visibility/style (Task 10.6)

    private var standaloneModuleCard: some View {
        SettingsCard("Standalone Module") {
            SettingsBlockRow {
                Text(module.bondLabel)
                    .font(.callout.weight(.semibold))
            }

            SettingsRow("Title") {
                TextField("", text: titleBinding)
            }

            SettingsRow("Show in menu bar") {
                Toggle("", isOn: visibilityBinding)
                    .labelsHidden()
                    .toggleStyle(.switch)
            }

            SettingsRow("Menu bar style") {
                Picker("", selection: menuBarStyleBinding) {
                    ForEach(MenuBarStyle.allCases) { style in
                        Text(style.label).tag(style)
                    }
                }
                .labelsHidden()
            }
        }
    }

    // MARK: Card 2 — icon (Task 10.7)

    private var iconCard: some View {
        SettingsCard("Icon") {
            SettingsBlockRow {
                IconPicker(
                    icon: iconBinding,
                    colorHex: iconColorBinding,
                    displayName: module.title.isEmpty ? module.kind.defaultTitle : module.title,
                    onPickCustomImage: { store.selectCustomIconForStandaloneModule(id: module.id) }
                )
            }
        }
    }

    // MARK: Card 3 — hotkey + conflict banner (Task 10.8)

    private var hotkeyCard: some View {
        SettingsCard("Hotkey") {
            SettingsRow("Shortcut") {
                StandaloneModuleShortcutRecorder(shortcut: shortcutBinding)
                    .frame(width: 220, height: 30)
            }

            if let conflict = currentConflict {
                SettingsBlockRow {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        Text("Conflicts with \(conflict.ownerName).")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    private var currentConflict: StandaloneModuleHotkeyConflict? {
        StandaloneModuleHotkeyConflict.scan(
            recorded: module.shortcut,
            currentEntryID: module.id,
            menuViews: store.settings.resolvedMenuViews,
            standaloneModules: store.settings.resolvedStandaloneModules,
            knownPopupHotkeys: []
        )
    }

    // MARK: Bindings

    private var titleBinding: Binding<String> {
        Binding(
            get: { module.title },
            set: { value in
                var updated = module
                updated.title = value
                store.updateStandaloneModule(updated)
            }
        )
    }

    private var visibilityBinding: Binding<Bool> {
        Binding(
            get: { module.isVisible },
            set: { value in
                store.setStandaloneModuleVisibility(id: module.id, isVisible: value)
            }
        )
    }

    private var menuBarStyleBinding: Binding<MenuBarStyle> {
        Binding(
            get: { module.menuBarStyle },
            set: { value in
                var updated = module
                updated.menuBarStyle = value
                store.updateStandaloneModule(updated)
            }
        )
    }

    private var iconBinding: Binding<FolderIconConfig> {
        Binding(
            get: { module.icon },
            set: { value in
                var updated = module
                updated.icon = value
                store.updateStandaloneModule(updated)
            }
        )
    }

    private var iconColorBinding: Binding<String?> {
        Binding(
            get: { module.iconColorHex },
            set: { value in
                var updated = module
                updated.iconColorHex = value
                store.updateStandaloneModule(updated)
            }
        )
    }

    private var shortcutBinding: Binding<KeyboardShortcutConfig?> {
        Binding(
            get: { module.shortcut },
            set: { value in
                var updated = module
                updated.shortcut = value
                store.updateStandaloneModule(updated)
            }
        )
    }
}

// MARK: - Local shortcut recorder
//
// `ShortcutRecorderView` is `private` to `SettingsView.swift`. To keep this
// module self-contained, we declare a sibling that mirrors its behaviour
// 1:1. Once a shared public version exists this can be removed.

private struct StandaloneModuleShortcutRecorder: NSViewRepresentable {
    @Binding var shortcut: KeyboardShortcutConfig?

    func makeNSView(context: Context) -> StandaloneModuleShortcutRecorderButton {
        let button = StandaloneModuleShortcutRecorderButton()
        button.bezelStyle = .rounded
        button.setButtonType(.momentaryPushIn)
        button.onChange = { shortcut in
            self.shortcut = shortcut
        }
        return button
    }

    func updateNSView(_ nsView: StandaloneModuleShortcutRecorderButton, context: Context) {
        nsView.shortcut = shortcut ?? .disabled
        nsView.title = nsView.isRecording ? "Press Shortcut" : (shortcut ?? .disabled).displayString
    }
}

private final class StandaloneModuleShortcutRecorderButton: NSButton {
    var shortcut: KeyboardShortcutConfig = .disabled
    var onChange: ((KeyboardShortcutConfig) -> Void)?
    var isRecording = false

    override var acceptsFirstResponder: Bool { true }

    override func mouseDown(with event: NSEvent) {
        isRecording = true
        title = "Press Shortcut"
        window?.makeFirstResponder(self)
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 {
            isRecording = false
            title = shortcut.displayString
            return
        }

        if event.keyCode == 51 || event.keyCode == 117 {
            let cleared = KeyboardShortcutConfig.disabled
            shortcut = cleared
            isRecording = false
            title = cleared.displayString
            onChange?(cleared)
            return
        }

        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let acceptedFlags = flags.intersection([.command, .option, .control, .shift])
        guard !acceptedFlags.isEmpty,
              let key = event.charactersIgnoringModifiers?.trimmingCharacters(in: .whitespacesAndNewlines),
              !key.isEmpty else {
            NSSound.beep()
            return
        }

        let recorded = KeyboardShortcutConfig(
            isEnabled: true,
            keyEquivalent: key,
            modifierFlags: acceptedFlags.rawValue,
            keyCode: event.keyCode
        )
        shortcut = recorded
        isRecording = false
        title = recorded.displayString
        onChange?(recorded)
    }
}

// MARK: - Empty state (Task 10.9)

private struct EmptyStandaloneModulesPanel: View {
    @EnvironmentObject private var store: PreferencesStore

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "square.grid.2x2")
                .font(.system(size: 36, weight: .light))
                .foregroundStyle(.secondary)
            Text("No standalone modules yet")
                .font(.title3.weight(.semibold))
            Text("Add a Browser Flip, Clipboard Shelf, or World Clock icon to your menu bar.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)

            Menu {
                ForEach(ModuleKind.allCases) { kind in
                    Button(kind.defaultTitle) {
                        store.addStandaloneModule(kind: kind)
                    }
                }
            } label: {
                Label("Add Standalone Module", systemImage: "plus")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .padding(.top, 4)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
