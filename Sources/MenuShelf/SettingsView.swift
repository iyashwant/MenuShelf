import AppKit
import SwiftUI

private enum SettingsSection: String, CaseIterable, Identifiable {
    case general
    case menuViews
    case sources
    case menuDefaults
    case shortcuts
    case appleScripts
    case browserFlip
    case clipboardShelf
    case bookmarkShelf
    case worldClock
    case advanced

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: "General"
        case .menuViews: "Menu Bar"
        case .sources: "Sources"
        case .menuDefaults: "Menu Defaults"
        case .shortcuts: "Apple Shortcuts"
        case .appleScripts: "AppleScripts"
        case .browserFlip: "Browser Flip"
        case .clipboardShelf: "Clipboard Shelf"
        case .bookmarkShelf: "Bookmark Shelf"
        case .worldClock: "World Clock"
        case .advanced: "Advanced"
        }
    }

    var symbolName: String {
        switch self {
        case .general: return "gearshape"
        case .menuViews: return "menubar.rectangle"
        case .sources: return "externaldrive"
        case .menuDefaults: return "slider.horizontal.3"
        case .shortcuts: return "bolt.fill"
        case .appleScripts:
            if NSImage(systemSymbolName: "applescript", accessibilityDescription: nil) != nil {
                return "applescript"
            }
            return "scroll"
        case .browserFlip: return "globe"
        case .clipboardShelf: return "clipboard"
        case .bookmarkShelf: return "bookmark"
        case .worldClock: return "clock"
        case .advanced: return "wrench.and.screwdriver"
        }
    }
}

struct SettingsView: View {
    @EnvironmentObject private var store: PreferencesStore
    @State private var section: SettingsSection = .menuViews

