//
//  BookmarkShelfSettingsView.swift
//  MenuShelf
//
//  Settings pane for the Bookmark Shelf feature. Mirrors the structure of
//  `ClockShelfSettingsView` and `ClipboardShelfSettingsView`: a single
//  scrolling pane built from `SettingsCard`/`SettingsToggle`/`SettingsRow`.
//  All bindings flow through `store.updateBookmarkShelfSettings { ... }`
//  except the popup hotkey, which is owned by the vendored
//  `KeyboardShortcuts` package and bound via `KeyboardShortcuts.Recorder`.
//
//  The bookmark tree itself lives in `BookmarkShelfStorage` and persists
//  to `bookmarks.json`; settings persistence touches `settings.json` only
//  (Requirement 4.10 / 20.4).
//

import AppKit
import KeyboardShortcuts
import SwiftUI
import UniformTypeIdentifiers

/// An informational hotkey conflict surfaced under the popup recorder.
/// Conflicts are advisory only — they do NOT block save (Requirement
/// 16.5).
struct BookmarkShelfHotkeyConflict: Equatable {
    let ownerName: String
}

struct BookmarkShelfSettingsView: View {
    @EnvironmentObject private var store: PreferencesStore

    /// The pane reuses the controller's live storage handle when running.
    /// When the controller is stopped (e.g. previewing or with the
    /// feature disabled at launch), we fall back to a detached instance
    /// so the manager card still renders without crashing.
    @ObservedObject private var storage: BookmarkShelfStorage

    /// Selection inside the manager outline. `nil` means "the root".
    @State private var managerSelectedNodeID: UUID?

    /// Pending delete confirmation. When non-nil the alert is presented.
    @State private var pendingDeleteNodeID: UUID?

    @MainActor
    init() {
        self.storage = BookmarkShelfController.shared.storageHandle
            ?? BookmarkShelfStorage()
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                enableCard

                if store.settings.resolvedBookmarkShelf.enableBookmarkShelf {
                    popupCard
                    browserRoutingCard
                    importCard
                    managerCard
                }
            }
            .padding(16)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    // MARK: - Enable card (Task 15.2)

    @ViewBuilder
    private var enableCard: some View {
        SettingsCard("Enable") {
            SettingsRow("Enable Bookmark Shelf") {
                Toggle("", isOn: Binding(
                    get: { store.settings.resolvedBookmarkShelf.enableBookmarkShelf },
                    set: { store.setEnableBookmarkShelf($0) }
                ))
                .labelsHidden()
                .toggleStyle(.switch)
            }
        }
    }

    // MARK: - Popup card (Task 15.3)

