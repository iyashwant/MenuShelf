import AppKit
import SwiftUI

private enum SettingsSection: String, CaseIterable, Identifiable {
    case general
    case menuViews
    case sources
    case menuDefaults
    case shortcuts
    case advanced

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: "General"
        case .menuViews: "Menu Views"
        case .sources: "Sources"
        case .menuDefaults: "Menu Defaults"
        case .shortcuts: "Shortcuts"
        case .advanced: "Advanced"
        }
    }

    var symbolName: String {
        switch self {
        case .general: "gearshape"
        case .menuViews: "menubar.rectangle"
        case .sources: "externaldrive"
        case .menuDefaults: "slider.horizontal.3"
        case .shortcuts: "keyboard"
        case .advanced: "wrench.and.screwdriver"
        }
    }
}

struct SettingsView: View {
    @EnvironmentObject private var store: PreferencesStore
    @State private var section: SettingsSection = .menuViews

    var body: some View {
        NavigationSplitView {
            List(SettingsSection.allCases, selection: $section) { section in
                Label(section.title, systemImage: section.symbolName)
                    .tag(section)
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
                case .advanced:
                    AdvancedSettingsView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(.regularMaterial)
        }
    }
}

private struct GeneralSettingsView: View {
    @EnvironmentObject private var store: PreferencesStore

    var body: some View {
        FormContainer(title: "General", subtitle: "Control how MenuShelf appears in the menu bar.") {
            Toggle("Show MenuShelf item when no items are visible", isOn: Binding(
                get: { store.settings.showMenuBarItemWhenEmpty },
                set: { value in store.updateGlobalSettings { $0.showMenuBarItemWhenEmpty = value } }
            ))

            Toggle("Show icons for files and folders", isOn: Binding(
                get: { store.settings.resolvedShowFileAndFolderIcons },
                set: { value in store.updateGlobalSettings { $0.showFileAndFolderIcons = value } }
            ))

            Toggle("Show submenu for files", isOn: Binding(
                get: { store.settings.resolvedShowFileSubmenus },
                set: { value in store.updateGlobalSettings { $0.showFileSubmenus = value } }
            ))

            Toggle("Show submenu for folders", isOn: Binding(
                get: { store.settings.resolvedShowFolderSubmenus },
                set: { value in store.updateGlobalSettings { $0.showFolderSubmenus = value } }
            ))

            Picker("Open menu via keyboard shortcut", selection: Binding(
                get: { store.settings.resolvedShortcutOpenLocation },
                set: { value in store.updateGlobalSettings { $0.shortcutOpenLocation = value } }
            )) {
                ForEach(ShortcutOpenLocation.allCases) { location in
                    Text(location.label).tag(location)
                }
            }

            Picker("Global \"...\" menu item", selection: Binding(
                get: { store.settings.resolvedMoreMenuBehavior },
                set: { value in store.updateGlobalSettings { $0.moreMenuBehavior = value } }
            )) {
                ForEach(GlobalMoreMenuBehavior.allCases) { behavior in
                    Text(behavior.label).tag(behavior)
                }
            }

            Divider()

            Toggle("Show top-level folder icons", isOn: Binding(
                get: { store.settings.resolvedShowTopLevelFolderIcons },
                set: { value in store.updateGlobalSettings { $0.showTopLevelFolderIcons = value } }
            ))

            Picker("Top-level icon size", selection: Binding(
                get: { store.settings.resolvedTopLevelFolderIconSize },
                set: { value in store.updateGlobalSettings { $0.topLevelFolderIconSize = value } }
            )) {
                ForEach(FileIconSize.allCases) { size in
                    Text(size.label).tag(size)
                }
            }

            Button("Make All Menu Views Icon Only") {
                store.setAllMenuBarStyles(.iconOnly)
            }

            Text("Each visible Menu View creates one menu bar icon. Add folders and apps to a view to organize them under that icon.")
                .font(.footnote)
                .foregroundStyle(.secondary)

            Toggle("Reduce animations", isOn: Binding(
                get: { store.settings.reduceAnimations },
                set: { value in store.updateGlobalSettings { $0.reduceAnimations = value } }
            ))

            Toggle("Launch at login", isOn: Binding(
                get: { store.settings.launchAtLogin },
                set: { value in store.setLaunchAtLogin(value) }
            ))
        }
    }
}

private struct MenuViewsSettingsView: View {
    @EnvironmentObject private var store: PreferencesStore

    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                List(selection: $store.selectedMenuViewID) {
                    ForEach(store.settings.resolvedMenuViews) { view in
                        MenuViewRow(view: view, sourceCount: view.items.count)
                            .tag(Optional(view.id))
                    }
                    .onMove { source, destination in
                        store.moveMenuViews(fromOffsets: source, toOffset: destination)
                    }
                }
                .frame(minWidth: 260, idealWidth: 310)