    var body: some View {
        NavigationSplitView {
            VStack(spacing: 0) {
                List(SettingsSection.allCases, selection: $section) { section in
                    Label(section.title, systemImage: section.symbolName)
                        .tag(section)
                }

                Divider()

                HStack(spacing: 8) {
                    Image(nsImage: NSApp.applicationIconImage)
                        .resizable()
                        .interpolation(.high)
                        .frame(width: 22, height: 22)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("MenuShelf")
                            .font(.system(size: 12, weight: .semibold))
                        Text("Settings")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
            }
            .navigationSplitViewColumnWidth(min: 170, ideal: 190)
        } detail: {
            Group {
                switch section {
                case .general:
                    GeneralSettingsView()
                case .menuViews:
                    MenuViewsSettingsView()
                case .sources:
                    SourcesSettingsView()
                case .menuDefaults:
                    MenuDefaultsSettingsView()
                case .shortcuts:
                    ShortcutsSettingsView()
                case .appleScripts:
                    AppleScriptSettingsView()
                case .browserFlip:
                    BrowserFlipSettingsView()
                case .clipboardShelf:
                    ClipboardShelfSettingsView()
                case .bookmarkShelf:
                    BookmarkShelfSettingsView()
                case .worldClock:
                    WorldClockSettingsView()
                case .advanced:
                    AdvancedSettingsView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(.regularMaterial)
        }
        .navigationTitle("")
        .onReceive(NotificationCenter.default.publisher(for: .menuShelfFocusAppleScripts)) { _ in
            section = .appleScripts
        }
        .onReceive(NotificationCenter.default.publisher(for: .menuShelfFocusClipboardShelf)) { _ in
            section = .clipboardShelf
        }
        .onReceive(NotificationCenter.default.publisher(for: .menuShelfFocusWorldClock)) { _ in
            section = .worldClock
        }
        .onReceive(NotificationCenter.default.publisher(for: .menuShelfFocusBookmarkShelf)) { _ in
            section = .bookmarkShelf
        }
        .onReceive(NotificationCenter.default.publisher(for: .menuShelfFocusStandaloneModules)) { _ in
            section = .menuViews
        }
        .onReceive(NotificationCenter.default.publisher(for: .menuShelfFocusBrowserFlip)) { _ in
            section = .browserFlip
        }
    }
}

private struct GeneralSettingsView: View {
    @EnvironmentObject private var store: PreferencesStore

    var body: some View {
        SettingsPane("General", subtitle: "How MenuShelf shows up across the system.") {
            SettingsCard("Menu Bar") {
                SettingsToggle(
                    "Show MenuShelf when no items are visible",
                    helper: "Keep at least one menu bar icon visible even if every view is hidden.",
                    isOn: Binding(
                        get: { store.settings.showMenuBarItemWhenEmpty },
                        set: { value in store.updateGlobalSettings { $0.showMenuBarItemWhenEmpty = value } }
                    )
                )

                SettingsToggle(
                    "Show top-level folder icons",
                    isOn: Binding(
                        get: { store.settings.resolvedShowTopLevelFolderIcons },
                        set: { value in store.updateGlobalSettings { $0.showTopLevelFolderIcons = value } }
                    )
                )

                SettingsToggle(
                    "Show management items in root folder menus",
                    helper: "Add Item, Settings, Hide From Menu Bar, and Remove Folder appear at the bottom of top-level folder menus.",
                    isOn: Binding(
                        get: { store.settings.resolvedShowRootFolderManagementItems },
                        set: { value in store.updateGlobalSettings { $0.showRootFolderManagementItems = value } }
                    )
                )

                SettingsRow("Top-level icon size") {
                    Picker("", selection: Binding(
                        get: { store.settings.resolvedTopLevelFolderIconSize },
                        set: { value in store.updateGlobalSettings { $0.topLevelFolderIconSize = value } }
                    )) {
                        ForEach(FileIconSize.allCases) { size in
                            Text(size.label).tag(size)
                        }
                    }
                    .labelsHidden()
                }

                SettingsBlockRow {
                    Button("Make All Menu Views Icon Only") {
                        store.setAllMenuBarStyles(.iconOnly)
                    }
                    Text("Each visible view creates one menu bar icon. Use Menu Views to organize folders and apps under each.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            SettingsCard("Submenus & Icons") {
                SettingsToggle(
                    "Show icons for files and folders",
                    isOn: Binding(
                        get: { store.settings.resolvedShowFileAndFolderIcons },
                        set: { value in store.updateGlobalSettings { $0.showFileAndFolderIcons = value } }
                    )
                )

                SettingsToggle(
                    "Show submenu for files",
                    helper: "Reveal preview, metadata, and copy actions in a submenu.",
                    isOn: Binding(
                        get: { store.settings.resolvedShowFileSubmenus },
                        set: { value in store.updateGlobalSettings { $0.showFileSubmenus = value } }
                    )
                )

                SettingsToggle(
                    "Show submenu for folders",
                    isOn: Binding(
                        get: { store.settings.resolvedShowFolderSubmenus },
                        set: { value in store.updateGlobalSettings { $0.showFolderSubmenus = value } }
                    )
                )
            }

            SettingsCard("Behavior") {
                SettingsRow(
                    "Open menu via keyboard shortcut",
                    helper: "Choose where the menu appears when triggered by a hotkey."
                ) {
                    Picker("", selection: Binding(
                        get: { store.settings.resolvedShortcutOpenLocation },
                        set: { value in store.updateGlobalSettings { $0.shortcutOpenLocation = value } }
                    )) {
                        ForEach(ShortcutOpenLocation.allCases) { location in
                            Text(location.label).tag(location)
                        }
                    }
                    .labelsHidden()
                }

                SettingsRow(
                    "Global \"…\" menu item",
                    helper: "Where the More menu appears, or hide it until Option is held."
                ) {
                    Picker("", selection: Binding(
                        get: { store.settings.resolvedMoreMenuBehavior },
                        set: { value in store.updateGlobalSettings { $0.moreMenuBehavior = value } }
                    )) {
                        ForEach(GlobalMoreMenuBehavior.allCases) { behavior in
                            Text(behavior.label).tag(behavior)
                        }
                    }
                    .labelsHidden()
                }

                SettingsToggle(
                    "Reduce animations",
                    isOn: Binding(
                        get: { store.settings.reduceAnimations },
                        set: { value in store.updateGlobalSettings { $0.reduceAnimations = value } }
                    )
                )

                SettingsToggle(
                    "Launch at login",
                    isOn: Binding(
                        get: { store.settings.launchAtLogin },
                        set: { value in store.setLaunchAtLogin(value) }
                    )
                )
            }
        }
    }
}

private enum MenuBarItemSelection: Hashable {
    case menuView(UUID)
    case standaloneModule(UUID)
}

private struct MenuViewsSettingsView: View {
    @EnvironmentObject private var store: PreferencesStore
    @State private var selection: MenuBarItemSelection?
    @State private var pendingScrollToStandaloneModule: UUID?

    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                ScrollViewReader { proxy in
                    List(selection: $selection) {
                        if !store.settings.resolvedMenuViews.isEmpty {
                            Section("Menu Views") {
                                ForEach(store.settings.resolvedMenuViews) { view in
                                    MenuViewRow(
                                        view: view,
                                        itemCount: view.items.count
                                            + view.resolvedLinkedMenuViews.count
                                            + view.resolvedShortcutItems.count
                                            + view.resolvedLinkedShortcutsFolders.count
                                            + view.resolvedAppleScriptItems.count
                                            + (view.browserFlipItem != nil ? 1 : 0)
                                            + (view.clipboardShelfItem != nil ? 1 : 0)
                                            + (view.worldClockItem != nil ? 1 : 0)
                                    )
                                    .tag(Optional(MenuBarItemSelection.menuView(view.id)))
                                    .id(MenuBarItemSelection.menuView(view.id))
                                    .contextMenu {
                                        Button("Duplicate") {
                                            store.duplicateMenuView(id: view.id)
                                        }
                                        Divider()
                                        Button("Delete", role: .destructive) {
                                            store.removeMenuView(id: view.id)
                                        }
                                    }
                                }
                                .onMove { source, destination in
                                    store.moveMenuViews(fromOffsets: source, toOffset: destination)
                                }
                            }
                        }

                        if !sortedStandaloneModules.isEmpty {
                            Section("Standalone Modules") {
                                ForEach(sortedStandaloneModules) { module in
                                    StandaloneModuleListRow(module: module)
                                        .tag(Optional(MenuBarItemSelection.standaloneModule(module.id)))
                                        .id(MenuBarItemSelection.standaloneModule(module.id))
                                        .contextMenu {
                                            Button("Delete", role: .destructive) {
                                                store.removeStandaloneModule(id: module.id)
                                                if selection == .standaloneModule(module.id) {
                                                    selection = nil
                                                }
                                            }
                                        }
                                }
                                .onMove { source, destination in
                                    store.moveStandaloneModules(fromOffsets: source, toOffset: destination)
                                }
                            }
                        }
                    }
                    .onChange(of: pendingScrollToStandaloneModule) { _, newValue in
                        if let id = newValue {
                            withAnimation {
                                proxy.scrollTo(MenuBarItemSelection.standaloneModule(id), anchor: .center)
                            }
                            pendingScrollToStandaloneModule = nil
                        }
                    }
                }

                Divider()

                HStack {
                    Menu {
                        Button {
                            store.addMenuView()
                            if let id = store.settings.resolvedMenuViews.last?.id {
                                selection = .menuView(id)
                            }
                        } label: {
                            Label("Add Menu View", systemImage: "menubar.rectangle")
                        }

                        Divider()

                        ForEach(ModuleKind.allCases) { kind in
                            Button {
                                let entry = store.addStandaloneModule(kind: kind)
                                selection = .standaloneModule(entry.id)
                            } label: {
                                Label("Add \(kind.defaultTitle)", systemImage: kind.defaultIconSymbol)
                            }
                        }
                    } label: {
                        Label("Add", systemImage: "plus")
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()

                    Button {
                        removeSelection()
                    } label: {
                        Label("Remove", systemImage: "minus")
                    }
                    .disabled(selection == nil)

                    Spacer()
                }
                .padding(10)
            }
            .frame(minWidth: 200, idealWidth: 240, maxWidth: 280)
            .frame(maxHeight: .infinity)

            detailPane
        }
        .onAppear {
            syncSelectionFromStore(initial: true)
        }
        .onChange(of: store.selectedMenuViewID) { _, newValue in
            if let id = newValue, selection != .menuView(id) {
                selection = .menuView(id)
            }
        }
        .onChange(of: selection) { _, newValue in
            if case .menuView(let id) = newValue {
                if store.selectedMenuViewID != id {
                    store.selectedMenuViewID = id
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .menuShelfScrollToStandaloneModule)) { notification in
            if let id = notification.userInfo?["standaloneModuleID"] as? UUID {
                selection = .standaloneModule(id)
                pendingScrollToStandaloneModule = id
            }
        }
    }

    @ViewBuilder
    private var detailPane: some View {
        switch selection {
        case .menuView(let id):
            if let currentMenuView = store.menuView(id: id) {
                MenuViewContentsView(view: Binding(
                    get: { store.menuView(id: id) ?? currentMenuView },
                    set: { store.updateMenuView($0) }
                ))
                .frame(minWidth: 280, idealWidth: 360, maxWidth: 480)
                .frame(maxHeight: .infinity)

                MenuViewDetailView(view: Binding(
                    get: { store.menuView(id: id) ?? currentMenuView },
                    set: { store.updateMenuView($0) }
                ))
                .frame(minWidth: 380)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                emptySelectionPane
            }
        case .standaloneModule(let id):
            if let module = store.settings.resolvedStandaloneModules.first(where: { $0.id == id }) {
                StandaloneModuleDetailView(module: module)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                emptySelectionPane
            }
        case .none:
            if store.settings.resolvedMenuViews.isEmpty && sortedStandaloneModules.isEmpty {
                EmptyMenuViewsPanel()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                emptySelectionPane
            }
        }
    }

    private var emptySelectionPane: some View {
        ContentUnavailableView(
            "Select a menu bar item",
            systemImage: "menubar.rectangle",
            description: Text("Choose a menu view or standalone module from the list, or add a new one.")
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var sortedStandaloneModules: [StandaloneModuleConfig] {
        store.settings.resolvedStandaloneModules.sorted { $0.sortOrder < $1.sortOrder }
    }

    private func syncSelectionFromStore(initial: Bool) {
        if selection != nil { return }
        if let id = store.selectedMenuViewID {
            selection = .menuView(id)
        } else if let firstMenuViewID = store.settings.resolvedMenuViews.first?.id {
            selection = .menuView(firstMenuViewID)
        } else if let firstModuleID = sortedStandaloneModules.first?.id {
            selection = .standaloneModule(firstModuleID)
        }
        _ = initial
    }

    private func removeSelection() {
        switch selection {
        case .menuView(let id):
            store.removeMenuView(id: id)
            selection = store.settings.resolvedMenuViews.first.map { .menuView($0.id) }
                ?? sortedStandaloneModules.first.map { .standaloneModule($0.id) }
        case .standaloneModule(let id):
            store.removeStandaloneModule(id: id)
            selection = sortedStandaloneModules.first.map { .standaloneModule($0.id) }
                ?? store.settings.resolvedMenuViews.first.map { .menuView($0.id) }
        case .none:
            return
        }
    }
}

private struct StandaloneModuleListRow: View {
    let module: StandaloneModuleConfig

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: module.kind.defaultIconSymbol)
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
        }
        .padding(.vertical, 4)
    }
}

private struct SourcesSettingsView: View {
    @EnvironmentObject private var store: PreferencesStore

    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                List(selection: $store.selectedFolderID) {
                    ForEach(store.settings.folders) { folder in
                        FolderRow(folder: folder)
                            .tag(Optional(folder.id))
                            .contextMenu {
                                Button("Delete", role: .destructive) {
                                    store.removeFolder(id: folder.id)
                                }
                            }
                    }
                    .onMove { source, destination in
                        store.moveFolders(fromOffsets: source, toOffset: destination)
                    }
                }

                Divider()

                HStack {
                    Button {
                        store.addFolderFromPanel()
                    } label: {
                        Label("Add Folder", systemImage: "folder.badge.plus")
                    }

                    Button {
                        store.addAppFromPanel()
                    } label: {
                        Label("Add App", systemImage: "app.badge.plus")
                    }

                    Button {
                        if let id = store.selectedFolderID {
                            store.removeFolder(id: id)
                        }
                    } label: {
                        Label("Remove", systemImage: "minus")
                    }
                    .disabled(store.selectedFolderID == nil)

                    Spacer()
                }
                .padding(10)
            }
            .frame(minWidth: 170, idealWidth: 200, maxWidth: 250)
            .frame(maxHeight: .infinity)

            Group {
                if store.settings.folders.isEmpty {
                    OnboardingPanel()
                        .frame(minWidth: 430)
                } else if let id = store.selectedFolderID, let currentFolder = store.folder(id: id) {
                    FolderDetailView(config: Binding(
                        get: { store.folder(id: id) ?? currentFolder },
                        set: { store.updateFolder($0) }
                    ))
                    .frame(minWidth: 380)
                } else {
                    ContentUnavailableView("Select a Source", systemImage: "externaldrive", description: Text("Choose a folder or app source from the library."))
                        .frame(minWidth: 380)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

private struct MenuViewRow: View {
    let view: MenuViewConfig
    let itemCount: Int

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: view.isVisible ? "menubar.rectangle" : "menubar.dock.rectangle.badge.record")
                .foregroundStyle(view.isVisible ? .primary : .secondary)

            VStack(alignment: .leading, spacing: 2) {
                Text(view.title)
                    .lineLimit(1)
                Text("\(itemCount) item\(itemCount == 1 ? "" : "s")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if view.shortcut?.isEnabled == true {
                Image(systemName: "keyboard")
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }
}

private enum UnifiedContentItem: Identifiable {
    case menuViewItem(MenuViewItem)
    case shortcut(ShortcutMenuItemConfig)
    case linkedMenuView(LinkedMenuViewConfig)
    case linkedShortcutsFolder(LinkedShortcutsFolderConfig)
    case appleScript(AppleScriptMenuItemConfig)
    case browserFlip(BrowserFlipMenuItemConfig)
    case clipboardShelf(ClipboardShelfMenuItemConfig)
    case worldClock(WorldClockMenuItemConfig)

    var id: UUID {
        switch self {
        case .menuViewItem(let item): item.id
        case .shortcut(let item): item.id
        case .linkedMenuView(let item): item.id
        case .linkedShortcutsFolder(let item): item.id
        case .appleScript(let item): item.id
        case .browserFlip(let item): item.id
        case .clipboardShelf(let item): item.id
        case .worldClock(let item): item.id
        }
    }

    var kindIcon: String {
        switch self {
        case .menuViewItem: return "folder"
        case .shortcut: return "bolt.fill"
        case .linkedMenuView: return "menubar.rectangle"
        case .linkedShortcutsFolder: return "folder.badge.gearshape"
        case .appleScript:
            if NSImage(systemSymbolName: "applescript", accessibilityDescription: nil) != nil {
                return "applescript"
            }
            return "scroll"
        case .browserFlip: return "globe"
        case .clipboardShelf: return "clipboard"
        case .worldClock: return "clock"
        }
    }

    var kindIconColor: Color {
        switch self {
        case .menuViewItem: .secondary
        case .shortcut: .orange
        case .linkedMenuView: .blue
        case .linkedShortcutsFolder: .indigo
        case .appleScript: .purple
        case .browserFlip: .teal
        case .clipboardShelf: .green
        case .worldClock: .cyan
        }
    }
}

private struct MenuViewDetailView: View {
    @EnvironmentObject private var store: PreferencesStore
    @Binding var view: MenuViewConfig
    @State private var selectedContentItemID: UUID?
    @State private var editingItem: UnifiedContentItem?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                SettingsHeader(
                    title: view.title,
                    subtitle: "Menu bar icon with \(contentCount) item\(contentCount == 1 ? "" : "s")",
                    symbolName: "menubar.rectangle"
                )

                SettingsCard("Menu View") {
                    SettingsRow("Title") {
                        TextField("", text: $view.title)
                            .textFieldStyle(.roundedBorder)
                    }

                    SettingsToggle("Visible in menu bar", isOn: $view.isVisible)

                    SettingsRow("Menu bar style") {
                        Picker("", selection: $view.menuBarStyle) {
                            ForEach(MenuBarStyle.allCases) { style in
                                Text(style.label).tag(style)
                            }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .frame(width: 220)
                    }

                    SettingsRow("Layout") {
                        Picker("", selection: Binding(
                            get: { view.resolvedLayout },
                            set: { view.layout = $0 }
                        )) {
                            ForEach(MenuViewLayout.allCases) { layout in
                                Text(layout.label).tag(layout)
                            }
                        }
                        .labelsHidden()
                    }

                    SettingsRow(
                        "Shortcut opens",
                        helper: "Where the menu appears when triggered by the hotkey below."
                    ) {
                        Picker("", selection: Binding(
                            get: { view.openLocation ?? store.settings.resolvedShortcutOpenLocation },
                            set: { view.openLocation = $0 }
                        )) {
                            ForEach(ShortcutOpenLocation.allCases) { location in
                                Text(location.label).tag(location)
                            }
                        }
                        .labelsHidden()
                    }

                    SettingsRow("Hotkey") {
                        ShortcutRecorderView(shortcut: $view.shortcut)
                            .frame(width: 220, height: 30)
                    }
                }

                SettingsCard("Icon") {
                    SettingsBlockRow {
                        IconPicker(
                            icon: $view.icon,
                            colorHex: $view.iconColorHex,
                            displayName: view.title,
                            onPickCustomImage: { store.selectCustomIconForMenuView(id: view.id) }
                        )
                    }
                }

                MenuSettingsEditor(settings: $view.menuSettings)
            }
            .padding(28)
            .frame(maxWidth: 760, alignment: .leading)
        }
    }

    private var contentCount: Int {
        view.items.count + view.resolvedLinkedMenuViews.count + view.resolvedShortcutItems.count + view.resolvedLinkedShortcutsFolders.count + view.resolvedAppleScriptItems.count + (view.browserFlipItem != nil ? 1 : 0) + (view.clipboardShelfItem != nil ? 1 : 0) + (view.worldClockItem != nil ? 1 : 0)
    }
}

private struct MenuViewContentsView: View {
    @EnvironmentObject private var store: PreferencesStore
    @Binding var view: MenuViewConfig
    @State private var selectedContentItemID: UUID?
    @State private var editingItem: UnifiedContentItem?

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text("View Contents")
                    .font(.headline)
                Spacer()
                if store.isRefreshingShortcuts {
                    ProgressView()
                        .controlSize(.small)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)

            Divider()

            List(selection: $selectedContentItemID) {
                ForEach(unifiedItems) { item in
                    UnifiedContentItemRow(item: item, store: store)
                        .tag(item.id)
                        .contextMenu {
                            Button {
                                editingItem = item
                            } label: {
                                Label("Edit", systemImage: "pencil")
                            }

                            Divider()

                            Button(role: .destructive) {
                                removeContentItem(id: item.id)
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }

                            if case .shortcut(let shortcut) = item {
                                Button {
                                    let identifierOrName = shortcut.shortcutIdentifier ?? shortcut.name
                                    Task {
                                        try? await AppContainer.shared.shortcutsService.openShortcutForEditing(identifierOrName: identifierOrName)
                                    }
                                } label: {
                                    Label("Open in Shortcuts", systemImage: "app.connected.to.app.below.fill")
                                }
                            }
                        }
                }
                .onMove { source, destination in
                    handleContentMove(fromOffsets: source, toOffset: destination)
                }
            }
            .frame(maxHeight: .infinity)

            Divider()

            HStack {
                Menu {
                    Button {
                        store.selectedMenuViewID = view.id
                        store.addFolderFromPanel()
                    } label: {
                        Label("Add Folder", systemImage: "folder.badge.plus")
                    }

                    Button {
                        store.selectedMenuViewID = view.id
                        store.addAppFromPanel()
                    } label: {
                        Label("Add App", systemImage: "app.badge.plus")
                    }

                    Divider()

                    Menu {
                        ForEach(store.settings.folders) { source in
                            Button(source.displayName) {
                                store.attachSource(source.id, toMenuViewID: view.id)
                            }
                        }
                    } label: {
                        Label("Add Existing Source", systemImage: "plus.square.on.square")
                    }

                    Menu {
                        let candidates = store.settings.resolvedMenuViews.filter { candidate in
                            candidate.id != view.id && !view.resolvedLinkedMenuViews.contains { $0.menuViewID == candidate.id }
                        }

                        if candidates.isEmpty {
                            Text("No available views")
                        } else {
                            ForEach(candidates) { candidate in
                                Button(candidate.title) {
                                    store.addLinkedMenuView(candidate.id, toMenuViewID: view.id)
                                }
                                .disabled(!store.canLinkMenuView(candidate.id, toMenuViewID: view.id))
                            }
                        }
                    } label: {
                        Label("Add Existing View", systemImage: "menubar.rectangle")
                    }

                    Divider()

                    Menu {
                        if store.availableShortcuts.isEmpty {
                            Button("Refresh Shortcuts") {
                                store.refreshShortcutsCatalog()
                            }
                        } else {
                            ForEach(store.availableShortcuts) { shortcut in
                                Button(shortcut.name) {
                                    store.addShortcut(shortcut, toMenuViewID: view.id)
                                }
                            }
                        }
                    } label: {
                        Label("Add Shortcut", systemImage: "bolt.fill")
                    }

                    Menu {
                        if store.availableShortcutFolders.isEmpty {
                            Button("Refresh Shortcuts Folders") {
                                store.refreshShortcutsCatalog()
                            }
                        } else {
                            ForEach(store.availableShortcutFolders) { folder in
                                Button(folder.name) {
                                    store.addLinkedShortcutsFolder(folder, toMenuViewID: view.id)
                                }
                            }
                        }
                    } label: {
                        Label("Link Shortcuts Folder", systemImage: "folder.badge.plus")
                    }

                    Divider()

                    Menu {
                        let attached = Set(view.resolvedAppleScriptItems.map(\.appleScriptID))
                        let candidates = store.settings.resolvedAppleScripts.filter { !attached.contains($0.id) }
                        if candidates.isEmpty {
                            Text("No AppleScripts available").disabled(true)
                        } else {
                            ForEach(candidates) { script in
                                Button(script.name) {
                                    store.attachAppleScript(script.id, toMenuViewID: view.id)
                                }
                            }
                        }
                    } label: {
                        Label("Add AppleScript", systemImage: appleScriptMenuSymbol)
                    }

                    Divider()

                    Button {
                        store.addBrowserFlipItem(toMenuViewID: view.id)
                    } label: {
                        Label("Add Default Browser", systemImage: "globe")
                    }
                    .disabled(view.browserFlipItem != nil)

                    Button {
                        store.addClipboardShelfItem(toMenuViewID: view.id)
                    } label: {
                        Label("Add Clipboard Shelf", systemImage: "clipboard")
                    }
                    .disabled(view.clipboardShelfItem != nil)

                    Button {
                        store.addWorldClockItem(toMenuViewID: view.id)
                    } label: {
                        Label("Add World Clock", systemImage: "clock")
                    }
                    .disabled(view.worldClockItem != nil)
                } label: {
                    Label("Add", systemImage: "plus")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()

                Button {
                    if let id = selectedContentItemID,
                       let item = unifiedItems.first(where: { $0.id == id }) {
                        editingItem = item
                    }
                } label: {
                    Label("Edit", systemImage: "pencil")
                }
                .disabled(selectedContentItemID == nil)

                Button {
                    if let id = selectedContentItemID {
                        removeContentItem(id: id)
                    }
                } label: {
                    Label("Remove", systemImage: "minus")
                }
                .disabled(selectedContentItemID == nil)

                Spacer()

                Button {
                    store.refreshShortcutsCatalog()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .help("Refresh Shortcuts")
                .disabled(store.isRefreshingShortcuts)
            }
            .padding(10)
        }
        .popover(item: $editingItem, arrowEdge: .trailing) { item in
            makePopoverEditor(for: item)
                .frame(minWidth: 340, idealWidth: 380)
                .padding()
        }
    }

    private var unifiedItems: [UnifiedContentItem] {
        var items: [UnifiedContentItem] = []
        items.append(contentsOf: view.items.map { .menuViewItem($0) })
        items.append(contentsOf: view.resolvedLinkedMenuViews.map { .linkedMenuView($0) })
        items.append(contentsOf: view.resolvedShortcutItems.map { .shortcut($0) })
        items.append(contentsOf: view.resolvedAppleScriptItems.map { .appleScript($0) })
        items.append(contentsOf: view.resolvedLinkedShortcutsFolders.map { .linkedShortcutsFolder($0) })
        if let browserFlip = view.browserFlipItem {
            items.append(.browserFlip(browserFlip))
        }
        if let clipboardShelf = view.clipboardShelfItem {
            items.append(.clipboardShelf(clipboardShelf))
        }
        if let worldClock = view.worldClockItem {
            items.append(.worldClock(worldClock))
        }
        return items
    }

    private var appleScriptMenuSymbol: String {
        if NSImage(systemSymbolName: "applescript", accessibilityDescription: nil) != nil {
            return "applescript"
        }
        return "scroll"
    }

    private func menuViewItemBinding(for id: UUID) -> Binding<MenuViewItem>? {
        guard let index = view.items.firstIndex(where: { $0.id == id }) else { return nil }

        return Binding(
            get: { view.items[index] },
            set: { updated in
                var copy = updated
                copy.updatedAt = Date()
                view.items[index] = copy
            }
        )
    }

    private func removeContentItem(id: UUID) {
        if view.items.contains(where: { $0.id == id }) {
            view.items.removeAll { $0.id == id }
        } else if view.resolvedShortcutItems.contains(where: { $0.id == id }) {
            removeShortcutItem(id: id)
        } else if view.resolvedAppleScriptItems.contains(where: { $0.id == id }) {
            removeAppleScriptItem(id: id)
        } else if view.resolvedLinkedMenuViews.contains(where: { $0.id == id }) {
            removeLinkedMenuView(id: id)
        } else if view.resolvedLinkedShortcutsFolders.contains(where: { $0.id == id }) {
            removeLinkedFolder(id: id)
        } else if view.browserFlipItem?.id == id {
            view.browserFlipItem = nil
        } else if view.clipboardShelfItem?.id == id {
            view.clipboardShelfItem = nil
        } else if view.worldClockItem?.id == id {
            store.removeWorldClockItem(fromMenuViewID: view.id)
        }
        selectedContentItemID = nil
    }

    private func handleContentMove(fromOffsets source: IndexSet, toOffset destination: Int) {
        guard let sourceIndex = source.first else { return }
        let items = unifiedItems
        guard sourceIndex < items.count else { return }

        let sourcesEnd = view.items.count
        let linkedViewsEnd = sourcesEnd + view.resolvedLinkedMenuViews.count
        let shortcutsEnd = linkedViewsEnd + view.resolvedShortcutItems.count
        let appleScriptsEnd = shortcutsEnd + view.resolvedAppleScriptItems.count
        let linkedShortcutsFoldersEnd = appleScriptsEnd + view.resolvedLinkedShortcutsFolders.count

        let sourceItem = items[sourceIndex]
        var clampedDest = destination

        switch sourceItem {
        case .menuViewItem:
            if destination <= 0 { clampedDest = 0 }
            if destination > sourcesEnd { clampedDest = sourcesEnd }
        case .linkedMenuView:
            if destination < sourcesEnd { clampedDest = sourcesEnd }
            if destination > linkedViewsEnd { clampedDest = linkedViewsEnd }
        case .shortcut:
            if destination < linkedViewsEnd { clampedDest = linkedViewsEnd }
            if destination > shortcutsEnd { clampedDest = shortcutsEnd }
        case .appleScript:
            if destination < shortcutsEnd { clampedDest = shortcutsEnd }
            if destination > appleScriptsEnd { clampedDest = appleScriptsEnd }
        case .linkedShortcutsFolder:
            if destination < appleScriptsEnd { clampedDest = appleScriptsEnd }
            if destination > linkedShortcutsFoldersEnd { clampedDest = linkedShortcutsFoldersEnd }
        case .browserFlip:
            // Browser flip lives in a single-slot group; reordering is a no-op.
            return
        case .clipboardShelf:
            // Clipboard Shelf lives in a single-slot group; reordering is a no-op.
            return
        case .worldClock:
            // World Clock lives in a single-slot group; reordering is a no-op.
            return
        }

        if sourceIndex < clampedDest { clampedDest -= 1 }

        let groupOffset: Int
        let sourceGroupOffset: Int
        switch sourceItem {
        case .menuViewItem:
            sourceGroupOffset = sourceIndex
            groupOffset = clampedDest
            view.items.move(fromOffsets: IndexSet(integer: sourceGroupOffset), toOffset: groupOffset)
        case .linkedMenuView:
            sourceGroupOffset = sourceIndex - sourcesEnd
            groupOffset = clampedDest - sourcesEnd
            var arr = view.resolvedLinkedMenuViews
            arr.move(fromOffsets: IndexSet(integer: sourceGroupOffset), toOffset: groupOffset)
            view.linkedMenuViews = arr
        case .shortcut:
            sourceGroupOffset = sourceIndex - linkedViewsEnd
            groupOffset = clampedDest - linkedViewsEnd
            var arr = view.resolvedShortcutItems
            arr.move(fromOffsets: IndexSet(integer: sourceGroupOffset), toOffset: groupOffset)
            view.shortcutItems = arr
        case .appleScript:
            sourceGroupOffset = sourceIndex - shortcutsEnd
            groupOffset = clampedDest - shortcutsEnd
            var arr = view.resolvedAppleScriptItems
            arr.move(fromOffsets: IndexSet(integer: sourceGroupOffset), toOffset: groupOffset)
            view.appleScriptItems = arr
        case .linkedShortcutsFolder:
            sourceGroupOffset = sourceIndex - appleScriptsEnd
            groupOffset = clampedDest - appleScriptsEnd
            var arr = view.resolvedLinkedShortcutsFolders
            arr.move(fromOffsets: IndexSet(integer: sourceGroupOffset), toOffset: groupOffset)
            view.linkedShortcutsFolders = arr
        case .browserFlip:
            // Already handled by the early return above; the values are unused.
            sourceGroupOffset = 0
            groupOffset = 0
            _ = sourceGroupOffset
            _ = groupOffset
        case .clipboardShelf:
            // Already handled by the early return above; the values are unused.
            sourceGroupOffset = 0
            groupOffset = 0
            _ = sourceGroupOffset
            _ = groupOffset
        case .worldClock:
            // Already handled by the early return above; the values are unused.
            sourceGroupOffset = 0
            groupOffset = 0
            _ = sourceGroupOffset
            _ = groupOffset
        }
    }

    @ViewBuilder
    private func makePopoverEditor(for item: UnifiedContentItem) -> some View {
        switch item {
        case .menuViewItem:
            if let binding = menuViewItemBinding(for: item.id) {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Edit Source")
                        .font(.headline)

                    Text(store.folder(id: binding.wrappedValue.sourceID)?.displayName ?? "Missing Source")
                        .foregroundStyle(.secondary)

                    TextField("Title override", text: Binding(
                        get: { binding.wrappedValue.titleOverride ?? "" },
                        set: { binding.wrappedValue.titleOverride = $0.isEmpty ? nil : $0 }
                    ))

                    TextField("Section name", text: Binding(
                        get: { binding.wrappedValue.sectionName ?? "" },
                        set: { binding.wrappedValue.sectionName = $0.isEmpty ? nil : $0 }
                    ))

                    Toggle("Use custom menu settings for this source", isOn: Binding(
                        get: { binding.wrappedValue.menuSettingsOverride != nil },
                        set: { enabled in
                            let source = store.folder(id: binding.wrappedValue.sourceID)
                            binding.wrappedValue.menuSettingsOverride = enabled ? (binding.wrappedValue.menuSettingsOverride ?? source?.menuSettings ?? .defaults) : nil
                        }
                    ))

                    if binding.wrappedValue.menuSettingsOverride != nil {
                        MenuSettingsEditor(settings: Binding(
                            get: { binding.wrappedValue.menuSettingsOverride ?? store.folder(id: binding.wrappedValue.sourceID)?.menuSettings ?? .defaults },
                            set: { binding.wrappedValue.menuSettingsOverride = $0 }
                        ))
                    }
                }
            }
        case .shortcut:
            if let binding = shortcutBinding(for: item.id) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Edit Shortcut")
                        .font(.headline)
                    ShortcutMenuItemEditor(item: binding) {
                        removeContentItem(id: item.id)
                        editingItem = nil
                    }
                }
            }
        case .linkedMenuView:
            if let binding = linkedMenuViewBinding(for: item.id) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Edit Linked View")
                        .font(.headline)
                    LinkedMenuViewEditor(linkedView: binding, targetView: store.menuView(id: binding.wrappedValue.menuViewID)) {
                        removeContentItem(id: item.id)
                        editingItem = nil
                    }
                }
            }
        case .linkedShortcutsFolder:
            if let binding = linkedFolderBinding(for: item.id) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Edit Linked Folder")
                        .font(.headline)
                    LinkedShortcutsFolderEditor(folder: binding) {
                        removeContentItem(id: item.id)
                        editingItem = nil
                    }
                }
            }
        case .appleScript:
            if let binding = appleScriptItemBinding(for: item.id) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Edit AppleScript Item")
                        .font(.headline)
                    AppleScriptMenuItemEditor(item: binding) {
                        removeContentItem(id: item.id)
                        editingItem = nil
                    }
                }
            }
        case .browserFlip:
            if let binding = browserFlipItemBinding(for: item.id) {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Edit Default Browser")
                        .font(.headline)

                    Text("Lets you switch the system default browser from this menu.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    TextField("Title override", text: Binding(
                        get: { binding.wrappedValue.titleOverride ?? "" },
                        set: { binding.wrappedValue.titleOverride = $0.isEmpty ? nil : $0 }
                    ))

                    TextField("Section name", text: Binding(
                        get: { binding.wrappedValue.sectionName ?? "" },
                        set: { binding.wrappedValue.sectionName = $0.isEmpty ? nil : $0 }
                    ))

                    if !store.settings.resolvedBrowserFlip.enableBrowserFlip {
                        Text("Browser Flip is disabled. Enable it in Settings → Browser Flip for the submenu to populate.")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }

                    HStack {
                        Spacer()
                        Button(role: .destructive) {
                            removeContentItem(id: item.id)
                            editingItem = nil
                        } label: {
                            Label("Remove", systemImage: "trash")
                        }
                    }
                }
            }
        case .clipboardShelf:
            if let binding = clipboardShelfItemBinding(for: item.id) {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Edit Clipboard Shelf")
                        .font(.headline)

                    Text("Opens the Clipboard Shelf popup with your clipboard history.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    TextField("Title override", text: Binding(
                        get: { binding.wrappedValue.titleOverride ?? "" },
                        set: { binding.wrappedValue.titleOverride = $0.isEmpty ? nil : $0 }
                    ))

                    TextField("Section name", text: Binding(
                        get: { binding.wrappedValue.sectionName ?? "" },
                        set: { binding.wrappedValue.sectionName = $0.isEmpty ? nil : $0 }
                    ))

                    if !store.settings.resolvedClipboardShelf.enableClipboardShelf {
                        Text("Clipboard Shelf is disabled. Enable it in Settings → Clipboard Shelf for the popup to populate.")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }

                    HStack {
                        Spacer()
                        Button(role: .destructive) {
                            removeContentItem(id: item.id)
                            editingItem = nil
                        } label: {
                            Label("Remove", systemImage: "trash")
                        }
                    }
                }
            }
        case .worldClock:
            if let binding = worldClockItemBinding(for: item.id) {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Edit World Clock")
                        .font(.headline)

                    Text("Opens the World Clock with your configured clocks.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    TextField("Title override", text: Binding(
                        get: { binding.wrappedValue.titleOverride ?? "" },
                        set: { binding.wrappedValue.titleOverride = $0.isEmpty ? nil : $0 }
                    ))

                    TextField("Section name", text: Binding(
                        get: { binding.wrappedValue.sectionName ?? "" },
                        set: { binding.wrappedValue.sectionName = $0.isEmpty ? nil : $0 }
                    ))

                    if !store.settings.resolvedWorldClock.enableWorldClock {
                        Text("World Clock is disabled. Enable it in Settings → World Clock for the popover to populate.")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }

                    HStack {
                        Spacer()
                        Button(role: .destructive) {
                            removeContentItem(id: item.id)
                            editingItem = nil
                        } label: {
                            Label("Remove", systemImage: "trash")
                        }
                    }
                }
            }
        }
    }

    private func linkedMenuViewBinding(for id: UUID) -> Binding<LinkedMenuViewConfig>? {
        guard let index = view.resolvedLinkedMenuViews.firstIndex(where: { $0.id == id }) else { return nil }

        return Binding(
            get: { view.resolvedLinkedMenuViews[index] },
            set: { updated in
                var items = view.resolvedLinkedMenuViews
                var copy = updated
                copy.updatedAt = Date()
                items[index] = copy
                view.linkedMenuViews = items
            }
        )
    }

    private func shortcutBinding(for id: UUID) -> Binding<ShortcutMenuItemConfig>? {
        guard let index = view.resolvedShortcutItems.firstIndex(where: { $0.id == id }) else { return nil }

        return Binding(
            get: { view.resolvedShortcutItems[index] },
            set: { updated in
                var items = view.resolvedShortcutItems
                var copy = updated
                copy.updatedAt = Date()
                items[index] = copy
                view.shortcutItems = items
            }
        )
    }

    private func linkedFolderBinding(for id: UUID) -> Binding<LinkedShortcutsFolderConfig>? {
        guard let index = view.resolvedLinkedShortcutsFolders.firstIndex(where: { $0.id == id }) else { return nil }

        return Binding(
            get: { view.resolvedLinkedShortcutsFolders[index] },
            set: { updated in
                var folders = view.resolvedLinkedShortcutsFolders
                var copy = updated
                copy.updatedAt = Date()
                folders[index] = copy
                view.linkedShortcutsFolders = folders
            }
        )
    }

    private func appleScriptItemBinding(for id: UUID) -> Binding<AppleScriptMenuItemConfig>? {
        guard let index = view.resolvedAppleScriptItems.firstIndex(where: { $0.id == id }) else { return nil }

        return Binding(
            get: { view.resolvedAppleScriptItems[index] },
            set: { updated in
                var items = view.resolvedAppleScriptItems
                var copy = updated
                copy.updatedAt = Date()
                items[index] = copy
                view.appleScriptItems = items
            }
        )
    }

    private func browserFlipItemBinding(for id: UUID) -> Binding<BrowserFlipMenuItemConfig>? {
        guard let current = view.browserFlipItem, current.id == id else { return nil }

        return Binding(
            get: { view.browserFlipItem ?? current },
            set: { updated in
                var copy = updated
                copy.updatedAt = Date()
                view.browserFlipItem = copy
            }
        )
    }

    private func clipboardShelfItemBinding(for id: UUID) -> Binding<ClipboardShelfMenuItemConfig>? {
        guard let current = view.clipboardShelfItem, current.id == id else { return nil }

        return Binding(
            get: { view.clipboardShelfItem ?? current },
            set: { updated in
                var copy = updated
                copy.updatedAt = Date()
                view.clipboardShelfItem = copy
            }
        )
    }

    private func worldClockItemBinding(for id: UUID) -> Binding<WorldClockMenuItemConfig>? {
        guard let current = view.worldClockItem, current.id == id else { return nil }

        return Binding(
            get: { view.worldClockItem ?? current },
            set: { updated in
                var copy = updated
                copy.updatedAt = Date()
                view.worldClockItem = copy
            }
        )
    }

    private func removeShortcutItem(id: UUID) {
        var items = view.resolvedShortcutItems
        items.removeAll { $0.id == id }
        view.shortcutItems = items
    }

    private func removeAppleScriptItem(id: UUID) {
        var items = view.resolvedAppleScriptItems
        items.removeAll { $0.id == id }
        view.appleScriptItems = items
    }

    private func removeLinkedMenuView(id: UUID) {
        var items = view.resolvedLinkedMenuViews
        items.removeAll { $0.id == id }
        view.linkedMenuViews = items
    }

    private func removeLinkedFolder(id: UUID) {
        var folders = view.resolvedLinkedShortcutsFolders
        folders.removeAll { $0.id == id }
        view.linkedShortcutsFolders = folders
    }
}