    @ViewBuilder
    private var popupCard: some View {
        SettingsCard("Popup") {
            SettingsRow("Hotkey") {
                KeyboardShortcuts.Recorder(for: .bookmarkShelfPopup)
            }

            if let conflict = currentHotkeyConflict {
                SettingsBlockRow {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        Text("Conflicts with \(conflict.ownerName).")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer()
                    }
                }
            }

            SettingsRow("Width") {
                TextField("", value: popupWidthBinding, format: .number)
                    .frame(width: 80)
            }

            SettingsRow("Height") {
                TextField("", value: popupHeightBinding, format: .number)
                    .frame(width: 80)
            }

            SettingsRow("Show Favorites section") {
                Toggle("", isOn: Binding(
                    get: { store.settings.resolvedBookmarkShelf.showFavoritesSection },
                    set: { value in
                        store.updateBookmarkShelfSettings { $0.showFavoritesSection = value }
                    }
                ))
                .labelsHidden()
                .toggleStyle(.switch)
            }
        }
    }

    private var popupWidthBinding: Binding<Double> {
        Binding(
            get: { Double(store.settings.resolvedBookmarkShelf.popupSize.width) },
            set: { value in
                let clamped = min(max(value, 240), 640)
                store.updateBookmarkShelfSettings {
                    $0.popupSize = CGSize(
                        width: clamped,
                        height: $0.popupSize.height
                    )
                }
            }
        )
    }

    private var popupHeightBinding: Binding<Double> {
        Binding(
            get: { Double(store.settings.resolvedBookmarkShelf.popupSize.height) },
            set: { value in
                let clamped = min(max(value, 320), 800)
                store.updateBookmarkShelfSettings {
                    $0.popupSize = CGSize(
                        width: $0.popupSize.width,
                        height: clamped
                    )
                }
            }
        )
    }

    // MARK: - Browser routing card (Task 15.4)

    @ViewBuilder
    private var browserRoutingCard: some View {
        SettingsCard("Browser routing") {
            SettingsRow("Default browser") {
                Picker("", selection: defaultBrowserBinding) {
                    Text("System Default").tag(String?.none)
                    ForEach(DefaultBrowserService.shared.discoverBrowsers()) { browser in
                        Text(browser.name).tag(Optional(browser.id))
                    }
                }
                .labelsHidden()
            }
        }
    }

    private var defaultBrowserBinding: Binding<String?> {
        Binding(
            get: { store.settings.resolvedBookmarkShelf.defaultBrowserBundleID },
            set: { value in
                store.updateBookmarkShelfSettings { $0.defaultBrowserBundleID = value }
            }
        )
    }

    // MARK: - Import card (Task 15.5)

    @ViewBuilder
    private var importCard: some View {
        SettingsCard("Import") {
            SettingsBlockRow {
                HStack {
                    Button("Import HTML…") { runImportHTML() }
                    Button("Import from browser file…") { runImportBrowserFile() }
                    Spacer()
                }
            }
        }
    }

    private func runImportHTML() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.html]
        panel.message = "Choose an exported bookmarks HTML file."

        guard panel.runModal() == .OK, let url = panel.url else { return }
        let folderID = managerSelectedFolderID
        Task { @MainActor in
            let summary = await BookmarkShelfImportService.shared.importHTML(
                from: url,
                intoFolderID: folderID
            )
            presentImportSummary(summary)
        }
    }

    private func runImportBrowserFile() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.message = "Choose a Safari Bookmarks.plist or Chromium Bookmarks JSON file."

        guard panel.runModal() == .OK, let url = panel.url else { return }
        let folderID = managerSelectedFolderID
        Task { @MainActor in
            let summary = await BookmarkShelfImportService.shared
                .importBrowserBookmarkFile(from: url, intoFolderID: folderID)
            presentImportSummary(summary)
        }
    }

    /// Surface a counts-only toast formatted per Requirement 12.11.
    /// Bookmark and folder titles never appear here (Requirement 19.4).
    private func presentImportSummary(_ summary: BookmarkShelfImportService.ImportSummary) {
        // Suppress the no-op summary surfaced when the import service
        // returns early (e.g. the storage handle is nil because the
        // controller is stopped).
        if summary == BookmarkShelfImportService.ImportSummary() { return }

        let bookmarkLabel = "\(summary.addedBookmarks) bookmark\(summary.addedBookmarks == 1 ? "" : "s")"
        let folderLabel = "\(summary.addedFolders) folder\(summary.addedFolders == 1 ? "" : "s")"
        let duplicateLabel = "\(summary.skippedDuplicates) duplicate\(summary.skippedDuplicates == 1 ? "" : "s")"
        let flattenedLabel = "\(summary.flattenedFolders) folder\(summary.flattenedFolders == 1 ? "" : "s")"

        let message = "Imported \(bookmarkLabel), \(folderLabel). "
            + "Skipped \(duplicateLabel). Flattened \(flattenedLabel)."
        store.showError(message)
    }

    // MARK: - Manager card (Task 15.6)

    @ViewBuilder
    private var managerCard: some View {
        SettingsCard("Manager") {
            SettingsBlockRow {
                BookmarkManagerOutline(
                    storage: storage,
                    selectedNodeID: $managerSelectedNodeID,
                    confirmBeforeDelete: store.settings.resolvedBookmarkShelf.confirmBeforeDelete,
                    pendingDeleteNodeID: $pendingDeleteNodeID
                )
            }
        }
        .alert(
            deleteAlertTitle,
            isPresented: Binding(
                get: { pendingDeleteNodeID != nil },
                set: { value in if !value { pendingDeleteNodeID = nil } }
            )
        ) {
            Button("Delete", role: .destructive) {
                if let id = pendingDeleteNodeID {
                    storage.removeNode(id: id)
                    if managerSelectedNodeID == id {
                        managerSelectedNodeID = nil
                    }
                }
                pendingDeleteNodeID = nil
            }
            Button("Cancel", role: .cancel) {
                pendingDeleteNodeID = nil
            }
        }
    }

    /// Compose the delete-alert title from counts only — node titles
    /// must NOT appear here (Requirement 19.4 / 13.9).
    private var deleteAlertTitle: String {
        guard let id = pendingDeleteNodeID,
              let node = storage.nodes.first(where: { $0.id == id }) else {
            return "Delete?"
        }
        let descendants = storage.descendantIDs(of: id)
        let total = descendants.count + 1
        switch node.kind {
        case .bookmark:
            return total == 1
                ? "Delete 1 bookmark?"
                : "Delete \(total) bookmarks?"
        case .folder:
            return total == 1
                ? "Delete 1 folder?"
                : "Delete folder and \(total - 1) item\(total - 1 == 1 ? "" : "s")?"
        }
    }

    /// Resolve the folder containing the manager's selection. Used as
    /// the import target so imports land where the user is looking.
    private var managerSelectedFolderID: UUID? {
        guard let id = managerSelectedNodeID,
              let node = storage.nodes.first(where: { $0.id == id }) else {
            return nil
        }
        switch node.kind {
        case .folder: return node.id
        case .bookmark: return node.parentID
        }
    }

    // MARK: - Hotkey conflict scan (Task 16.1)

    /// Walk every other registered shortcut owner in priority order and
    /// return the first match. Conflicts are informational only and do
    /// NOT block save (Requirement 16.5).
    private var currentHotkeyConflict: BookmarkShelfHotkeyConflict? {
        guard let recorded = KeyboardShortcuts.getShortcut(for: .bookmarkShelfPopup),
              let recordedKey = recorded.key?.rawValue else {
            return nil
        }
        let recordedKeyCode = UInt16(recordedKey)
        let recordedFlags = recorded.modifiers
            .intersection(.deviceIndependentFlagsMask).rawValue

        // Priority 1: menu views.
        for view in store.settings.resolvedMenuViews {
            guard let shortcut = view.shortcut,
                  shortcut.isEnabled,
                  let keyCode = shortcut.keyCode,
                  keyCode == recordedKeyCode else { continue }
            let flags = NSEvent.ModifierFlags(rawValue: shortcut.modifierFlags)
                .intersection(.deviceIndependentFlagsMask).rawValue
            if flags == recordedFlags {
                return BookmarkShelfHotkeyConflict(
                    ownerName: "menu view '\(view.title)'"
                )
            }
        }

        // Priority 2: standalone modules.
        for module in store.settings.resolvedStandaloneModules {
            guard let shortcut = module.shortcut,
                  shortcut.isEnabled,
                  let keyCode = shortcut.keyCode,
                  keyCode == recordedKeyCode else { continue }
            let flags = NSEvent.ModifierFlags(rawValue: shortcut.modifierFlags)
                .intersection(.deviceIndependentFlagsMask).rawValue
            if flags == recordedFlags {
                return BookmarkShelfHotkeyConflict(
                    ownerName: "standalone module '\(module.title)'"
                )
            }
        }

        // Priority 3: Clipboard Shelf popup.
        if let popup = KeyboardShortcuts.getShortcut(for: .popup),
           let popupKey = popup.key?.rawValue {
            let popupFlags = popup.modifiers
                .intersection(.deviceIndependentFlagsMask).rawValue
            if UInt16(popupKey) == recordedKeyCode && popupFlags == recordedFlags {
                return BookmarkShelfHotkeyConflict(ownerName: "Clipboard Shelf popup")
            }
        }

        // Priority 4: Clock Shelf popup.
        if let world = KeyboardShortcuts.getShortcut(for: .clockShelfPopup),
           let worldKey = world.key?.rawValue {
            let worldFlags = world.modifiers
                .intersection(.deviceIndependentFlagsMask).rawValue
            if UInt16(worldKey) == recordedKeyCode && worldFlags == recordedFlags {
                return BookmarkShelfHotkeyConflict(ownerName: "Clock Shelf popup")
            }
        }

        // Priority 5: per-folder shortcuts.
        for folder in store.settings.folders {
            guard let shortcut = folder.shortcut,
                  shortcut.isEnabled,
                  let keyCode = shortcut.keyCode,
                  keyCode == recordedKeyCode else { continue }
            let flags = NSEvent.ModifierFlags(rawValue: shortcut.modifierFlags)
                .intersection(.deviceIndependentFlagsMask).rawValue
            if flags == recordedFlags {
                return BookmarkShelfHotkeyConflict(
                    ownerName: "folder '\(folder.displayName)'"
                )
            }
        }

        return nil
    }
}