                Divider()

                HStack {
                    Button {
                        store.addMenuView()
                    } label: {
                        Label("Add View", systemImage: "plus")
                    }

                    Button {
                        if let id = store.selectedMenuViewID {
                            store.removeMenuView(id: id)
                        }
                    } label: {
                        Label("Remove", systemImage: "minus")
                    }
                    .disabled(store.selectedMenuViewID == nil)

                    Button("Duplicate") {
                        if let id = store.selectedMenuViewID {
                            store.duplicateMenuView(id: id)
                        }
                    }
                    .disabled(store.selectedMenuViewID == nil)

                    Spacer()
                }
                .padding(10)
            }

            Group {
                if store.settings.resolvedMenuViews.isEmpty {
                    EmptyMenuViewsPanel()
                        .frame(minWidth: 430)
                } else if let id = store.selectedMenuViewID, store.menuView(id: id) != nil {
                    MenuViewDetailView(view: Binding(
                        get: { store.menuView(id: id)! },
                        set: { store.updateMenuView($0) }
                    ))
                    .frame(minWidth: 480)
                } else {
                    ContentUnavailableView("Select a Menu View", systemImage: "menubar.rectangle", description: Text("Choose a menu bar icon/view from the list, or create a new one."))
                        .frame(minWidth: 430)
                }
            }
        }
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
                    }
                    .onMove { source, destination in
                        store.moveFolders(fromOffsets: source, toOffset: destination)
                    }
                }
                .frame(minWidth: 260, idealWidth: 310)

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

            Group {
                if store.settings.folders.isEmpty {
                    OnboardingPanel()
                        .frame(minWidth: 430)
                } else if let id = store.selectedFolderID, store.folder(id: id) != nil {
                    FolderDetailView(config: Binding(
                        get: { store.folder(id: id)! },
                        set: { store.updateFolder($0) }
                    ))
                    .frame(minWidth: 480)
                } else {
                    ContentUnavailableView("Select a Source", systemImage: "externaldrive", description: Text("Choose a folder or app source from the library."))
                        .frame(minWidth: 430)
                }
            }
        }
    }
}