private struct UnifiedContentItemRow: View {
    let item: UnifiedContentItem
    let store: PreferencesStore

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: item.kindIcon)
                .foregroundStyle(item.kindIconColor)

            VStack(alignment: .leading, spacing: 2) {
                Text(displayTitle)
                    .lineLimit(1)
                Text(displaySubtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer()
        }
        .padding(.vertical, 4)
    }

    private var displayTitle: String {
        switch item {
        case .menuViewItem(let menuItem):
            if let override = menuItem.titleOverride, !override.isEmpty {
                return override
            }
            return store.folder(id: menuItem.sourceID)?.displayName ?? "Missing Source"
        case .shortcut(let shortcut):
            return shortcut.displayTitle
        case .linkedMenuView(let linkedView):
            return linkedView.displayTitle(fallbackTitle: store.menuView(id: linkedView.menuViewID)?.title ?? "Missing View")
        case .linkedShortcutsFolder(let folder):
            return folder.folderName
        case .appleScript(let script):
            let fallback = store.appleScript(id: script.appleScriptID)?.name ?? "Missing AppleScript"
            return script.displayTitle(fallbackName: fallback)
        case .browserFlip(let config):
            return config.displayTitle
        case .clipboardShelf(let config):
            return config.displayTitle
        case .worldClock(let config):
            return config.displayTitle
        }
    }

    private var displaySubtitle: String {
        switch item {
        case .menuViewItem(let menuItem):
            if let section = menuItem.sectionName, !section.isEmpty {
                return "Section: \(section)"
            }
            return store.folder(id: menuItem.sourceID)?.originalPathHint ?? "Source no longer exists"
        case .shortcut(let shortcut):
            if let section = shortcut.sectionName, !section.isEmpty {
                return "Section: \(section)"
            }
            return shortcut.shortcutIdentifier ?? shortcut.name
        case .linkedMenuView(let linkedView):
            if let section = linkedView.sectionName, !section.isEmpty {
                return "Section: \(section)"
            }
            return "Linked View"
        case .linkedShortcutsFolder(let folder):
            return folder.shortcutFolderIdentifier ?? "Shortcuts Folder"
        case .appleScript(let script):
            if let section = script.sectionName, !section.isEmpty {
                return "Section: \(section)"
            }
            return "AppleScript"
        case .browserFlip(let config):
            if let section = config.sectionName, !section.isEmpty {
                return "Section: \(section)"
            }
            return "Default Browser"
        case .clipboardShelf(let config):
            if let section = config.sectionName, !section.isEmpty {
                return "Section: \(section)"
            }
            return "Clipboard Shelf"
        case .worldClock(let config):
            if let section = config.sectionName, !section.isEmpty {
                return "Section: \(section)"
            }
            return "World Clock"
        }
    }
}

