import AppKit
import Foundation
import UniformTypeIdentifiers

enum MenuActionKind {
    case addFolder
    case addApp
    case addLinkedMenuView
    case openSettings
    case quit
    case open
    case openWithApp
    case openWithOther
    case reveal
    case copyPath
    case copyFile
    case copyContents
    case copyDimensions
    case share
    case moveToTrash
    case getInfo
    case hideFolder
    case removeFolder
    case folderSettings
    case reselectFolder
    case setFolderVisibility
    case showOnlyFolder
    case showAllFolders
    case addMenuView
    case duplicateMenuView
    case removeMenuView
    case hideMenuView
    case menuViewSettings
    case setMenuViewVisibility
    case showOnlyMenuView
    case setSortKey
    case setSortDirection
    case setAllIconOnly
    case openShortcutsApp
    case runShortcut
    case openShortcutForEditing
    case refreshShortcuts
    case runScript
    case runAppleScript
}

final class MenuAction: NSObject {
    let kind: MenuActionKind
    let url: URL?
    let folderID: UUID?
    let menuViewID: UUID?
    let appURL: URL?
    let stringValue: String?
    let boolValue: Bool?
    let sortKey: SortKey?
    let sortDirection: SortDirection?
    let shortcutID: String?
    let shortcutName: String?
    let shortcutTextInput: String?
    let linkedMenuViewID: UUID?
    let appleScriptID: UUID?

    init(
        kind: MenuActionKind,
        url: URL? = nil,
        folderID: UUID? = nil,
        menuViewID: UUID? = nil,
        appURL: URL? = nil,
        stringValue: String? = nil,
        boolValue: Bool? = nil,
        sortKey: SortKey? = nil,
        sortDirection: SortDirection? = nil,
        shortcutID: String? = nil,
        shortcutName: String? = nil,
        shortcutTextInput: String? = nil,
        linkedMenuViewID: UUID? = nil,
        appleScriptID: UUID? = nil
    ) {
        self.kind = kind
        self.url = url
        self.folderID = folderID
        self.menuViewID = menuViewID
        self.appURL = appURL
        self.stringValue = stringValue
        self.boolValue = boolValue
        self.sortKey = sortKey
        self.sortDirection = sortDirection
        self.shortcutID = shortcutID
        self.shortcutName = shortcutName
        self.shortcutTextInput = shortcutTextInput
        self.linkedMenuViewID = linkedMenuViewID
        self.appleScriptID = appleScriptID
    }
}

@objcMembers final class MenuActionHandler: NSObject {
    private let store: PreferencesStore
    private let fileAccessService: FileAccessService
    private let metadataService: MetadataService
    private let shortcutsService: ShortcutsService
    let appleScriptService: AppleScriptService
    private(set) lazy var appleScriptCoordinator: AppleScriptRunCoordinator = AppleScriptRunCoordinator(
        store: store,
        service: appleScriptService,
        actionHandler: self
    )
    private var temporarySharingWindow: NSWindow?
    private let sharingPickerDelegate = SharingPickerCloseDelegate()

    init(store: PreferencesStore,
         fileAccessService: FileAccessService,
         metadataService: MetadataService,
         shortcutsService: ShortcutsService,
         appleScriptService: AppleScriptService) {
        self.store = store
        self.fileAccessService = fileAccessService
        self.metadataService = metadataService
        self.shortcutsService = shortcutsService
        self.appleScriptService = appleScriptService
    }

