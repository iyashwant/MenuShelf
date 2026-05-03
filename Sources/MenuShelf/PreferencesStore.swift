import AppKit
import Combine
import Foundation
import UniformTypeIdentifiers

final class PreferencesStore: ObservableObject {
    @Published var settings: AppSettings {
        didSet { save() }
    }

    @Published var selectedMenuViewID: UUID?
    @Published var selectedMenuViewItemID: UUID?
    @Published var selectedFolderID: UUID?
    @Published var lastErrorMessage: String?

    private let settingsURL: URL
    private let supportURL: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private let launchAtLoginService = LaunchAtLoginService()

    init() {
        supportURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first!
            .appendingPathComponent("MenuShelf", isDirectory: true)

        try? FileManager.default.createDirectory(at: supportURL, withIntermediateDirectories: true)

        settingsURL = supportURL.appendingPathComponent("settings.json")

        encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601

        decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        if let data = try? Data(contentsOf: settingsURL),
           let decoded = try? decoder.decode(AppSettings.self, from: data) {
            let migrated = Self.migratedSettings(decoded)
            settings = migrated
            if migrated != decoded {
                try? encoder.encode(migrated).write(to: settingsURL, options: [.atomic])
            }
        } else {
            settings = .defaults
        }

        selectedMenuViewID = settings.resolvedMenuViews.first?.id
        selectedMenuViewItemID = settings.resolvedMenuViews.first?.items.first?.id
        selectedFolderID = settings.folders.first?.id
    }

    func addFolderFromPanel(startingAt initialURL: URL? = nil) {
        let panel = NSOpenPanel()
        panel.title = "Add Folder to MenuShelf"
        panel.message = "Choose folders to browse from the menu bar."
        panel.prompt = "Add Folder"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.canCreateDirectories = false
        panel.directoryURL = initialURL

        guard panel.runModal() == .OK else { return }

        for url in panel.urls {
            do {
                try addFolder(url)
            } catch {
                showError("Could not add \(url.lastPathComponent): \(error.localizedDescription)")
            }
        }
    }

    func addAppFromPanel() {
        let panel = NSOpenPanel()
        panel.title = "Add App to MenuShelf"
        panel.message = "Choose apps to launch from the menu bar."
        panel.prompt = "Add App"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.canCreateDirectories = false
        panel.directoryURL = URL(fileURLWithPath: "/Applications", isDirectory: true)
        panel.treatsFilePackagesAsDirectories = false
        panel.allowsOtherFileTypes = false
        panel.allowedContentTypes = appContentTypes()

        guard panel.runModal() == .OK else { return }

        for url in panel.urls {
            do {
                try addFolder(url)
            } catch {
                showError("Could not add \(url.lastPathComponent): \(error.localizedDescription)")
            }
        }
    }

    @discardableResult
    func addFolder(_ url: URL, attachToMenuViewID: UUID? = nil) throws -> FolderConfig {
        if url.pathExtension.lowercased() == "savedsearch" {
            throw NSError(
                domain: "MenuShelf",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "Smart Folders cannot be added because their Finder search behavior cannot be reproduced inside a sandboxed menu."]
            )
        }

        guard let itemKind = itemKind(for: url) else {
            throw NSError(
                domain: "MenuShelf",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Choose a folder or .app bundle."]
            )
        }

        let bookmarkData = try url.bookmarkData(
            options: [.withSecurityScope],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )

        let config = FolderConfig.make(url: url, bookmarkData: bookmarkData, defaults: settings.defaultMenuSettings, itemKind: itemKind)
        settings.folders.append(config)
        attachSource(config.id, toMenuViewID: attachToMenuViewID ?? selectedMenuViewID)
        selectedFolderID = config.id
        selectedMenuViewItemID = menuView(id: selectedMenuViewID)?.items.last?.id
        DiagnosticsLogger.shared.log("Added \(itemKind.rawValue): \(config.displayName). Total items: \(settings.folders.count)")
        return config
    }

    func setAllMenuBarStyles(_ style: MenuBarStyle) {
        guard var views = settings.menuViews else { return }
        for index in views.indices {
            views[index].menuBarStyle = style
            views[index].updatedAt = Date()
        }
        settings.menuViews = views
        DiagnosticsLogger.shared.log("Set all folder menu bar styles to \(style.rawValue)")
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            try launchAtLoginService.setEnabled(enabled)
            settings.launchAtLogin = enabled
        } catch {
            showError(error.localizedDescription)
        }
    }

    func removeFolder(id: UUID) {
        settings.folders.removeAll { $0.id == id }
        removeSourceFromAllMenuViews(sourceID: id)
        if selectedFolderID == id {
            selectedFolderID = settings.folders.first?.id
        }
    }

    func duplicateFolder(id: UUID) {
        guard var config = folder(id: id) else { return }
        config.id = UUID()
        config.displayName += " Copy"
        config.createdAt = Date()
        config.updatedAt = Date()
        settings.folders.append(config)
        attachSource(config.id, toMenuViewID: selectedMenuViewID)
        selectedFolderID = config.id
    }

    func setFolderVisibility(id: UUID, isVisible: Bool) {
        setMenuViewVisibility(id: id, isVisible: isVisible)
    }

    func showOnlyFolder(id: UUID) {
        showOnlyMenuView(id: id)
    }

    func showAllFolders() {
        showAllMenuViews()
    }

    func folder(id: UUID) -> FolderConfig? {
        settings.folders.first { $0.id == id }
    }

    func updateFolder(_ config: FolderConfig) {
        guard let index = settings.folders.firstIndex(where: { $0.id == config.id }) else { return }
        var updated = config
        updated.updatedAt = Date()
        settings.folders[index] = updated
    }

    func moveFolders(fromOffsets source: IndexSet, toOffset destination: Int) {
        settings.folders.move(fromOffsets: source, toOffset: destination)
    }

    func menuView(id: UUID?) -> MenuViewConfig? {
        guard let id else { return nil }
        return settings.resolvedMenuViews.first { $0.id == id }
    }

    func updateMenuView(_ view: MenuViewConfig) {
        var views = settings.resolvedMenuViews
        guard let index = views.firstIndex(where: { $0.id == view.id }) else { return }
        var updated = view
        updated.updatedAt = Date()
        views[index] = updated
        settings.menuViews = views
    }

    func addMenuView(title: String = "New Menu") {
        var views = settings.resolvedMenuViews
        let view = MenuViewConfig.make(title: title, defaults: settings.defaultMenuSettings)
        views.append(view)
        settings.menuViews = views
        selectedMenuViewID = view.id
        selectedMenuViewItemID = nil
    }

    func duplicateMenuView(id: UUID) {
        guard var view = menuView(id: id) else { return }
        view.id = UUID()
        view.title += " Copy"
        view.shortcut = .disabled
        view.items = view.items.map { item in
            var copy = item
            copy.id = UUID()
            copy.createdAt = Date()
            copy.updatedAt = Date()
            return copy
        }
        view.createdAt = Date()
        view.updatedAt = Date()
        var views = settings.resolvedMenuViews
        views.append(view)
        settings.menuViews = views
        selectedMenuViewID = view.id
        selectedMenuViewItemID = view.items.first?.id
    }

    func removeMenuView(id: UUID) {
        var views = settings.resolvedMenuViews
        views.removeAll { $0.id == id }
        if views.isEmpty, !settings.folders.isEmpty {
            views.append(MenuViewConfig.make(title: "MenuShelf", defaults: settings.defaultMenuSettings, sourceIDs: settings.folders.map(\.id)))
        }
        settings.menuViews = views
        if selectedMenuViewID == id {
            selectedMenuViewID = views.first?.id
            selectedMenuViewItemID = views.first?.items.first?.id
        }
    }

    func moveMenuViews(fromOffsets source: IndexSet, toOffset destination: Int) {
        var views = settings.resolvedMenuViews
        views.move(fromOffsets: source, toOffset: destination)
        settings.menuViews = views
    }

    func moveMenuViewItems(viewID: UUID, fromOffsets source: IndexSet, toOffset destination: Int) {
        guard var view = menuView(id: viewID) else { return }
        view.items.move(fromOffsets: source, toOffset: destination)
        updateMenuView(view)
    }

    func attachSource(_ sourceID: UUID, toMenuViewID menuViewID: UUID?) {
        var views = settings.resolvedMenuViews
        let targetID: UUID

        if let menuViewID, views.contains(where: { $0.id == menuViewID }) {
            targetID = menuViewID
        } else {
            let view = MenuViewConfig.make(title: "MenuShelf", defaults: settings.defaultMenuSettings)
            views.append(view)
            targetID = view.id
            selectedMenuViewID = targetID
        }

        guard let index = views.firstIndex(where: { $0.id == targetID }) else { return }
        guard !views[index].items.contains(where: { $0.sourceID == sourceID }) else {
            settings.menuViews = views
            return
        }

        views[index].items.append(MenuViewItem.make(sourceID: sourceID))
        views[index].updatedAt = Date()
        settings.menuViews = views
    }

    func removeMenuViewItem(viewID: UUID, itemID: UUID) {
        guard var view = menuView(id: viewID) else { return }
        view.items.removeAll { $0.id == itemID }
        updateMenuView(view)
        if selectedMenuViewItemID == itemID {
            selectedMenuViewItemID = view.items.first?.id
        }
    }

    func setMenuViewVisibility(id: UUID, isVisible: Bool) {
        guard var view = menuView(id: id) else { return }
        view.isVisible = isVisible
        updateMenuView(view)
    }

    func showOnlyMenuView(id: UUID) {
        var views = settings.resolvedMenuViews
        for index in views.indices {
            views[index].isVisible = views[index].id == id
            views[index].updatedAt = Date()
        }
        settings.menuViews = views
    }

    func showAllMenuViews() {
        var views = settings.resolvedMenuViews
        for index in views.indices {
            views[index].isVisible = true
            views[index].updatedAt = Date()
        }
        settings.menuViews = views
    }

    private func removeSourceFromAllMenuViews(sourceID: UUID) {
        var views = settings.resolvedMenuViews
        for index in views.indices {
            views[index].items.removeAll { $0.sourceID == sourceID }
            views[index].updatedAt = Date()
        }
        settings.menuViews = views
    }

    func setDisplayMode(_ mode: DisplayMode) {
        settings.displayMode = mode
    }

    func updateGlobalSettings(_ update: (inout AppSettings) -> Void) {
        update(&settings)
    }

    func revealInFinder(id: UUID) {
        guard let config = folder(id: id) else { return }

        do {
            let access = try FileAccessService().accessFolder(config)
            NSWorkspace.shared.activateFileViewerSelecting([access.url])
        } catch {
            showError(error.localizedDescription)
        }
    }

    func reselectFolder(id: UUID) {
        let panel = NSOpenPanel()
        panel.title = "Locate Item"
        panel.message = "Choose the folder or app again to refresh MenuShelf's access."
        panel.prompt = "Update Access"
        let currentKind = folder(id: id)?.resolvedItemKind ?? .folder
        panel.canChooseFiles = currentKind == .app
        panel.canChooseDirectories = currentKind == .folder
        panel.allowsMultipleSelection = false
        panel.treatsFilePackagesAsDirectories = false
        panel.allowedContentTypes = currentKind == .app ? appContentTypes() : [.folder]
        if currentKind == .app {
            panel.directoryURL = URL(fileURLWithPath: "/Applications", isDirectory: true)
            panel.allowsOtherFileTypes = false
        }

        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            guard let itemKind = itemKind(for: url) else {
                throw NSError(
                    domain: "MenuShelf",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "Choose a folder or .app bundle."]
                )
            }

            let bookmarkData = try url.bookmarkData(
                options: [.withSecurityScope],
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
            guard var config = folder(id: id) else { return }
            config.bookmarkData = bookmarkData
            config.originalPathHint = url.path
            config.displayName = FileManager.default.displayName(atPath: url.path)
            config.itemKind = itemKind
            updateFolder(config)
        } catch {
            showError(error.localizedDescription)
        }
    }

    func selectCustomIcon(for id: UUID) {
        let panel = NSOpenPanel()
        panel.title = "Choose Custom Icon"
        panel.message = "Choose an image to use as this menu bar icon."
        panel.prompt = "Choose"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.allowedContentTypes = [.image]

        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            let iconsURL = supportURL.appendingPathComponent("Icons", isDirectory: true)
            try FileManager.default.createDirectory(at: iconsURL, withIntermediateDirectories: true)
            let destination = iconsURL.appendingPathComponent("\(id.uuidString).\(url.pathExtension.isEmpty ? "png" : url.pathExtension)")
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.copyItem(at: url, to: destination)
            let bookmarkData = try destination.bookmarkData(
                options: [.withSecurityScope],
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )

            guard var config = folder(id: id) else { return }
            config.icon = .customImage(bookmarkData: bookmarkData)
            config.iconColorHex = nil
            updateFolder(config)
        } catch {
            showError("Could not use custom icon: \(error.localizedDescription)")
        }
    }

    func selectCustomIconForMenuView(id: UUID) {
        let panel = NSOpenPanel()
        panel.title = "Choose Menu View Icon"
        panel.message = "Choose an image to use for this menu bar icon."
        panel.prompt = "Choose"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.allowedContentTypes = [.image]

        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            let iconsURL = supportURL.appendingPathComponent("Icons", isDirectory: true)
            try FileManager.default.createDirectory(at: iconsURL, withIntermediateDirectories: true)
            let destination = iconsURL.appendingPathComponent("\(id.uuidString).\(url.pathExtension.isEmpty ? "png" : url.pathExtension)")
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.copyItem(at: url, to: destination)
            let bookmarkData = try destination.bookmarkData(
                options: [.withSecurityScope],
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )

            guard var view = menuView(id: id) else { return }
            view.icon = .customImage(bookmarkData: bookmarkData)
            view.iconColorHex = nil
            updateMenuView(view)
        } catch {
            showError("Could not use custom icon: \(error.localizedDescription)")
        }
    }

    func showError(_ message: String) {
        lastErrorMessage = message

        let alert = NSAlert()
        alert.messageText = "MenuShelf"
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.runModal()
    }

    private func save() {
        do {
            let data = try encoder.encode(settings)
            try data.write(to: settingsURL, options: [.atomic])
        } catch {
            lastErrorMessage = "Could not save settings: \(error.localizedDescription)"
        }
    }

    private static func migratedSettings(_ decoded: AppSettings) -> AppSettings {
        var settings = decoded

        if settings.schemaVersion < 2 {
            settings.schemaVersion = 2
            for index in settings.folders.indices {
                settings.folders[index].menuBarStyle = .iconOnly
                settings.folders[index].updatedAt = Date()
            }
        }

        if settings.schemaVersion < 3 {
            settings.schemaVersion = 3
            settings.displayMode = .groupedItem
        }

        if settings.schemaVersion < 4 {
            settings.schemaVersion = 4
            for index in settings.folders.indices {
                if settings.folders[index].itemKind == nil {
                    settings.folders[index].itemKind = settings.folders[index].originalPathHint.hasSuffix(".app") ? .app : .folder
                }
            }
        }

        if settings.schemaVersion < 5 {
            settings.schemaVersion = 5
        }

        if settings.schemaVersion < 6 {
            settings.schemaVersion = 6
        }

        settings.showFileAndFolderIcons = settings.showFileAndFolderIcons ?? true
        settings.showFileSubmenus = settings.showFileSubmenus ?? true
        settings.showFolderSubmenus = settings.showFolderSubmenus ?? true
        settings.shortcutOpenLocation = settings.shortcutOpenLocation ?? .menuBarItem
        settings.showTopLevelFolderIcons = settings.showTopLevelFolderIcons ?? true
        settings.topLevelFolderIconSize = settings.topLevelFolderIconSize ?? .small
        settings.moreMenuBehavior = settings.moreMenuBehavior ?? .visibleAtBottom
        applyMenuSettingsDefaults(&settings.defaultMenuSettings)

        for index in settings.folders.indices {
            applyMenuSettingsDefaults(&settings.folders[index].menuSettings)
            if settings.folders[index].shortcut == nil {
                settings.folders[index].shortcut = .disabled
            }
        }

        if settings.menuViews == nil || settings.menuViews?.isEmpty == true {
            let sourceIDs = settings.folders.map(\.id)
            settings.menuViews = sourceIDs.isEmpty
                ? []
                : [MenuViewConfig.make(title: "MenuShelf", defaults: settings.defaultMenuSettings, sourceIDs: sourceIDs)]
        }

        var views = settings.resolvedMenuViews
        for index in views.indices {
            applyMenuSettingsDefaults(&views[index].menuSettings)
            views[index].shortcut = views[index].shortcut ?? .disabled
            views[index].layout = views[index].layout ?? .automatic
            views[index].items = views[index].items.filter { item in
                settings.folders.contains { $0.id == item.sourceID }
            }
        }
        settings.menuViews = views

        return settings
    }

    private static func applyMenuSettingsDefaults(_ menuSettings: inout MenuSettings) {
        menuSettings.fileIconSize = menuSettings.fileIconSize ?? .medium
        menuSettings.showFolderTitle = menuSettings.showFolderTitle ?? true
        menuSettings.showOpenWithForSubfolders = menuSettings.showOpenWithForSubfolders ?? false
        menuSettings.showTips = menuSettings.showTips ?? true
        menuSettings.enableModifierActions = menuSettings.enableModifierActions ?? true
    }

    private func itemKind(for url: URL) -> ShelfItemKind? {
        if url.pathExtension.lowercased() == "app" {
            return .app
        }

        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue {
            return .folder
        }

        return nil
    }

    private func appContentTypes() -> [UTType] {
        var types: [UTType] = []
        if #available(macOS 11.0, *) {
            types.append(.applicationBundle)
        }
        if let appType = UTType(filenameExtension: "app") {
            types.append(appType)
        }
        return types
    }
}