private struct MenuViewItemRow: View {
    let item: MenuViewItem
    let source: FolderConfig?

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: source?.resolvedItemKind.symbolName ?? "questionmark")
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 2) {
                let title = item.titleOverride.flatMap { $0.isEmpty ? nil : $0 }
                    ?? source?.displayName
                    ?? "Missing Source"
                let subtitle = item.sectionName.flatMap { $0.isEmpty ? nil : "Section: \($0)" }
                    ?? source?.originalPathHint
                    ?? "Source no longer exists"

                Text(title)
                    .lineLimit(1)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer()
        }
        .padding(.vertical, 4)
    }
}

private struct MenuViewItemEditor: View {
    @Binding var item: MenuViewItem
    let source: FolderConfig?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Divider()

            Text("Selected Source")
                .font(.headline)

            Text(source?.displayName ?? "Missing Source")
                .foregroundStyle(.secondary)

            TextField("Title override", text: Binding(
                get: { item.titleOverride ?? "" },
                set: { item.titleOverride = $0.isEmpty ? nil : $0 }
            ))

            TextField("Section name", text: Binding(
                get: { item.sectionName ?? "" },
                set: { item.sectionName = $0.isEmpty ? nil : $0 }
            ))

            Toggle("Use custom menu settings for this source", isOn: Binding(
                get: { item.menuSettingsOverride != nil },
                set: { enabled in
                    item.menuSettingsOverride = enabled ? (item.menuSettingsOverride ?? source?.menuSettings ?? .defaults) : nil
                }
            ))

