import AppKit
import Combine
import Foundation
import UniformTypeIdentifiers

final class PreferencesStore: ObservableObject {
    @Published var settings: AppSettings {
        didSet { scheduleSave() }
    }

    @Published var selectedMenuViewID: UUID?
    @Published var selectedMenuViewItemID: UUID?
    @Published var selectedFolderID: UUID?
    @Published var selectedAppleScriptID: UUID?
    @Published var lastErrorMessage: String?
    @Published var availableShortcuts: [ShortcutInfo] = []
    @Published var availableShortcutFolders: [ShortcutsFolderInfo] = []
    @Published var shortcutsByFolder: [String: [ShortcutInfo]] = [:]
    @Published var isRefreshingShortcuts = false
    @Published var lastAppleScriptRuns: [UUID: AppleScriptRunRecord] = [:]
    @Published var discoveredBrowsers: [BrowserInfo] = []
    @Published var currentDefaultBrowserID: String?

    private let settingsURL: URL
    let supportURL: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private let launchAtLoginService = LaunchAtLoginService()
    let shortcutsService: ShortcutsService
    private let fileAccessService: FileAccessService

    // Persistence is debounced to coalesce rapid mutations (e.g. typing in
    // a TextField) into a single off-main write. Flush on app terminate or
    // settings-window close so changes always land on disk before exit.
    private let saveQueue = DispatchQueue(label: "com.menushelf.settings-save", qos: .utility)
    private var pendingSave: DispatchWorkItem?
    private let saveDebounce: TimeInterval = 0.4

    init(shortcutsService: ShortcutsService = ShortcutsService(),
         fileAccessService: FileAccessService = FileAccessService()) {
        self.shortcutsService = shortcutsService
        self.fileAccessService = fileAccessService
        let resolvedSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        supportURL = resolvedSupport.appendingPathComponent("MenuShelf", isDirectory: true)

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

        DiagnosticsLogger.shared.setEnabled(settings.resolvedEnableVerboseDiagnostics)
        DiagnosticsLogger.shared.beginSession(settings: settings)

        refreshShortcutsCatalog(showErrors: false)
    }

    func addFolderFromPanel(startingAt initialURL: URL? = nil) {
        let panel = NSOpenPanel()
        panel.title = "Add Folder to MenuShelf"
        panel.message = "Choose folders to browse from the menu bar."
        panel.prompt = "Add Folder"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.canCreateDirectories = true
        panel.directoryURL = initialURL

        // Activate so the modal panel doesn't appear behind whatever's frontmost
        // when triggered from a menu bar click.
        NSApp.activate(ignoringOtherApps: true)
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

        NSApp.activate(ignoringOtherApps: true)
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
        // Drop any cached resolved URL so removed folders don't linger in
        // FileAccessService. The bookmark hash check would also evict on next
        // access, but here we know the folder will never be accessed again.
        fileAccessService.invalidateCache(for: id)
        if selectedFolderID == id {
            selectedFolderID = settings.folders.first?.id
        }
    }

    func duplicateFolder(id: UUID) {
        guard var config = folder(id: id) else { return }
        config.id = UUID()
        config.displayName = nextCopyName(
            base: config.displayName,
            existing: settings.folders.map(\.displayName)
        )
        config.createdAt = Date()
        config.updatedAt = Date()
        settings.folders.append(config)
        attachSource(config.id, toMenuViewID: selectedMenuViewID)
        selectedFolderID = config.id
    }

    func setFolderVisibility(id: UUID, isVisible: Bool) {
        setMenuViewVisibility(id: id, isVisible: isVisible)
    }