    dynamic func handleMenuAction(_ sender: Any?) {
        guard let sender = sender as? NSMenuItem else {
            DiagnosticsLogger.shared.log("Menu action received non-menu sender")
            return
        }

        guard let action = sender.representedObject as? MenuAction else { return }
        let modifierFlags = NSApp.currentEvent?.modifierFlags ?? NSEvent.modifierFlags
        DiagnosticsLogger.shared.log("Menu selected: \(sender.title) [\(String(describing: action.kind))]")

        // Defer real work until after AppKit finishes tracking the menu. This avoids
        // menu actions being swallowed when opening windows or handing URLs to Finder.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self, action, modifierFlags] in
            self?.execute(action, modifierFlags: modifierFlags)
        }
    }

    func openRootItem(folderID: UUID) {
        guard let config = store.folder(id: folderID) else { return }
        do {
            let access = try fileAccessService.accessItem(config)
            withExtendedLifetime(access) {
                if config.resolvedItemKind == .app {
                    openApplication(access.url)
                } else {
                    openFolderInFinder(access.url)
                }
            }
        } catch {
            DiagnosticsLogger.shared.log("openRootItem error for \(folderID): \(error.localizedDescription)")
            store.showError(error.localizedDescription)
        }
    }

    private func execute(_ action: MenuAction, modifierFlags: NSEvent.ModifierFlags = []) {
        DiagnosticsLogger.shared.log("Executing action: \(String(describing: action.kind)) url=\(action.url?.path ?? "nil") folder=\(action.folderID?.uuidString ?? "nil")")

        switch action.kind {
        case .addFolder:
            if let menuViewID = action.menuViewID {
                store.selectedMenuViewID = menuViewID
            }
            store.addFolderFromPanel()

        case .addApp:
            if let menuViewID = action.menuViewID {
                store.selectedMenuViewID = menuViewID
            }
            store.addAppFromPanel()

        case .addLinkedMenuView:
            guard let menuViewID = action.menuViewID,
                  let linkedMenuViewID = action.linkedMenuViewID else {
                return
            }
            store.addLinkedMenuView(linkedMenuViewID, toMenuViewID: menuViewID)

        case .addMenuView:
            store.addMenuView()

        case .openSettings:
            AppContainer.shared.settingsWindowController.show()
            DiagnosticsLogger.shared.log("Requested settings window")

        case .quit:
            NSApp.terminate(nil)

        case .open:
            guard let url = action.url else { return }
            withFolderAccess(action.folderID) {
                if modifierFlags.contains(.option) {
                    revealInFinder(url)
                    return
                }

                if isApplicationBundle(url) {
                    openApplication(url)
                } else if isDirectory(url) {
                    openFolderInFinder(url)
                } else if !NSWorkspace.shared.open(url) {
                    store.showError("Could not open \(url.lastPathComponent).")
                } else {
                    DiagnosticsLogger.shared.log("Opened URL: \(url.path)")
                }
            }

        case .openWithApp:
            guard let url = action.url, let appURL = action.appURL else { return }
            open(url, withApplicationAt: appURL, folderID: action.folderID)

        case .openWithOther:
            guard let url = action.url else { return }
            chooseApplicationAndOpen(url, folderID: action.folderID)

        case .reveal:
            guard let url = action.url else { return }
            withFolderAccess(action.folderID) {
                revealInFinder(url)
            }

        case .copyPath:
            guard let path = action.url?.path ?? action.stringValue else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(path, forType: .string)
            DiagnosticsLogger.shared.log("Copied path: \(path)")

        case .copyFile:
            guard let url = action.url else { return }
            withFolderAccess(action.folderID) {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.writeObjects([url as NSURL])
                DiagnosticsLogger.shared.log("Copied file: \(url.path)")
            }

        case .copyContents:
            guard let url = action.url else { return }
            withFolderAccess(action.folderID) {
                copyFileContents(at: url)
            }

        case .copyDimensions:
            guard let value = action.stringValue else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(value, forType: .string)
            DiagnosticsLogger.shared.log("Copied dimensions: \(value)")

        case .share:
            guard let url = action.url else { return }
            withFolderAccess(action.folderID) {
                showSharingPicker(for: url)
            }

        case .moveToTrash:
            guard let url = action.url else { return }
            withFolderAccess(action.folderID) {
                moveToTrash(url)
            }

        case .getInfo:
            guard let url = action.url else { return }
            withFolderAccess(action.folderID) {
                revealInFinder(url)
                DiagnosticsLogger.shared.log("Get Info fallback revealed URL: \(url.path)")
            }

        case .hideFolder:
            guard let folderID = action.folderID, var folder = store.folder(id: folderID) else { return }
            folder.isVisible = false
            store.updateFolder(folder)

        case .removeFolder:
            guard let folderID = action.folderID else { return }
            confirmRemoveFolder(folderID)

        case .folderSettings:
            guard let folderID = action.folderID else {
                AppContainer.shared.settingsWindowController.show()
                return
            }
            AppContainer.shared.settingsWindowController.show(selectedFolderID: folderID)

        case .reselectFolder:
            guard let folderID = action.folderID else { return }
            store.reselectFolder(id: folderID)

        case .setFolderVisibility:
            guard let folderID = action.folderID, let isVisible = action.boolValue else { return }
            store.setFolderVisibility(id: folderID, isVisible: isVisible)

        case .showOnlyFolder:
            guard let folderID = action.folderID else { return }
            store.showOnlyFolder(id: folderID)

        case .showAllFolders:
            store.showAllFolders()

        case .duplicateMenuView:
            guard let menuViewID = action.menuViewID else { return }
            store.duplicateMenuView(id: menuViewID)

        case .removeMenuView:
            guard let menuViewID = action.menuViewID else { return }
            confirmRemoveMenuView(menuViewID)

        case .hideMenuView:
            guard let menuViewID = action.menuViewID else { return }
            store.setMenuViewVisibility(id: menuViewID, isVisible: false)

        case .menuViewSettings:
            guard let menuViewID = action.menuViewID else {
                AppContainer.shared.settingsWindowController.show()
                return
            }
            AppContainer.shared.settingsWindowController.show(selectedMenuViewID: menuViewID)

        case .setMenuViewVisibility:
            guard let menuViewID = action.menuViewID, let isVisible = action.boolValue else { return }
            store.setMenuViewVisibility(id: menuViewID, isVisible: isVisible)

        case .showOnlyMenuView:
            guard let menuViewID = action.menuViewID else { return }
            store.showOnlyMenuView(id: menuViewID)

        case .setSortKey:
            guard let folderID = action.folderID, let sortKey = action.sortKey, var folder = store.folder(id: folderID) else { return }
            folder.menuSettings.sortKey = sortKey
            store.updateFolder(folder)

        case .setSortDirection:
            guard let folderID = action.folderID, let sortDirection = action.sortDirection, var folder = store.folder(id: folderID) else { return }
            folder.menuSettings.sortDirection = sortDirection
            store.updateFolder(folder)

        case .setAllIconOnly:
            store.setAllMenuBarStyles(.iconOnly)

        case .openShortcutsApp:
            NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Shortcuts.app"))

        case .refreshShortcuts:
            store.refreshShortcutsCatalog()

        case .runScript:
            guard let url = action.url else { return }
            withFolderAccess(action.folderID) {
                runScriptInTerminal(url)
            }

        case .runShortcut:
            guard let shortcutName = action.shortcutName else { return }
            let identifierOrName = action.shortcutID ?? shortcutName
            let openForEditing = modifierFlags.contains(.option)
            // MenuActionHandler is owned by AppContainer.shared for the app's
            // lifetime, so a strong self capture in the Task isn't a leak. We
            // avoid [weak self] which triggers Swift 6's mutable-capture warning
            // in concurrent closures.
            Task { [shortcutsService] in
                do {
                    if openForEditing {
                        try await shortcutsService.openShortcutForEditing(identifierOrName: identifierOrName)
                    } else {
                        try await shortcutsService.runShortcut(identifierOrName: identifierOrName, textInput: action.shortcutTextInput)
                    }
                } catch {
                    await MainActor.run {
                        DiagnosticsLogger.shared.log("Run shortcut failed \(shortcutName): \(error.localizedDescription)")
                        self.store.showError("Could not run \(shortcutName): \(error.localizedDescription)")
                    }
                }
            }

        case .openShortcutForEditing:
            guard let shortcutName = action.shortcutName else { return }
            let identifierOrName = action.shortcutID ?? shortcutName
            // See .runShortcut above for the strong-capture rationale.
            Task { [shortcutsService] in
                do {
                    try await shortcutsService.openShortcutForEditing(identifierOrName: identifierOrName)
                } catch {
                    await MainActor.run {
                        DiagnosticsLogger.shared.log("Open shortcut failed \(shortcutName): \(error.localizedDescription)")
                        self.store.showError("Could not open \(shortcutName): \(error.localizedDescription)")
                    }
                }
            }

        case .runAppleScript:
            guard let scriptID = action.appleScriptID else { return }
            appleScriptCoordinator.run(scriptID: scriptID, fromMenuViewID: action.menuViewID)
        }
    }

    private func withFolderAccess(_ folderID: UUID?, perform action: () -> Void) {
        do {
            let access = try startFolderAccess(folderID)
            withExtendedLifetime(access) {
                action()
            }
        } catch {
            DiagnosticsLogger.shared.log("Failed security scope: \(error.localizedDescription)")
            store.showError(error.localizedDescription)
        }
    }

    private func startFolderAccess(_ folderID: UUID?) throws -> SecurityScopedURL? {
        guard let folderID, let config = store.folder(id: folderID) else {
            return nil
        }

        let access = try fileAccessService.accessItem(config)
        DiagnosticsLogger.shared.log("Started security scope for \(config.resolvedItemKind.rawValue): \(config.displayName)")
        return access
    }

    private func open(_ url: URL, withApplicationAt appURL: URL, folderID: UUID?) {
        let access: SecurityScopedURL?

        do {
            access = try startFolderAccess(folderID)
        } catch {
            DiagnosticsLogger.shared.log("Failed security scope: \(error.localizedDescription)")
            store.showError(error.localizedDescription)
            return
        }

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        configuration.promptsUserIfNeeded = true

        // MenuActionHandler is owned by AppContainer.shared; capturing self strongly
        // here isn't a leak. The closure also keeps the SecurityScopedURL alive for
        // the full XPC handoff so the destination app can read the file.
        NSWorkspace.shared.open([url], withApplicationAt: appURL, configuration: configuration) { [access] _, error in
            withExtendedLifetime(access) {
                if let error {
                    DiagnosticsLogger.shared.log("Open With failed for \(url.path) using \(appURL.path): \(error.localizedDescription)")
                    DispatchQueue.main.async {
                        self.store.showError(error.localizedDescription)
                    }
                    return
                }

                DiagnosticsLogger.shared.log("Opened \(url.path) with \(appURL.path)")
            }
        }
    }

    private func chooseApplicationAndOpen(_ url: URL, folderID: UUID?) {
        let panel = NSOpenPanel()
        panel.title = "Open With"
        panel.message = "Choose an app to open \(url.lastPathComponent)."
        panel.prompt = "Open"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.directoryURL = URL(fileURLWithPath: "/Applications", isDirectory: true)
        panel.treatsFilePackagesAsDirectories = false
        panel.allowedContentTypes = [.applicationBundle]
        panel.allowsOtherFileTypes = false

        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let appURL = panel.url else { return }
        open(url, withApplicationAt: appURL, folderID: folderID)
    }

    private func openFolderInFinder(_ url: URL) {
        let didSelect = NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: url.path)
        if !didSelect, !NSWorkspace.shared.open(url) {
            store.showError("Could not open \(url.lastPathComponent) in Finder.")
            return
        }

        activateFinder()
        DiagnosticsLogger.shared.log("Opened folder in Finder: \(url.path)")
    }

    private func openApplication(_ url: URL) {
        if !NSWorkspace.shared.open(url) {
            store.showError("Could not open \(url.lastPathComponent).")
            return
        }

        DiagnosticsLogger.shared.log("Opened app: \(url.path)")
    }

    private func revealInFinder(_ url: URL) {
        let parentPath = url.deletingLastPathComponent().path
        let didSelect = NSWorkspace.shared.selectFile(url.path, inFileViewerRootedAtPath: parentPath)
        if !didSelect {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }

        activateFinder()
        DiagnosticsLogger.shared.log("Revealed URL in Finder: \(url.path)")
    }

    private func activateFinder() {
        let finderBundleID = "com.apple.finder"
        if let finder = NSRunningApplication.runningApplications(withBundleIdentifier: finderBundleID).first {
            finder.activate(options: [.activateAllWindows])
        }
    }

    private func isDirectory(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    private func isApplicationBundle(_ url: URL) -> Bool {
        url.pathExtension.lowercased() == "app"
    }

    /// Cap copy-to-clipboard at a reasonable file size so we don't block the
    /// main thread reading a multi-gigabyte log into memory.
    private static let maxCopyContentsBytes: Int = 8 * 1024 * 1024 // 8 MB

    private func copyFileContents(at url: URL) {
        do {
            let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
            if let size = attrs[.size] as? NSNumber, size.intValue > Self.maxCopyContentsBytes {
                let alert = NSAlert()
                alert.messageText = "File is too large to copy"
                alert.informativeText = "\(url.lastPathComponent) is \(ByteCountFormatter.string(fromByteCount: size.int64Value, countStyle: .file)). Copy is limited to 8 MB to keep the menu responsive."
                alert.alertStyle = .warning
                alert.addButton(withTitle: "OK")
                alert.runModal()
                return
            }
        } catch {
            // If attributes fail we still try to read; String(contentsOf:) will surface the real error.
        }

        do {
            let content = try String(contentsOf: url, encoding: .utf8)
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(content, forType: .string)
            DiagnosticsLogger.shared.log("Copied contents of: \(url.path)")
        } catch {
            DiagnosticsLogger.shared.log("Copy contents failed: \(error.localizedDescription)")
            store.showError("Could not read file contents: \(error.localizedDescription)")
        }
    }

    private func runScriptInTerminal(_ url: URL) {
        let ext = url.pathExtension.lowercased()
        let scriptPath = url.path
        let dir = url.deletingLastPathComponent().path

        // Build a single shell command. Use POSIX-shell single-quote escaping —
        // wrap each path in '...' and replace any embedded ' with '\'' .
        let runner = (ext == "ps1") ? "pwsh" : "bash"
        let shellCommand = "cd \(shellQuote(dir)) && \(runner) \(shellQuote(scriptPath))"

        // Pass the shell command into AppleScript via an environment variable so
        // the path/contents never have to be escaped through both AppleScript and
        // shell quoting layers.
        let appleScript = """
        tell application "Terminal"
            activate
            do script (system attribute "MENUSHELF_CMD")
        end tell
        """

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", appleScript]
        var environment = ProcessInfo.processInfo.environment
        environment["MENUSHELF_CMD"] = shellCommand
        process.environment = environment

        do {
            try process.run()
        } catch {
            DiagnosticsLogger.shared.log("Launch Terminal failed: \(error.localizedDescription)")
            store.showError("Could not launch Terminal: \(error.localizedDescription)")
        }
    }

    /// POSIX-shell single-quote escape: every ' becomes '\'' and the whole
    /// thing is wrapped in single quotes. Works for any byte sequence except NUL.
    private func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private func showSharingPicker(for url: URL) {
        let view = NSApp.keyWindow?.contentView ?? temporaryAnchorView()
        let picker = NSSharingServicePicker(items: [url])
        picker.delegate = sharingPickerDelegate
        sharingPickerDelegate.onClose = { [weak self] in
            // Tear down the temporary anchor window once the picker is gone,
            // not on a fixed timer that could expire mid-interaction.
            self?.tearDownTemporaryAnchor()
        }
        picker.show(relativeTo: NSRect(x: view.bounds.midX, y: view.bounds.midY, width: 1, height: 1), of: view, preferredEdge: .minY)
    }

    private func temporaryAnchorView() -> NSView {
        if let view = temporarySharingWindow?.contentView {
            return view
        }

        let mouseLocation = NSEvent.mouseLocation
        let window = NSWindow(
            contentRect: NSRect(x: mouseLocation.x, y: mouseLocation.y, width: 1, height: 1),
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        window.level = .statusBar
        window.isOpaque = false
        window.backgroundColor = .clear
        window.ignoresMouseEvents = true
        window.orderFrontRegardless()
        temporarySharingWindow = window
        return window.contentView ?? NSView(frame: .zero)
    }

    private func tearDownTemporaryAnchor() {
        temporarySharingWindow?.close()
        temporarySharingWindow = nil
    }

    private func moveToTrash(_ url: URL) {
        let alert = NSAlert()
        alert.messageText = "Move to Trash?"
        alert.informativeText = url.lastPathComponent
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Move to Trash")
        alert.addButton(withTitle: "Cancel")

        guard alert.runModal() == .alertFirstButtonReturn else { return }

        do {
            var resultingURL: NSURL?
            try FileManager.default.trashItem(at: url, resultingItemURL: &resultingURL)
        } catch {
            DiagnosticsLogger.shared.log("Move to trash failed for \(url.path): \(error.localizedDescription)")
            store.showError(error.localizedDescription)
        }
    }

    private func confirmRemoveFolder(_ id: UUID) {
        let name = store.folder(id: id)?.displayName ?? "Folder"
        let alert = NSAlert()
        alert.messageText = "Remove \(name)?"
        alert.informativeText = "This removes the folder from MenuShelf. Files on disk are not deleted."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Remove")
        alert.addButton(withTitle: "Cancel")

        guard alert.runModal() == .alertFirstButtonReturn else { return }
        store.removeFolder(id: id)
    }

    private func confirmRemoveMenuView(_ id: UUID) {
        let name = store.menuView(id: id)?.title ?? "Menu View"
        let alert = NSAlert()
        alert.messageText = "Remove \(name)?"
        alert.informativeText = "This removes the menu bar icon/view. Sources inside it remain in MenuShelf and can be used in other views."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Remove")
        alert.addButton(withTitle: "Cancel")

        guard alert.runModal() == .alertFirstButtonReturn else { return }
        store.removeMenuView(id: id)
    }

    // MARK: - AppleScript alerts

    func showAppleScriptCompileAlert(scriptID: UUID, error: AppleScriptCompileError, scriptName: String) {
        let truncatedName = String(scriptName.prefix(256))
        let alert = NSAlert()
        alert.messageText = "Compile error in \(truncatedName)"
        alert.informativeText = composeCompileMessage(error: error)
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Edit Script")
        alert.addButton(withTitle: "Cancel")

        let response = alert.runModal()
        guard response == .alertFirstButtonReturn else { return }
        AppContainer.shared.settingsWindowController.show(selectedAppleScriptID: scriptID)
    }

    func showAppleScriptExecutionAlert(error: AppleScriptExecutionError, scriptName: String) {
        let truncatedName = String(scriptName.prefix(256))
        let alert = NSAlert()
        alert.messageText = "AppleScript failed: \(truncatedName)"
        alert.informativeText = error.message
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Copy Details")
        alert.addButton(withTitle: "OK")

        let response = alert.runModal()
        guard response == .alertFirstButtonReturn else { return }
        copyExecutionErrorDictionary(error)
    }

    func showAppleScriptPermissionAlert(error: AppleScriptExecutionError, scriptName: String) {
        let truncatedName = String(scriptName.prefix(256))
        let target = error.appName ?? "another application"
        let alert = NSAlert()
        alert.messageText = "Automation permission required"
        alert.informativeText = "MenuShelf needs permission to control \(target) to run \(truncatedName). Open System Settings → Privacy & Security → Automation to grant access. \(error.message)"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Cancel")

        let response = alert.runModal()
        guard response == .alertFirstButtonReturn else { return }
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation") {
            NSWorkspace.shared.open(url)
        }
    }

    func showAppleScriptMissingAlert(scriptID: UUID) {
        let alert = NSAlert()
        alert.messageText = "AppleScript no longer exists"
        alert.informativeText = "The AppleScript with id \(scriptID.uuidString) was removed before it could run."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        _ = alert.runModal()
    }

    func showAppleScriptTimeoutAlert(scriptName: String, elapsedMs: Int) {
        let truncatedName = String(scriptName.prefix(256))
        let alert = NSAlert()
        alert.messageText = "AppleScript timed out: \(truncatedName)"
        alert.informativeText = "Script did not return within the timeout window (\(elapsedMs) ms)."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        _ = alert.runModal()
    }

    private func composeCompileMessage(error: AppleScriptCompileError) -> String {
        if error.isTimeout {
            return "Compilation timed out after 5 seconds."
        }
        if error.isOversized {
            return "Source is too large to compile (max 100,000 characters)."
        }
        if error.isEmpty {
            return "Source is empty."
        }
        if let line = error.line {
            return "Line \(line): \(error.message)"
        }
        return error.message
    }

    private func copyExecutionErrorDictionary(_ error: AppleScriptExecutionError) {
        let lines = error.rawDictionary
            .sorted(by: { $0.key < $1.key })
            .map { "\($0.key): \($0.value)" }
        let body = lines.joined(separator: "\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(body, forType: .string)
        DiagnosticsLogger.shared.log("Copied AppleScript error details (\(body.count) chars)")
    }
}


/// Calls a closure once the sharing picker is dismissed, so callers can
/// tear down a transient anchor window precisely when it is no longer needed.
private final class SharingPickerCloseDelegate: NSObject, NSSharingServicePickerDelegate {
    var onClose: (() -> Void)?

    func sharingServicePicker(_ sharingServicePicker: NSSharingServicePicker, didChoose service: NSSharingService?) {
        // `didChoose` fires whether or not the user picked a service.
        // Defer slightly so the system can fully dismiss the picker first.
        DispatchQueue.main.async { [weak self] in
            self?.onClose?()
        }
    }
}