            if item.menuSettingsOverride != nil {
                MenuSettingsEditor(settings: Binding(
                    get: { item.menuSettingsOverride ?? source?.menuSettings ?? .defaults },
                    set: { item.menuSettingsOverride = $0 }
                ))
            }
        }
    }
}

private struct ShortcutMenuItemEditor: View {
    @Binding var item: ShortcutMenuItemConfig
    let onRemove: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: "bolt.fill")
                    .foregroundStyle(.orange)

                VStack(alignment: .leading, spacing: 2) {
                    Text(item.displayTitle)
                        .lineLimit(1)
                    Text(item.shortcutIdentifier ?? item.name)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                Spacer()

                Button("Open in Shortcuts") {
                    let identifierOrName = item.shortcutIdentifier ?? item.name
                    Task {
                        try? await AppContainer.shared.shortcutsService.openShortcutForEditing(identifierOrName: identifierOrName)
                    }
                }

                Button(role: .destructive, action: onRemove) {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
            }

            HStack {
                TextField("Title override", text: Binding(
                    get: { item.titleOverride ?? "" },
                    set: { item.titleOverride = $0.isEmpty ? nil : $0 }
                ))

                TextField("Section", text: Binding(
                    get: { item.sectionName ?? "" },
                    set: { item.sectionName = $0.isEmpty ? nil : $0 }
                ))

                TextField("Quick key", text: Binding(
                    get: { item.quickKey ?? "" },
                    set: { item.quickKey = normalizedQuickKey($0) }
                ))
                .frame(width: 82)
            }
        }
        .padding(10)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func normalizedQuickKey(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard let first = trimmed.first else { return nil }
        let key = String(first)
        let allowed = "123456789abcdefghijklmnopqrstuvwxyz"
        return allowed.contains(first) ? key : nil
    }
}