// MARK: - Manager outline view

/// Hierarchical outline used inside the Manager card. Renders the bookmark
/// tree as nested rows with a flat selection model and a row of bottom
/// action buttons (Add bookmark / Add folder / Star / Move / Rename /
/// Delete).
private struct BookmarkManagerOutline: View {
    @ObservedObject var storage: BookmarkShelfStorage
    @Binding var selectedNodeID: UUID?
    let confirmBeforeDelete: Bool
    @Binding var pendingDeleteNodeID: UUID?

    @State private var renamingNodeID: UUID?
    @State private var renamingDraft: String = ""
    @State private var newBookmarkSheet: Bool = false
    @State private var newBookmarkTitle: String = ""
    @State private var newBookmarkURL: String = ""
    @State private var newFolderSheet: Bool = false
    @State private var newFolderTitle: String = ""

    /// The manager renders a single hierarchical list using SwiftUI's
    /// `List` + `OutlineGroup` with our own `BookmarkOutlineNode`
    /// adapter that walks the flat-array tree by `parentID`.
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            outlineList
                .frame(minHeight: 220, maxHeight: 380)

            actionsRow
        }
        .sheet(isPresented: $newBookmarkSheet) {
            newBookmarkSheetView
        }
        .sheet(isPresented: $newFolderSheet) {
            newFolderSheetView
        }
    }

    private var outlineList: some View {
        List(selection: $selectedNodeID) {
            ForEach(rootOutlineNodes, id: \.node.id) { entry in
                OutlineGroup(entry, children: \.children) { item in
                    row(for: item.node)
                        .tag(Optional(item.node.id))
                }
            }
        }
        .listStyle(.inset)
    }

    private var rootOutlineNodes: [BookmarkOutlineNode] {
        storage.nodes
            .filter { $0.parentID == nil }
            .sorted { lhs, rhs in
                if lhs.kind != rhs.kind {
                    // Folders before bookmarks within the same band.
                    return lhs.kind == .folder && rhs.kind == .bookmark
                }
                return lhs.sortOrder < rhs.sortOrder
            }
            .map { BookmarkOutlineNode(node: $0, allNodes: storage.nodes) }
    }

    @ViewBuilder
    private func row(for node: BookmarkNode) -> some View {
        HStack(spacing: 8) {
            Image(systemName: node.kind == .folder ? "folder" : "globe")
                .foregroundStyle(.secondary)
                .frame(width: 16)

            if renamingNodeID == node.id {
                TextField("", text: $renamingDraft, onCommit: {
                    commitRename(for: node)
                })
                .textFieldStyle(.roundedBorder)
                .onAppear { renamingDraft = node.title }
            } else {
                Text(node.title)
                    .lineLimit(1)
                if node.isFavorite {
                    Image(systemName: "star.fill")
                        .foregroundStyle(.yellow)
                        .font(.caption)
                }
            }

            Spacer()
        }
        .contextMenu { contextMenu(for: node) }
    }

    @ViewBuilder
    private func contextMenu(for node: BookmarkNode) -> some View {
        Button("Rename…") {
            renamingNodeID = node.id
            renamingDraft = node.title
        }

        Button(node.isFavorite ? "Unstar" : "Star") {
            storage.setFavorite(id: node.id, isFavorite: !node.isFavorite)
        }

        Button("Move Up") {
            moveSibling(node, by: -1)
        }
        .disabled(!canMove(node, by: -1))

        Button("Move Down") {
            moveSibling(node, by: +1)
        }
        .disabled(!canMove(node, by: +1))

        Divider()

        Button("Delete", role: .destructive) {
            requestDelete(node.id)
        }
    }

    private var actionsRow: some View {
        HStack(spacing: 8) {
            Button {
                newBookmarkTitle = ""
                newBookmarkURL = ""
                newBookmarkSheet = true
            } label: {
                Label("Add Bookmark", systemImage: "plus")
            }
            .controlSize(.small)

            Button {
                newFolderTitle = ""
                newFolderSheet = true
            } label: {
                Label("Add Folder", systemImage: "folder.badge.plus")
            }
            .controlSize(.small)

            Button {
                if let id = selectedNodeID,
                   let node = storage.nodes.first(where: { $0.id == id }) {
                    storage.setFavorite(id: id, isFavorite: !node.isFavorite)
                }
            } label: {
                Label("Star", systemImage: "star")
            }
            .controlSize(.small)
            .disabled(selectedNodeID == nil)

            Button {
                if let id = selectedNodeID { requestDelete(id) }
            } label: {
                Label("Delete", systemImage: "minus")
            }
            .controlSize(.small)
            .disabled(selectedNodeID == nil)

            Spacer()
        }
    }

    // MARK: - Sheet views

    @ViewBuilder
    private var newBookmarkSheetView: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Add Bookmark")
                .font(.headline)
            TextField("Title", text: $newBookmarkTitle)
                .textFieldStyle(.roundedBorder)
            TextField("https://example.com", text: $newBookmarkURL)
                .textFieldStyle(.roundedBorder)
            HStack {
                Button("Cancel", role: .cancel) {
                    newBookmarkSheet = false
                }
                .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Add") {
                    let parent = parentForNewNode()
                    _ = storage.addBookmark(
                        parentID: parent,
                        title: newBookmarkTitle,
                        url: newBookmarkURL,
                        isFavorite: false
                    )
                    newBookmarkSheet = false
                }
                .keyboardShortcut(.defaultAction)
                .disabled(
                    newBookmarkTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    || newBookmarkURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                )
            }
        }
        .padding(20)
        .frame(width: 360)
    }

    @ViewBuilder
    private var newFolderSheetView: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Add Folder")
                .font(.headline)
            TextField("Folder name", text: $newFolderTitle)
                .textFieldStyle(.roundedBorder)
            HStack {
                Button("Cancel", role: .cancel) {
                    newFolderSheet = false
                }
                .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Add") {
                    let parent = parentForNewNode()
                    _ = storage.addFolder(
                        parentID: parent,
                        title: newFolderTitle
                    )
                    newFolderSheet = false
                }
                .keyboardShortcut(.defaultAction)
                .disabled(newFolderTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 360)
    }

    // MARK: - Helpers

    /// The parent for a freshly added node: the selected folder, or the
    /// selected bookmark's parent, or `nil` (root) when nothing is
    /// selected.
    private func parentForNewNode() -> UUID? {
        guard let id = selectedNodeID,
              let node = storage.nodes.first(where: { $0.id == id }) else {
            return nil
        }
        switch node.kind {
        case .folder: return node.id
        case .bookmark: return node.parentID
        }
    }

    private func commitRename(for node: BookmarkNode) {
        let trimmed = renamingDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        renamingNodeID = nil
        guard !trimmed.isEmpty else { return }
        var copy = node
        copy.title = trimmed
        storage.updateNode(copy)
    }

    private func canMove(_ node: BookmarkNode, by delta: Int) -> Bool {
        let siblings = storage.nodes
            .filter { $0.parentID == node.parentID }
            .sorted { $0.sortOrder < $1.sortOrder }
        guard let idx = siblings.firstIndex(where: { $0.id == node.id }) else {
            return false
        }
        let target = idx + delta
        return target >= 0 && target < siblings.count
    }

    private func moveSibling(_ node: BookmarkNode, by delta: Int) {
        let siblings = storage.nodes
            .filter { $0.parentID == node.parentID }
            .sorted { $0.sortOrder < $1.sortOrder }
        guard let idx = siblings.firstIndex(where: { $0.id == node.id }) else {
            return
        }
        let target = idx + delta
        guard target >= 0, target < siblings.count else { return }

        // moveNode places the node before `beforeSiblingID`. To move
        // down we need the sibling at index target+1 (which becomes the
        // node we land before); to move up we need the sibling at
        // target.
        let beforeID: UUID?
        if delta < 0 {
            // Moving up: insert before the current sibling at target.
            beforeID = siblings[target].id
        } else {
            // Moving down: insert before the sibling at target+1, or
            // append when target was the last position.
            if target + 1 < siblings.count {
                beforeID = siblings[target + 1].id
            } else {
                beforeID = nil
            }
        }
        storage.moveNode(
            id: node.id,
            toParentID: node.parentID,
            beforeSiblingID: beforeID
        )
    }

    private func requestDelete(_ id: UUID) {
        if confirmBeforeDelete {
            pendingDeleteNodeID = id
        } else {
            storage.removeNode(id: id)
            if selectedNodeID == id { selectedNodeID = nil }
        }
    }
}

/// Adapter that lets SwiftUI's `OutlineGroup` walk the flat-array tree.
private struct BookmarkOutlineNode: Identifiable {
    let node: BookmarkNode
    let allNodes: [BookmarkNode]

    var id: UUID { node.id }

    /// `nil` for leaves (bookmarks); a sorted list of children for
    /// folders, including empty folders represented as `[]`.
    var children: [BookmarkOutlineNode]? {
        guard node.kind == .folder else { return nil }
        let kids = allNodes
            .filter { $0.parentID == node.id }
            .sorted { lhs, rhs in
                if lhs.kind != rhs.kind {
                    return lhs.kind == .folder && rhs.kind == .bookmark
                }
                return lhs.sortOrder < rhs.sortOrder
            }
            .map { BookmarkOutlineNode(node: $0, allNodes: allNodes) }
        return kids
    }
}