private struct MenuViewRow: View {
    let view: MenuViewConfig
    let sourceCount: Int

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: view.isVisible ? "menubar.rectangle" : "menubar.dock.rectangle.badge.record")
                .foregroundStyle(view.isVisible ? .primary : .secondary)

            VStack(alignment: .leading, spacing: 2) {
                Text(view.title)
                    .lineLimit(1)
                Text("\(sourceCount) source\(sourceCount == 1 ? "" : "s")")
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

private struct MenuViewDetailView: View {
    @EnvironmentObject private var store: PreferencesStore
    @Binding var view: MenuViewConfig

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                Header(title: view.title, subtitle: "Menu bar icon with \(view.items.count) source\(view.items.count == 1 ? "" : "s")", symbolName: "menubar.rectangle")

                SettingsCard("Menu View") {
                    TextField("Title", text: $view.title)
                    Toggle("Visible in menu bar", isOn: $view.isVisible)

                    Picker("Menu bar style", selection: $view.menuBarStyle) {
                        ForEach(MenuBarStyle.allCases) { style in
                            Text(style.label).tag(style)
                        }
                    }
                    .pickerStyle(.segmented)

                    Picker("Layout", selection: Binding(
                        get: { view.resolvedLayout },
                        set: { view.layout = $0 }
                    )) {
                        ForEach(MenuViewLayout.allCases) { layout in
                            Text(layout.label).tag(layout)
                        }
                    }

                    Picker("Shortcut opens", selection: Binding(
                        get: { view.openLocation ?? store.settings.resolvedShortcutOpenLocation },
                        set: { view.openLocation = $0 }
                    )) {
                        ForEach(ShortcutOpenLocation.allCases) { location in
                            Text(location.label).tag(location)
                        }
                    }

                    ShortcutRecorderView(shortcut: $view.shortcut)
                        .frame(width: 220, height: 34)
                }

                SettingsCard("Icon") {
                    HStack {
                        Button("Use Folder Icon") { view.icon = .folderIcon }
                        Button("Use Monogram") { view.icon = .monogram(String(view.title.prefix(1))) }
                        Button("Choose Custom Image") { store.selectCustomIconForMenuView(id: view.id) }
                    }

                    TextField("SF Symbol", text: Binding(
                        get: {
                            if case .systemSymbol(let name, _) = view.icon { return name }
                            return "folder"
                        },
                        set: { view.icon = .systemSymbol(name: $0, tint: nil) }
                    ))

                    TextField("Emoji", text: Binding(
                        get: {
                            if case .emoji(let emoji) = view.icon { return emoji }
                            return ""
                        },
                        set: { value in
                            if !value.isEmpty { view.icon = .emoji(value) }
                        }
                    ))

                    ColorPicker("Color", selection: Binding(
                        get: { Color(hexString: view.iconColorHex) },
                        set: { value in view.iconColorHex = value.hexString }
                    ))

                    Button("Clear Color") {
                        view.iconColorHex = nil
                    }
                }

                SettingsCard("View Contents") {
                    HStack {
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

                        Menu {
                            ForEach(store.settings.folders) { source in
                                Button(source.displayName) {
                                    store.attachSource(source.id, toMenuViewID: view.id)
                                }
                            }
                        } label: {
                            Label("Add Existing Source", systemImage: "plus.square.on.square")
                        }

                        Button {
                            if let id = store.selectedMenuViewItemID {
                                store.removeMenuViewItem(viewID: view.id, itemID: id)
                            }
                        } label: {
                            Label("Remove", systemImage: "minus")
                        }
                        .disabled(store.selectedMenuViewItemID == nil)

                        Spacer()
                    }

                    List(selection: $store.selectedMenuViewItemID) {
                        ForEach(view.items) { item in
                            MenuViewItemRow(item: item, source: store.folder(id: item.sourceID))
                                .tag(Optional(item.id))
                        }
                        .onMove { source, destination in
                            view.items.move(fromOffsets: source, toOffset: destination)
                        }
                    }
                    .frame(minHeight: 170)

                    if let itemBinding = selectedItemBinding {
                        MenuViewItemEditor(item: itemBinding, source: store.folder(id: itemBinding.wrappedValue.sourceID))
                    }
                }

                SettingsCard("Menu Behavior") {
                    MenuSettingsEditor(settings: $view.menuSettings)
                }
            }
            .padding(28)
            .frame(maxWidth: 760, alignment: .leading)
        }
    }

    private var selectedItemBinding: Binding<MenuViewItem>? {
        guard let id = store.selectedMenuViewItemID,
              let index = view.items.firstIndex(where: { $0.id == id }) else {
            return nil
        }

        return Binding(
            get: { view.items[index] },
            set: { updated in
                var copy = updated
                copy.updatedAt = Date()
                view.items[index] = copy
            }
        )
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
                Text(item.titleOverride?.isEmpty == false ? item.titleOverride! : (source?.displayName ?? "Missing Source"))
                    .lineLimit(1)
                Text(item.sectionName?.isEmpty == false ? "Section: \(item.sectionName!)" : (source?.originalPathHint ?? "Source no longer exists"))
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
            VStack(alignment: .leading, spacing: 22) {
                Header(title: config.displayName, subtitle: "\(config.resolvedItemKind.label) - \(config.originalPathHint)", symbolName: config.resolvedItemKind.symbolName)

                SettingsCard("Source") {
                    TextField("Display name", text: $config.displayName)

                    if config.resolvedItemKind == .folder {
                        Picker("Folder click behavior", selection: $config.openBehavior) {
                            ForEach(OpenBehavior.allCases) { behavior in
                                Text(behavior.label).tag(behavior)
                            }
                        }
                    } else {
                        Text("Apps launch directly when selected from a Menu View.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }

                SettingsCard("Icon") {
                    HStack {
                        Button("Use Folder Icon") { config.icon = .folderIcon }
                        Button("Use Monogram") { config.icon = .monogram(String(config.displayName.prefix(1))) }
                        Button("Choose Custom Image") { store.selectCustomIcon(for: config.id) }
                    }

                    TextField("SF Symbol", text: Binding(
                        get: {
                            if case .systemSymbol(let name, _) = config.icon { return name }
                            return "folder"
                        },
                        set: { config.icon = .systemSymbol(name: $0, tint: nil) }
                    ))

                    ColorPicker("Color", selection: Binding(
                        get: { Color(hexString: config.iconColorHex) },
                        set: { value in config.iconColorHex = value.hexString }
                    ))

                    Button("Clear Color") {
                        config.iconColorHex = nil
                    }

                    TextField("Emoji", text: Binding(
                        get: {
                            if case .emoji(let emoji) = config.icon { return emoji }
                            return ""
                        },
                        set: { value in
                            if !value.isEmpty { config.icon = .emoji(value) }
                        }
                    ))
                }

                SettingsCard("Menu") {
                    MenuSettingsEditor(settings: $config.menuSettings)
                }
            }
            .padding(28)
            .frame(maxWidth: 680, alignment: .leading)
        }
    }
}

private struct MenuDefaultsSettingsView: View {
    @EnvironmentObject private var store: PreferencesStore

    var body: some View {
        FormContainer(title: "Menu Defaults", subtitle: "Defaults are applied to newly added folders. Existing items keep their own settings.") {
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
        Picker("Sort by", selection: $settings.sortKey) {
            ForEach(SortKey.allCases) { sort in
                Text(sort.label).tag(sort)
            }
        }

        Picker("Direction", selection: $settings.sortDirection) {
            ForEach(SortDirection.allCases) { direction in
                Text(direction.label).tag(direction)
            }
        }
        .pickerStyle(.segmented)

        Picker("Filter", selection: $settings.filterMode) {
            ForEach(FilterMode.allCases) { mode in
                Text(mode.label).tag(mode)
            }
        }

        Picker("File icon size", selection: Binding(
            get: { settings.resolvedFileIconSize },
            set: { settings.fileIconSize = $0 }
        )) {
            ForEach(FileIconSize.allCases) { size in
                Text(size.label).tag(size)
            }
        }

        Toggle("Keep folders on top", isOn: $settings.keepFoldersOnTop)
        Toggle("Keep apps on top", isOn: $settings.keepAppsOnTop)
        Toggle("Show hidden files", isOn: $settings.showHiddenFiles)
        Toggle("Show folder title", isOn: Binding(
            get: { settings.resolvedShowFolderTitle },
            set: { settings.showFolderTitle = $0 }
        ))
        Toggle("Show \"Open With\" menu for subfolders", isOn: Binding(
            get: { settings.resolvedShowOpenWithForSubfolders },
            set: { settings.showOpenWithForSubfolders = $0 }
        ))
        Toggle("Show file extensions", isOn: $settings.showFileExtensions)
        Toggle("Show file previews", isOn: $settings.showPreview)
        Toggle("Show metadata", isOn: $settings.showMetadata)
        Toggle("Show tips in file submenus", isOn: Binding(
            get: { settings.resolvedShowTips },
            set: { settings.showTips = $0 }
        ))
        Toggle("Reveal extra copy actions with Option", isOn: Binding(
            get: { settings.resolvedEnableModifierActions },
            set: { settings.enableModifierActions = $0 }
        ))
        Toggle("Resolve Finder aliases", isOn: $settings.followAliases)
        Toggle("Resolve symlinks", isOn: $settings.followSymlinks)

        Toggle("Limit visible items", isOn: Binding(
            get: { settings.maxItems != nil },
            set: { enabled in settings.maxItems = enabled ? (settings.maxItems ?? 200) : nil }
        ))

        if settings.maxItems != nil {
            Stepper("Max visible items: \(settings.maxItems ?? 200)", value: Binding(
                get: { settings.maxItems ?? 200 },
                set: { settings.maxItems = $0 }
            ), in: 20...2000, step: 10)
        }

        Picker("More item", selection: $settings.showMoreItemPosition) {
            ForEach(MoreItemPosition.allCases) { position in
                Text(position.label).tag(position)
            }
        }
    }
}

private struct OnboardingPanel: View {
    @EnvironmentObject private var store: PreferencesStore

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            Header(title: "Put folders and apps in your menu bar.", subtitle: "Add folders to browse and apps to launch from a native menu.", symbolName: "menubar.rectangle")

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
            Header(title: "Create menu views.", subtitle: "Each visible view becomes one menu bar icon. Add folders and apps inside a view to keep different workspaces organized.", symbolName: "menubar.rectangle")

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

    var body: some View {
        FormContainer(title: "Shortcuts", subtitle: "Open Menu Views with global keyboard shortcuts and automate visibility from Shortcuts.") {
            ForEach(store.settings.resolvedMenuViews) { view in
                HStack {
                    VStack(alignment: .leading) {
                        Text(view.title)
                        Text("\(view.items.count) source\(view.items.count == 1 ? "" : "s")")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }

                    Spacer()

                    ShortcutRecorderView(shortcut: Binding(
                        get: { store.menuView(id: view.id)?.shortcut ?? .disabled },
                        set: { shortcut in
                            guard var updated = store.menuView(id: view.id) else { return }
                            updated.shortcut = shortcut
                            store.updateMenuView(updated)
                        }
                    ))
                    .frame(width: 200, height: 32)
                }
                Divider()
            }

            Button("Open Shortcuts") {
                NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Shortcuts.app"))
            }

            Text("Shortcuts exposes Set Menu View Visibility and Open Menu View actions for project workflows.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }
}

private struct AdvancedSettingsView: View {
    @EnvironmentObject private var store: PreferencesStore

    var body: some View {
        FormContainer(title: "Advanced", subtitle: "Local-only diagnostics and privacy controls.") {
            Button("Clear Last Error") {
                store.lastErrorMessage = nil
            }

            Button("Clear Diagnostics Log") {
                DiagnosticsLogger.shared.clear()
            }

            Text("Diagnostics log: \(DiagnosticsLogger.shared.logURL.path)")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)

            if let error = store.lastErrorMessage {
                Text(error)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }

            Text("MenuShelf does not need network access for core functionality. File previews and metadata are generated locally from folders and apps you explicitly choose.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct FormContainer<Content: View>: View {
    let title: String
    let subtitle: String
    @ViewBuilder let content: Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                Header(title: title, subtitle: subtitle, symbolName: nil)
                SettingsCard(nil) {
                    content
                }
            }
            .padding(32)
            .frame(maxWidth: 720, alignment: .leading)
        }
    }
}

private struct Header: View {
    let title: String
    let subtitle: String
    let symbolName: String?

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            if let symbolName {
                Image(systemName: symbolName)
                    .font(.system(size: 34, weight: .semibold))
                    .symbolRenderingMode(.hierarchical)
                    .frame(width: 44, height: 44)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .font(.largeTitle.bold())
                    .lineLimit(2)
                Text(subtitle)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

private struct SettingsCard<Content: View>: View {
    let title: String?
    @ViewBuilder let content: Content

    init(_ title: String?, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let title {
                Text(title)
                    .font(.headline)
            }

            VStack(alignment: .leading, spacing: 12) {
                content
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(Color(nsColor: .separatorColor).opacity(0.35))
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