private struct LinkedMenuViewEditor: View {
    @Binding var linkedView: LinkedMenuViewConfig
    let targetView: MenuViewConfig?
    let onRemove: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: "menubar.rectangle")
                    .foregroundStyle(.blue)

                VStack(alignment: .leading, spacing: 2) {
                    Text(displayTitle)
                        .lineLimit(1)
                    Text(targetView?.title ?? "Menu View no longer exists")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer()

                Button(role: .destructive, action: onRemove) {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
            }

            HStack {
                TextField("Title override", text: Binding(
                    get: { linkedView.titleOverride ?? "" },
                    set: { linkedView.titleOverride = $0.isEmpty ? nil : $0 }
                ))

                TextField("Section", text: Binding(
                    get: { linkedView.sectionName ?? "" },
                    set: { linkedView.sectionName = $0.isEmpty ? nil : $0 }
                ))
            }
        }
        .padding(10)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private var displayTitle: String {
        linkedView.displayTitle(fallbackTitle: targetView?.title ?? "Missing Menu View")
    }
}

private struct LinkedShortcutsFolderEditor: View {
    @Binding var folder: LinkedShortcutsFolderConfig
    let onRemove: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: "folder")
                    .foregroundStyle(.blue)

                VStack(alignment: .leading, spacing: 2) {
                    Text(folder.folderName)
                        .lineLimit(1)
                    Text(folder.shortcutFolderIdentifier ?? "Shortcuts folder")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                Spacer()

                Picker("Display", selection: $folder.displayMode) {
                    ForEach(LinkedShortcutsFolderConfig.DisplayMode.allCases) { mode in
                        Text(mode.label).tag(mode)
                    }
                }
                .labelsHidden()
                .frame(width: 150)

                Button("Refresh") {
                    AppContainer.shared.store.refreshLinkedShortcutsFolder(folder.folderName)
                }

                Button(role: .destructive, action: onRemove) {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
            }
        }
        .padding(10)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

struct AppleScriptMenuItemEditor: View {
    @Binding var item: AppleScriptMenuItemConfig
    let onRemove: () -> Void
    @EnvironmentObject private var store: PreferencesStore

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: appleScriptSymbol)
                    .foregroundStyle(.purple)

                VStack(alignment: .leading, spacing: 2) {
                    Text(scriptName)
                        .lineLimit(1)
                    Text("AppleScript")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button("Open in Editor") {
                    AppContainer.shared.settingsWindowController.show(selectedAppleScriptID: item.appleScriptID)
                }

                Button(role: .destructive, action: onRemove) {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
            }

            HStack {
                TextField("Title override", text: Binding(
                    get: { item.titleOverride ?? "" },
                    set: { item.titleOverride = trimmedOrNil($0, maxLength: 200) }
                ))

                TextField("Section", text: Binding(
                    get: { item.sectionName ?? "" },
                    set: { item.sectionName = trimmedOrNil($0, maxLength: 100) }
                ))

                TextField("Quick key", text: Binding(
                    get: { item.quickKey ?? "" },
                    set: { item.quickKey = normalizedQuickKey($0) }
                ))
                .frame(width: 82)
            }
        }
        .padding(10)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private var scriptName: String {
        let fallback = store.appleScript(id: item.appleScriptID)?.name ?? "Missing AppleScript"
        return item.displayTitle(fallbackName: fallback)
    }

    private var appleScriptSymbol: String {
        if NSImage(systemSymbolName: "applescript", accessibilityDescription: nil) != nil { return "applescript" }
        if NSImage(systemSymbolName: "scroll", accessibilityDescription: nil) != nil { return "scroll" }
        return "doc.text"
    }

    private func trimmedOrNil(_ value: String, maxLength: Int) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return nil }
        return String(trimmed.prefix(maxLength))
    }

    private func normalizedQuickKey(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard let first = trimmed.first else { return nil }
        let allowed = "123456789abcdefghijklmnopqrstuvwxyz"
        return allowed.contains(first) ? String(first) : nil
    }
}

private struct FolderRow: View {
    let folder: FolderConfig

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: folder.resolvedItemKind.symbolName)
                .foregroundStyle(.primary)

            VStack(alignment: .leading, spacing: 2) {
                Text(folder.displayName)
                    .lineLimit(1)
                Text("\(folder.resolvedItemKind.label) - \(folder.originalPathHint)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer()

        }
        .padding(.vertical, 4)
    }
}

private struct FolderDetailView: View {
    @EnvironmentObject private var store: PreferencesStore
    @Binding var config: FolderConfig

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                SettingsHeader(
                    title: config.displayName,
                    subtitle: "\(config.resolvedItemKind.label) · \(config.originalPathHint)",
                    symbolName: config.resolvedItemKind.symbolName
                )