    /// Produce a Finder-style copy name. Strips any trailing " copy"/" copy N" /
    /// " Copy"/" Copy N" suffix from `base` and appends " copy", " copy 2",
    /// " copy 3", … until the name is unique among `existing`.
    private func nextCopyName(base: String, existing: [String]) -> String {
        // Match either " copy" or " Copy", optionally followed by " <N>" at end.
        let pattern = #"\s+[Cc]opy(?:\s+\d+)?$"#
        let stripped: String
        if let regex = try? NSRegularExpression(pattern: pattern) {
            let range = NSRange(base.startIndex..<base.endIndex, in: base)
            stripped = regex.stringByReplacingMatches(in: base, range: range, withTemplate: "")
        } else {
            stripped = base
        }

        let used = Set(existing)
        let firstCandidate = "\(stripped) copy"
        if !used.contains(firstCandidate) { return firstCandidate }

        var n = 2
        while true {
            let candidate = "\(stripped) copy \(n)"
            if !used.contains(candidate) { return candidate }
            n += 1
            if n > 9999 { return "\(stripped) copy \(UUID().uuidString.prefix(4))" }
        }
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
        view.title = nextCopyName(
            base: view.title,
            existing: settings.resolvedMenuViews.map(\.title)
        )
        view.shortcut = .disabled
        view.items = view.items.map { item in
            var copy = item
            copy.id = UUID()
            copy.createdAt = Date()
            copy.updatedAt = Date()
            return copy
        }
        view.linkedMenuViews = view.resolvedLinkedMenuViews.map { linkedView in
            var copy = linkedView
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
        for index in views.indices {
            views[index].linkedMenuViews = views[index].resolvedLinkedMenuViews.filter { $0.menuViewID != id }
        }
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

    func addShortcut(_ shortcut: ShortcutInfo, toMenuViewID menuViewID: UUID?) {
        var views = settings.resolvedMenuViews
        let targetID: UUID

        if let menuViewID, views.contains(where: { $0.id == menuViewID }) {
            targetID = menuViewID
        } else {
            let view = MenuViewConfig.make(title: "Shortcuts", defaults: settings.defaultMenuSettings)
            views.append(view)
            targetID = view.id
            selectedMenuViewID = targetID
        }

        guard let index = views.firstIndex(where: { $0.id == targetID }) else { return }
        var shortcuts = views[index].resolvedShortcutItems
        guard !shortcuts.contains(where: { ($0.shortcutIdentifier ?? $0.name) == (shortcut.identifier ?? shortcut.name) }) else {
            settings.menuViews = views
            return
        }

        shortcuts.append(.make(shortcut: shortcut))
        views[index].shortcutItems = shortcuts
        views[index].updatedAt = Date()
        settings.menuViews = views
        selectedMenuViewID = targetID
    }

    func addLinkedShortcutsFolder(_ folder: ShortcutsFolderInfo, toMenuViewID menuViewID: UUID?) {
        var views = settings.resolvedMenuViews
        let targetID: UUID

        if let menuViewID, views.contains(where: { $0.id == menuViewID }) {
            targetID = menuViewID
        } else {
            let view = MenuViewConfig.make(title: "Shortcuts", defaults: settings.defaultMenuSettings)
            views.append(view)
            targetID = view.id
            selectedMenuViewID = targetID
        }

        guard let index = views.firstIndex(where: { $0.id == targetID }) else { return }
        var folders = views[index].resolvedLinkedShortcutsFolders
        guard !folders.contains(where: { ($0.shortcutFolderIdentifier ?? $0.folderName) == (folder.identifier ?? folder.name) }) else {
            settings.menuViews = views
            return
        }

        folders.append(.make(folder: folder))
        views[index].linkedShortcutsFolders = folders
        views[index].updatedAt = Date()
        settings.menuViews = views
        selectedMenuViewID = targetID
        refreshLinkedShortcutsFolder(folder.name, showErrors: false)
    }

    func addLinkedMenuView(_ linkedMenuViewID: UUID, toMenuViewID menuViewID: UUID?) {
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

        guard linkedMenuViewID != targetID,
              let index = views.firstIndex(where: { $0.id == targetID }),
              canLinkMenuView(linkedMenuViewID, toMenuViewID: targetID, in: views) else {
            settings.menuViews = views
            return
        }

        var linkedViews = views[index].resolvedLinkedMenuViews
        guard !linkedViews.contains(where: { $0.menuViewID == linkedMenuViewID }) else {
            settings.menuViews = views
            return
        }

        linkedViews.append(.make(menuViewID: linkedMenuViewID))
        views[index].linkedMenuViews = linkedViews
        views[index].updatedAt = Date()
        settings.menuViews = views
        selectedMenuViewID = targetID
    }

    func canLinkMenuView(_ linkedMenuViewID: UUID, toMenuViewID targetID: UUID) -> Bool {
        canLinkMenuView(linkedMenuViewID, toMenuViewID: targetID, in: settings.resolvedMenuViews)
    }

    func refreshShortcutsCatalog(showErrors: Bool = true) {
        isRefreshingShortcuts = true
        let linkedFolderNames = Set(settings.resolvedMenuViews.flatMap { $0.resolvedLinkedShortcutsFolders.map(\.folderName) })
        // PreferencesStore is owned by AppContainer.shared for the app's lifetime,
        // so a strong self capture here is not a leak. We deliberately avoid
        // [weak self] which triggers Swift 6's mutable-capture warning in async
        // Tasks.
        Task { [shortcutsService, linkedFolderNames] in
            do {
                async let shortcuts = shortcutsService.listShortcuts()
                async let folders = shortcutsService.listFolders()
                let (resolvedShortcuts, resolvedFolders) = try await (shortcuts, folders)

                var folderContents: [String: [ShortcutInfo]] = [:]
                for name in linkedFolderNames {
                    do {
                        folderContents[name] = try await shortcutsService.listShortcuts(inFolder: name)
                    } catch {
                        // Treat a transient failure as "empty" rather than "still loading"
                        // so the menu doesn't stick on a permanent loading state until the
                        // user manually refreshes.
                        DiagnosticsLogger.shared.log("Could not load Shortcuts folder \(name): \(error.localizedDescription)")
                        folderContents[name] = []
                    }
                }
                let resolvedFolderContents = folderContents

                await MainActor.run {
                    self.availableShortcuts = resolvedShortcuts
                    self.availableShortcutFolders = resolvedFolders
                    self.shortcutsByFolder.merge(resolvedFolderContents) { _, new in new }
                    self.isRefreshingShortcuts = false
                }
            } catch {
                await MainActor.run {
                    self.isRefreshingShortcuts = false
                    if showErrors {
                        self.showError("Could not load Shortcuts: \(error.localizedDescription)")
                    } else {
                        self.lastErrorMessage = error.localizedDescription
                        DiagnosticsLogger.shared.log("Could not load Shortcuts: \(error.localizedDescription)")
                    }
                }
            }
        }
    }

    func refreshLinkedShortcutsFolder(_ folderName: String, showErrors: Bool = true) {
        // See refreshShortcutsCatalog above for why we capture self strongly.
        Task { [shortcutsService] in
            do {
                let shortcuts = try await shortcutsService.listShortcuts(inFolder: folderName)
                await MainActor.run {
                    self.shortcutsByFolder[folderName] = shortcuts
                }
            } catch {
                await MainActor.run {
                    // Mark as loaded-but-empty so the menu doesn't display a
                    // permanent "Loading…" state on transient failures.
                    if self.shortcutsByFolder[folderName] == nil {
                        self.shortcutsByFolder[folderName] = []
                    }
                    if showErrors {
                        self.showError("Could not load \(folderName): \(error.localizedDescription)")
                    } else {
                        DiagnosticsLogger.shared.log("Could not load linked Shortcuts folder \(folderName): \(error.localizedDescription)")
                    }
                }
            }
        }
    }

    // MARK: - AppleScripts

    func appleScript(id: UUID) -> AppleScriptConfig? {
        settings.resolvedAppleScripts.first { $0.id == id }
    }

    @discardableResult
    func addAppleScript() -> AppleScriptConfig {
        var scripts = settings.resolvedAppleScripts
        let config = AppleScriptConfig.make()
        scripts.append(config)
        settings.appleScripts = scripts
        selectedAppleScriptID = config.id
        DiagnosticsLogger.shared.log("Created AppleScript \(config.id) (\(config.name))")
        return config
    }

    func updateAppleScript(_ config: AppleScriptConfig) {
        var scripts = settings.resolvedAppleScripts
        guard let index = scripts.firstIndex(where: { $0.id == config.id }) else { return }
        var updated = config
        updated.updatedAt = Date()
        scripts[index] = updated
        settings.appleScripts = scripts
    }

    /// Renames an AppleScript. Trims whitespace; rejects empty or >100-char
    /// names and surfaces an inline error without mutating storage.
    func renameAppleScript(id: UUID, to newName: String) {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 100 else {
            DiagnosticsLogger.shared.log("Rejected AppleScript rename: invalid length (\(trimmed.count))")
            showError("AppleScript names must be between 1 and 100 characters.")
            return
        }

        var scripts = settings.resolvedAppleScripts
        guard let index = scripts.firstIndex(where: { $0.id == id }) else { return }
        scripts[index].name = trimmed
        scripts[index].updatedAt = Date()
        settings.appleScripts = scripts
    }

    /// Replaces source text. Rejects sources larger than 1,000,000 characters.
    /// Resets the cached compile state because the script is now dirty.
    func updateAppleScriptSource(id: UUID, source: String) {
        guard source.count <= 1_000_000 else {
            DiagnosticsLogger.shared.log("Rejected AppleScript source update: oversized (\(source.count) chars)")
            showError("AppleScript source cannot exceed 1,000,000 characters.")
            return
        }

        var scripts = settings.resolvedAppleScripts
        guard let index = scripts.firstIndex(where: { $0.id == id }) else { return }
        scripts[index].source = source
        scripts[index].compiledAt = nil
        scripts[index].compileError = nil
        scripts[index].updatedAt = Date()
        settings.appleScripts = scripts
    }

    func setAppleScriptCompileState(id: UUID, compiledAt: Date?, compileError: String?) {
        var scripts = settings.resolvedAppleScripts
        guard let index = scripts.firstIndex(where: { $0.id == id }) else { return }
        scripts[index].compiledAt = compiledAt
        scripts[index].compileError = compileError
        scripts[index].updatedAt = Date()
        settings.appleScripts = scripts
    }

    func setAppleScriptIcon(id: UUID, icon: FolderIconConfig?, colorHex: String?) {
        var scripts = settings.resolvedAppleScripts
        guard let index = scripts.firstIndex(where: { $0.id == id }) else { return }
        scripts[index].icon = icon
        scripts[index].iconColorHex = colorHex
        scripts[index].updatedAt = Date()
        settings.appleScripts = scripts
    }

    /// Sets a file reference for an AppleScript. The bookmark is created from the URL
    /// and stored in the config. Setting a file reference clears the inline source.
    func setAppleScriptFileBookmark(id: UUID, bookmark: Data?) {
        var scripts = settings.resolvedAppleScripts
        guard let index = scripts.firstIndex(where: { $0.id == id }) else { return }
        scripts[index].sourceFileBookmark = bookmark
        if bookmark != nil {
            // Clear inline source when referencing a file
            scripts[index].source = ""
        }
        scripts[index].updatedAt = Date()
        settings.appleScripts = scripts
        DiagnosticsLogger.shared.log("Set AppleScript file bookmark for \(id)")
    }

    /// Creates a bookmark for an AppleScript file URL and applies it to the script config.
    /// This is the main entry point for the file picker UI.
    func importAppleScriptFile(url: URL, for scriptID: UUID) {
        do {
            let bookmark = try FileAccessService.createAppleScriptBookmark(for: url)
            setAppleScriptFileBookmark(id: scriptID, bookmark: bookmark)

            // Update name to match file name if this is a new/empty script
            if let config = appleScript(id: scriptID), config.name == "Untitled AppleScript" {
                let fileName = url.deletingPathExtension().lastPathComponent
                renameAppleScript(id: scriptID, to: fileName)
            }
        } catch {
            showError("Could not import AppleScript file: \(error.localizedDescription)")
            DiagnosticsLogger.shared.log("Failed to create bookmark for \(url.path): \(error)")
        }
    }

    func duplicateAppleScript(id: UUID) {
        guard var copy = appleScript(id: id) else { return }
        copy.id = UUID()
        copy.name = nextCopyName(
            base: copy.name,
            existing: settings.resolvedAppleScripts.map(\.name)
        )
        copy.compiledAt = nil
        copy.compileError = nil
        copy.createdAt = Date()
        copy.updatedAt = Date()

        var scripts = settings.resolvedAppleScripts
        scripts.append(copy)
        settings.appleScripts = scripts
        selectedAppleScriptID = copy.id
    }

    func deleteAppleScript(id: UUID) {
        var scripts = settings.resolvedAppleScripts
        scripts.removeAll { $0.id == id }
        settings.appleScripts = scripts

        // Cascade: drop every menu item that referenced this script.
        var views = settings.resolvedMenuViews
        var anyChanged = false
        for vi in views.indices {
            let before = views[vi].resolvedAppleScriptItems.count
            let filtered = views[vi].resolvedAppleScriptItems.filter { $0.appleScriptID != id }
            if filtered.count != before {
                views[vi].appleScriptItems = filtered
                views[vi].updatedAt = Date()
                anyChanged = true
            }
        }
        if anyChanged {
            settings.menuViews = views
        }

        if selectedAppleScriptID == id {
            selectedAppleScriptID = scripts.first?.id
        }

        lastAppleScriptRuns.removeValue(forKey: id)
    }

    /// Append an AppleScriptMenuItemConfig to the target menu view (creating one
    /// if needed). Skips when the script is already attached.
    func attachAppleScript(_ scriptID: UUID, toMenuViewID menuViewID: UUID?) {
        var views = settings.resolvedMenuViews
        let targetID: UUID

        if let menuViewID, views.contains(where: { $0.id == menuViewID }) {
            targetID = menuViewID
        } else {
            let view = MenuViewConfig.make(title: "AppleScripts", defaults: settings.defaultMenuSettings)
            views.append(view)
            targetID = view.id
            selectedMenuViewID = targetID
        }

        guard let index = views.firstIndex(where: { $0.id == targetID }) else { return }
        var items = views[index].resolvedAppleScriptItems
        guard !items.contains(where: { $0.appleScriptID == scriptID }) else {
            settings.menuViews = views
            return
        }

        items.append(AppleScriptMenuItemConfig.make(appleScriptID: scriptID))
        views[index].appleScriptItems = items
        views[index].updatedAt = Date()
        settings.menuViews = views
        selectedMenuViewID = targetID
    }

    func recordAppleScriptRun(_ record: AppleScriptRunRecord) {
        lastAppleScriptRuns[record.scriptID] = record
    }

    // MARK: - Sources

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

    private func canLinkMenuView(_ linkedMenuViewID: UUID, toMenuViewID targetID: UUID, in views: [MenuViewConfig]) -> Bool {
        guard linkedMenuViewID != targetID else { return false }
        return !menuView(linkedMenuViewID, contains: targetID, in: views, visited: [])
    }

    private func menuView(_ currentID: UUID, contains searchID: UUID, in views: [MenuViewConfig], visited: Set<UUID>) -> Bool {
        if currentID == searchID { return true }
        guard !visited.contains(currentID),
              let view = views.first(where: { $0.id == currentID }) else {
            return false
        }

        var nextVisited = visited
        nextVisited.insert(currentID)

        for linkedView in view.resolvedLinkedMenuViews {
            if menuView(linkedView.menuViewID, contains: searchID, in: views, visited: nextVisited) {
                return true
            }
        }

        return false
    }

    func setDisplayMode(_ mode: DisplayMode) {
        settings.displayMode = mode
    }

    func updateGlobalSettings(_ update: (inout AppSettings) -> Void) {
        let before = settings.enableVerboseDiagnostics
        update(&settings)
        if settings.enableVerboseDiagnostics != before {
            DiagnosticsLogger.shared.setEnabled(settings.resolvedEnableVerboseDiagnostics)
        }
    }

    func revealInFinder(id: UUID) {
        guard let config = folder(id: id) else { return }

        do {
            let access = try fileAccessService.accessFolder(config)
            // activateFileViewerSelecting hands the URL to Finder over XPC and returns
            // immediately; keep the security scope alive long enough for Finder to read it.
            withExtendedLifetime(access) {
                NSWorkspace.shared.activateFileViewerSelecting([access.url])
            }
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

        NSApp.activate(ignoringOtherApps: true)
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
            // Drop any cached resolution that referred to the previous bookmark
            // so the next access path uses the freshly granted permission.
            fileAccessService.invalidateCache(for: id)
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

        NSApp.activate(ignoringOtherApps: true)
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

        NSApp.activate(ignoringOtherApps: true)
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
        // Eager helper kept for migration-time writes (during init when we re-encode
        // freshly migrated settings). For all post-init mutations, prefer scheduleSave().
        do {
            let data = try encoder.encode(settings)
            try data.write(to: settingsURL, options: [.atomic])
        } catch {
            lastErrorMessage = "Could not save settings: \(error.localizedDescription)"
        }
    }

    /// Coalesce rapid mutations (slider drags, TextField edits) into a single
    /// off-main write. Cancels any pending write on each call so we never queue
    /// a backlog of disk writes.
    private func scheduleSave() {
        pendingSave?.cancel()

        let snapshot = settings
        let item = DispatchWorkItem { [weak self] in
            self?.write(snapshot)
        }
        pendingSave = item
        saveQueue.asyncAfter(deadline: .now() + saveDebounce, execute: item)
    }

    /// Force any pending debounced save to run synchronously. Call this on app
    /// terminate or settings-window close so changes always land on disk.
    func flushPendingSave() {
        guard let pending = pendingSave else { return }
        pendingSave = nil
        pending.cancel()
        // Run inline on the calling thread so we know the write completed before
        // returning. We snapshot settings rather than re-reading inside the work
        // item to keep behavior consistent with scheduleSave().
        write(settings)
    }

    private func write(_ snapshot: AppSettings) {
        // JSONEncoder isn't documented as thread-safe across concurrent encode calls,
        // and our encoder is shared with the main-thread migration path. Build a
        // local encoder for the background write to keep the contract simple.
        let localEncoder = JSONEncoder()
        localEncoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        localEncoder.dateEncodingStrategy = .iso8601

        do {
            let data = try localEncoder.encode(snapshot)
            try data.write(to: settingsURL, options: [.atomic])
        } catch {
            DispatchQueue.main.async { [weak self] in
                self?.lastErrorMessage = "Could not save settings: \(error.localizedDescription)"
            }
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

        if settings.schemaVersion < 7 {
            settings.schemaVersion = 7
        }

        if settings.schemaVersion < 8 {
            settings.schemaVersion = 8
            settings.enableVerboseDiagnostics = settings.enableVerboseDiagnostics ?? false
        }

        if settings.schemaVersion < 9 {
            settings.schemaVersion = 9
            settings.appleScripts = settings.appleScripts ?? []
            if var views = settings.menuViews {
                for index in views.indices {
                    views[index].appleScriptItems = views[index].resolvedAppleScriptItems
                }
                settings.menuViews = views
            }
        }

        if settings.schemaVersion < 10 {
            settings.schemaVersion = 10
            settings.browserFlip = settings.browserFlip ?? .defaults
        }

        if settings.schemaVersion < 11 {
            settings.schemaVersion = 11
            // browserFlipItem is added per-menu-view as an optional field.
            // Default is nil for existing menu views, so no backfill is needed.
        }

        if settings.schemaVersion < 12 {
            settings.schemaVersion = 12
            settings.showRootFolderManagementItems = settings.showRootFolderManagementItems ?? true
        }

        if settings.schemaVersion < 13 {
            settings.schemaVersion = 13
            settings.clipboardShelf = settings.clipboardShelf ?? .defaults
            // clipboardShelfItem is added per-menu-view as an optional field.
            // Default is nil for existing menu views, so no per-view backfill is needed.
        }

        if settings.schemaVersion < 14 {
            settings.schemaVersion = 14
            settings.worldClock = settings.worldClock ?? .defaults
            // worldClockItem is added per-menu-view as an optional field.
            // Default is nil for existing menu views, so no per-view backfill is needed.
        }

        if settings.schemaVersion < 15 {
            settings.schemaVersion = 15
            settings.standaloneModules = settings.standaloneModules ?? []
            DiagnosticsLogger.shared.log("Applied schema-15 migration: standalone modules field defaulted to []")
        }

        if settings.schemaVersion < 16 {
            settings.schemaVersion = 16
            settings.bookmarkShelf = settings.bookmarkShelf ?? BookmarkShelfSettings.defaults
            DiagnosticsLogger.shared.log("Applied schema-16 migration: bookmarkShelf field defaulted to .defaults")
        }

        settings.showFileAndFolderIcons = settings.showFileAndFolderIcons ?? true
        settings.showFileSubmenus = settings.showFileSubmenus ?? true
        settings.showFolderSubmenus = settings.showFolderSubmenus ?? true
        settings.shortcutOpenLocation = settings.shortcutOpenLocation ?? .menuBarItem
        settings.showTopLevelFolderIcons = settings.showTopLevelFolderIcons ?? true
        settings.topLevelFolderIconSize = settings.topLevelFolderIconSize ?? .small
        settings.moreMenuBehavior = settings.moreMenuBehavior ?? .visibleAtBottom
        settings.appleScripts = settings.appleScripts ?? []
        settings.clipboardShelf = settings.clipboardShelf ?? .defaults
        settings.worldClock = settings.worldClock ?? .defaults
        settings.standaloneModules = settings.standaloneModules ?? []
        settings.bookmarkShelf = settings.bookmarkShelf ?? BookmarkShelfSettings.defaults
        // Standalone modules: decode-time title fixup (Requirement 1.4).
        // An empty / whitespace-only `title` substitutes the kind's default;
        // a `title` longer than 200 characters is clamped. Both fixups land
        // here so any decoded entry, whether from older builds (no field) or
        // hand-edited JSON, normalises before reaching the runtime.
        if var modules = settings.standaloneModules {
            for index in modules.indices {
                let trimmed = modules[index].title.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.isEmpty {
                    modules[index].title = modules[index].kind.defaultTitle
                } else if trimmed.count > 200 {
                    modules[index].title = String(trimmed.prefix(200))
                }
            }
            settings.standaloneModules = modules
        }
        settings.showRootFolderManagementItems = settings.showRootFolderManagementItems ?? true
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
            views[index].shortcutItems = views[index].shortcutItems ?? []
            views[index].linkedShortcutsFolders = views[index].linkedShortcutsFolders ?? []
            views[index].linkedMenuViews = views[index].resolvedLinkedMenuViews.filter { linkedView in
                linkedView.menuViewID != views[index].id && views.contains { $0.id == linkedView.menuViewID }
            }
            views[index].appSpecificShortcutGroups = views[index].appSpecificShortcutGroups ?? []
            views[index].appleScriptItems = views[index].resolvedAppleScriptItems
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
        menuSettings.showOpenWithForSubfolders = menuSettings.showOpenWithForSubfolders ?? true
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