                SettingsCard("Source") {
                    SettingsRow("Display name") {
                        TextField("", text: $config.displayName)
                            .textFieldStyle(.roundedBorder)
                    }

                    if config.resolvedItemKind == .folder {
                        SettingsRow(
                            "Click behavior",
                            helper: "What happens when this folder is selected from a Menu View."
                        ) {
                            Picker("", selection: $config.openBehavior) {
                                ForEach(OpenBehavior.allCases) { behavior in
                                    Text(behavior.label).tag(behavior)
                                }
                            }
                            .labelsHidden()
                        }
                    } else {
                        SettingsBlockRow {
                            Text("Apps launch directly when selected from a Menu View.")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                SettingsCard("Icon") {
                    SettingsBlockRow {
                        IconPicker(
                            icon: $config.icon,
                            colorHex: $config.iconColorHex,
                            displayName: config.displayName,
                            onPickCustomImage: { store.selectCustomIcon(for: config.id) }
                        )
                    }
                }

                MenuSettingsEditor(settings: $config.menuSettings)
            }
            .padding(28)
            .frame(maxWidth: 720, alignment: .leading)
        }
    }
}

private struct MenuDefaultsSettingsView: View {
    @EnvironmentObject private var store: PreferencesStore

    var body: some View {
        SettingsPane(
            "Menu Defaults",
            subtitle: "Defaults for newly added folders. Existing items keep their own settings."
        ) {
            MenuSettingsEditor(settings: Binding(
                get: { store.settings.defaultMenuSettings },
                set: { value in store.updateGlobalSettings { $0.defaultMenuSettings = value } }
            ))
        }
    }
}

private struct MenuSettingsEditor: View {
    @Binding var settings: MenuSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            SettingsCard("Sorting") {
                SettingsRow("Sort by") {
                    Picker("", selection: $settings.sortKey) {
                        ForEach(SortKey.allCases) { sort in
                            Text(sort.label).tag(sort)
                        }
                    }
                    .labelsHidden()
                }

                SettingsRow("Direction") {
                    Picker("", selection: $settings.sortDirection) {
                        ForEach(SortDirection.allCases) { direction in
                            Text(direction.label).tag(direction)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 200)
                }

                SettingsToggle("Keep folders on top", isOn: $settings.keepFoldersOnTop)
                SettingsToggle("Keep apps on top", isOn: $settings.keepAppsOnTop)
            }

            SettingsCard("Filtering & Limits") {
                SettingsRow("Filter") {
                    Picker("", selection: $settings.filterMode) {
                        ForEach(FilterMode.allCases) { mode in
                            Text(mode.label).tag(mode)
                        }
                    }
                    .labelsHidden()
                }

                SettingsToggle("Show hidden files", isOn: $settings.showHiddenFiles)

                SettingsToggle(
                    "Limit visible items",
                    helper: "Truncate long folders so the menu stays responsive.",
                    isOn: Binding(
                        get: { settings.maxItems != nil },
                        set: { enabled in settings.maxItems = enabled ? (settings.maxItems ?? 200) : nil }
                    )
                )

                if settings.maxItems != nil {
                    SettingsRow("Max visible items") {
                        Stepper(
                            "\(settings.maxItems ?? 200)",
                            value: Binding(
                                get: { settings.maxItems ?? 200 },
                                set: { settings.maxItems = $0 }
                            ),
                            in: 20...2000,
                            step: 10
                        )
                    }
                }

                SettingsRow("More item position") {
                    Picker("", selection: $settings.showMoreItemPosition) {
                        ForEach(MoreItemPosition.allCases) { position in
                            Text(position.label).tag(position)
                        }
                    }
                    .labelsHidden()
                }
            }

            SettingsCard("Display") {
                SettingsRow("File icon size") {
                    Picker("", selection: Binding(
                        get: { settings.resolvedFileIconSize },
                        set: { settings.fileIconSize = $0 }
                    )) {
                        ForEach(FileIconSize.allCases) { size in
                            Text(size.label).tag(size)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 220)
                }

                SettingsToggle("Show file extensions", isOn: $settings.showFileExtensions)

                SettingsToggle(
                    "Show folder title",
                    isOn: Binding(
                        get: { settings.resolvedShowFolderTitle },
                        set: { settings.showFolderTitle = $0 }
                    )
                )

                SettingsToggle("Show file previews", isOn: $settings.showPreview)
                SettingsToggle("Show metadata", isOn: $settings.showMetadata)

                SettingsToggle(
                    "Show tips in file submenus",
                    isOn: Binding(
                        get: { settings.resolvedShowTips },
                        set: { settings.showTips = $0 }
                    )
                )
            }

            SettingsCard("Behavior") {
                SettingsToggle(
                    "Show \"Open With\" for subfolders",
                    isOn: Binding(
                        get: { settings.resolvedShowOpenWithForSubfolders },
                        set: { settings.showOpenWithForSubfolders = $0 }
                    )
                )

                SettingsToggle(
                    "Reveal extra copy actions with Option",
                    helper: "Hold ⌥ over a file to surface alternate copy targets.",
                    isOn: Binding(
                        get: { settings.resolvedEnableModifierActions },
                        set: { settings.enableModifierActions = $0 }
                    )
                )

                SettingsToggle("Resolve Finder aliases", isOn: $settings.followAliases)
                SettingsToggle("Resolve symlinks", isOn: $settings.followSymlinks)
            }
        }
    }
}

private struct OnboardingPanel: View {
    @EnvironmentObject private var store: PreferencesStore

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            SettingsHeader(title: "Put folders and apps in your menu bar.", subtitle: "Add folders to browse and apps to launch from a native menu.", symbolName: "menubar.rectangle")

            HStack {
                Button {
                    store.addFolderFromPanel()
                } label: {
                    Label("Add First Folder", systemImage: "folder.badge.plus")
                        .font(.headline)
                }
                .buttonStyle(.borderedProminent)

                Button {
                    store.addAppFromPanel()
                } label: {
                    Label("Add App", systemImage: "app.badge.plus")
                        .font(.headline)
                }
                .buttonStyle(.bordered)
            }

            VStack(alignment: .leading, spacing: 10) {
                Text("Suggested folders")
                    .font(.headline)

                LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 10)], alignment: .leading, spacing: 10) {
                    ForEach(SuggestedFolder.allCases) { suggestion in
                        Button {
                            store.addFolderFromPanel(startingAt: suggestion.url)
                        } label: {
                            Label(suggestion.title, systemImage: suggestion.symbolName)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
            }

            Text("MenuShelf stores a security-scoped bookmark for every folder or app you choose so access survives relaunch inside the macOS sandbox.")
                .font(.footnote)
                .foregroundStyle(.secondary)

            Spacer()
        }
        .padding(34)
    }
}

private struct EmptyMenuViewsPanel: View {
    @EnvironmentObject private var store: PreferencesStore

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            SettingsHeader(title: "Create menu views.", subtitle: "Each visible view becomes one menu bar icon. Add folders and apps inside a view to keep different workspaces organized.", symbolName: "menubar.rectangle")

            HStack {
                Button {
                    store.addMenuView(title: "Work")
                } label: {
                    Label("Add Menu View", systemImage: "plus")
                        .font(.headline)
                }
                .buttonStyle(.borderedProminent)

                Button {
                    store.addMenuView(title: "Apps")
                    store.addAppFromPanel()
                } label: {
                    Label("Add App View", systemImage: "app.badge.plus")
                        .font(.headline)
                }
                .buttonStyle(.bordered)
            }

            Text("Sources are reusable. The same folder or app can appear in multiple Menu Views with different display names, sections, and menu settings.")
                .font(.footnote)
                .foregroundStyle(.secondary)

            Spacer()
        }
        .padding(34)
    }
}

private enum SuggestedFolder: String, CaseIterable, Identifiable {
    case applications
    case documents
    case downloads
    case desktop
    case home

    var id: String { rawValue }

    var title: String {
        switch self {
        case .applications: "Applications"
        case .documents: "Documents"
        case .downloads: "Downloads"
        case .desktop: "Desktop"
        case .home: "Home"
        }
    }

    var symbolName: String {
        switch self {
        case .applications: "app.dashed"
        case .documents: "doc.text"
        case .downloads: "arrow.down.circle"
        case .desktop: "desktopcomputer"
        case .home: "house"
        }
    }

    var url: URL {
        switch self {
        case .applications:
            return URL(fileURLWithPath: "/Applications", isDirectory: true)
        case .documents:
            return FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first ?? FileManager.default.homeDirectoryForCurrentUser
        case .downloads:
            return FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first ?? FileManager.default.homeDirectoryForCurrentUser
        case .desktop:
            return FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first ?? FileManager.default.homeDirectoryForCurrentUser
        case .home:
            return FileManager.default.homeDirectoryForCurrentUser
        }
    }
}

private struct ShortcutsSettingsView: View {
    @EnvironmentObject private var store: PreferencesStore
    @State private var searchText = ""

    var body: some View {
        HSplitView {
            allShortcutsList
                .frame(minWidth: 240, idealWidth: 300, maxWidth: 380)
                .frame(maxHeight: .infinity)

            detailPane
                .frame(minWidth: 360)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var allShortcutsList: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                Text("All Shortcuts")
                    .font(.headline)

                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                    TextField("Search shortcuts", text: $searchText)
                        .textFieldStyle(.plain)
                    if !searchText.isEmpty {
                        Button {
                            searchText = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.borderless)
                        .help("Clear search")
                    }
                }
                .padding(.vertical, 6)
                .padding(.horizontal, 8)
                .background(.background.tertiary, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            }
            .padding(.horizontal, 12)
            .padding(.top, 14)
            .padding(.bottom, 10)

            Divider()

            Group {
                if store.availableShortcuts.isEmpty {
                    VStack(spacing: 8) {
                        Spacer()
                        Text(store.isRefreshingShortcuts ? "Loading shortcuts…" : "No shortcuts found.")
                            .foregroundStyle(.secondary)
                        if !store.isRefreshingShortcuts {
                            Button("Refresh Catalog") {
                                store.refreshShortcutsCatalog()
                            }
                            .controlSize(.small)
                        }
                        Spacer()
                    }
                    .frame(maxWidth: .infinity)
                } else if filteredShortcuts.isEmpty {
                    VStack {
                        Spacer()
                        Text("No shortcuts match \u{201C}\(searchText)\u{201D}.")
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 16)
                        Spacer()
                    }
                    .frame(maxWidth: .infinity)
                } else {
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(Array(filteredShortcuts.enumerated()), id: \.element.id) { index, shortcut in
                                AllShortcutsRow(shortcut: shortcut)
                                if index < filteredShortcuts.count - 1 {
                                    Divider()
                                        .padding(.leading, 38)
                                }
                            }
                        }
                    }
                }
            }
            .frame(maxHeight: .infinity)

            Divider()

            HStack(spacing: 8) {
                Button {
                    store.refreshShortcutsCatalog()
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .disabled(store.isRefreshingShortcuts)

                if store.isRefreshingShortcuts {
                    ProgressView()
                        .controlSize(.small)
                }

                Spacer()

                Text("\(filteredShortcuts.count) of \(store.availableShortcuts.count)")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .padding(10)
        }
    }

    private var detailPane: some View {
        SettingsPane(
            "Apple Shortcuts",
            subtitle: "Run Shortcuts.app workflows directly from MenuShelf."
        ) {
            SettingsCard("Catalog") {
                SettingsBlockRow {
                    HStack(spacing: 10) {
                        Button("Refresh Catalog") {
                            store.refreshShortcutsCatalog()
                        }
                        .disabled(store.isRefreshingShortcuts)

                        if store.isRefreshingShortcuts {
                            ProgressView()
                                .controlSize(.small)
                        }

                        Spacer()

                        Button("Open Shortcuts.app") {
                            NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Shortcuts.app"))
                        }
                    }

                    Text("Loaded \(store.availableShortcuts.count) shortcut\(store.availableShortcuts.count == 1 ? "" : "s") and \(store.availableShortcutFolders.count) folder\(store.availableShortcutFolders.count == 1 ? "" : "s").")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                SettingsBlockRow {
                    HStack(spacing: 10) {
                        Menu {
                            ForEach(store.availableShortcuts) { shortcut in
                                Button(shortcut.name) {
                                    store.addShortcut(shortcut, toMenuViewID: store.selectedMenuViewID ?? store.settings.resolvedMenuViews.first?.id)
                                }
                            }
                            if store.availableShortcuts.isEmpty {
                                Button("Refresh Shortcuts") {
                                    store.refreshShortcutsCatalog()
                                }
                            }
                        } label: {
                            Label("Add Shortcut to Selected View", systemImage: "bolt.fill")
                        }

                        Menu {
                            ForEach(store.availableShortcutFolders) { folder in
                                Button(folder.name) {
                                    store.addLinkedShortcutsFolder(folder, toMenuViewID: store.selectedMenuViewID ?? store.settings.resolvedMenuViews.first?.id)
                                }
                            }
                            if store.availableShortcutFolders.isEmpty {
                                Button("Refresh Folders") {
                                    store.refreshShortcutsCatalog()
                                }
                            }
                        } label: {
                            Label("Link Shortcuts Folder", systemImage: "folder.badge.plus")
                        }

                        Spacer()
                    }
                }
            }

            SettingsCard(
                "URL Scheme",
                footer: "Option-click a shortcut menu item to open it for editing in Shortcuts.app."
            ) {
                SettingsBlockRow {
                    Text("Trigger a shortcut from anywhere by name or identifier.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)

                    URLExampleRow(text: "menushelf://run-shortcut?name=My%20Shortcut")
                    URLExampleRow(text: "menushelf://run-shortcut?id=A1B2C3D4-0000-1111-2222-ABCDEFABCDEF")
                }
            }
        }
    }

    private var filteredShortcuts: [ShortcutInfo] {
        let trimmed = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return store.availableShortcuts }
        return store.availableShortcuts.filter { shortcut in
            shortcut.name.localizedCaseInsensitiveContains(trimmed)
                || (shortcut.identifier?.localizedCaseInsensitiveContains(trimmed) ?? false)
        }
    }
}

private struct AllShortcutsRow: View {
    let shortcut: ShortcutInfo
    @State private var isHovering = false
    @State private var isRunning = false

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "bolt.fill")
                .foregroundStyle(.orange)
                .frame(width: 18)

            VStack(alignment: .leading, spacing: 2) {
                Text(shortcut.name)
                    .lineLimit(1)
                if let identifier = shortcut.identifier {
                    Text(identifier)
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }

            Spacer(minLength: 8)

            if isRunning {
                ProgressView()
                    .controlSize(.small)
            }

            Button {
                runShortcut()
            } label: {
                Label("Run", systemImage: "play.fill")
            }
            .controlSize(.small)
            .disabled(isRunning)
            .help("Run shortcut")

            Button {
                openInShortcuts()
            } label: {
                Image(systemName: "pencil")
            }
            .buttonStyle(.borderless)
            .help("Open in Shortcuts")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(isHovering ? Color.primary.opacity(0.06) : Color.clear)
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
    }

    private var identifierOrName: String {
        shortcut.identifier ?? shortcut.name
    }

    private func runShortcut() {
        isRunning = true
        Task {
            try? await AppContainer.shared.shortcutsService.runShortcut(identifierOrName: identifierOrName)
            await MainActor.run { isRunning = false }
        }
    }

    private func openInShortcuts() {
        Task {
            try? await AppContainer.shared.shortcutsService.openShortcutForEditing(identifierOrName: identifierOrName)
        }
    }
}

private struct URLExampleRow: View {
    let text: String

    var body: some View {
        HStack(spacing: 8) {
            Text(text)
                .font(.system(.footnote, design: .monospaced))
                .textSelection(.enabled)
                .lineLimit(1)
                .truncationMode(.middle)
                .padding(.vertical, 6)
                .padding(.horizontal, 8)
                .background(.background.tertiary, in: RoundedRectangle(cornerRadius: 6, style: .continuous))

            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
            } label: {
                Image(systemName: "doc.on.doc")
            }
            .buttonStyle(.borderless)
            .help("Copy")

            Spacer()
        }
    }
}

private struct AdvancedSettingsView: View {
    @EnvironmentObject private var store: PreferencesStore

    var body: some View {
        SettingsPane("Advanced", subtitle: "Local-only diagnostics and privacy controls.") {
            SettingsCard(
                "Diagnostics",
                footer: "Logs are stored locally and never uploaded."
            ) {
                SettingsToggle(
                    "Enable verbose diagnostics",
                    helper: "Write detailed logs and register crash handlers. Use to diagnose unexpected quits.",
                    isOn: Binding(
                        get: { store.settings.resolvedEnableVerboseDiagnostics },
                        set: { value in store.updateGlobalSettings { $0.enableVerboseDiagnostics = value } }
                    )
                )

                SettingsRow("Diagnostics log") {
                    HStack(spacing: 8) {
                        Button("Reveal") {
                            NSWorkspace.shared.activateFileViewerSelecting([DiagnosticsLogger.shared.logURL])
                        }
                        Button("Clear") {
                            DiagnosticsLogger.shared.clear()
                        }
                    }
                }

                SettingsBlockRow {
                    Text(DiagnosticsLogger.shared.logURL.path)
                        .font(.footnote.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .lineLimit(2)
                        .truncationMode(.middle)
                }
            }

            SettingsCard("Errors") {
                SettingsRow(
                    "Last error",
                    helper: store.lastErrorMessage ?? "No recent errors."
                ) {
                    Button("Clear") {
                        store.lastErrorMessage = nil
                    }
                    .disabled(store.lastErrorMessage == nil)
                }
            }

            SettingsCard("Privacy") {
                SettingsBlockRow {
                    Text("MenuShelf does not need network access for core functionality. File previews and metadata are generated locally from folders and apps you explicitly choose.")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

private struct ShortcutRecorderView: NSViewRepresentable {
    @Binding var shortcut: KeyboardShortcutConfig?

    func makeNSView(context: Context) -> ShortcutRecorderButton {
        let button = ShortcutRecorderButton()
        button.bezelStyle = .rounded
        button.setButtonType(.momentaryPushIn)
        button.onChange = { shortcut in
            self.shortcut = shortcut
        }
        return button
    }

    func updateNSView(_ nsView: ShortcutRecorderButton, context: Context) {
        nsView.shortcut = shortcut ?? .disabled
        nsView.title = nsView.isRecording ? "Press Shortcut" : (shortcut ?? .disabled).displayString
    }
}

private final class ShortcutRecorderButton: NSButton {
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
