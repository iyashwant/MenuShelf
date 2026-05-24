//
//  BookmarkShelfStorage.swift
//  MenuShelf
//
//  Owner of the Bookmark Shelf in-memory tree and its on-disk file
//  `~/Library/Application Support/MenuShelf/bookmarks.json`. Decoupled
//  from `PreferencesStore` so a bookmark edit never rewrites
//  `settings.json`, and a settings edit never rewrites `bookmarks.json`
//  (Requirement 4.10). Every public mutation runs on `@MainActor`,
//  publishes through `@Published var nodes` (Requirement 5.10), and
//  schedules a debounced write on a dedicated serial I/O queue
//  (Requirements 4.4, 4.8, 4.9).
//

import Combine
import Foundation

@MainActor
final class BookmarkShelfStorage: ObservableObject {

    // MARK: - Published state

    /// In-memory tree. Mutations publish through `@Published` so SwiftUI
    /// views and the MenuBuilder observe changes immediately
    /// (Requirement 5.10).
    @Published private(set) var nodes: [BookmarkNode] = []

    /// Fires when a debounced write completes successfully on disk. Used
    /// by `BookmarkShelfController.stop()` and by tests to confirm a
    /// flush.
    let didFlush = PassthroughSubject<Void, Never>()

    /// Current on-disk schema version known to this build. Bumping this
    /// requires extending `migratedNodes(_:)` (Requirement 4.7).
    static let currentSchemaVersion: Int = 1

    // MARK: - Internal state

    /// Dedicated serial queue for off-main disk I/O (Requirement 4.9).
    private let ioQueue = DispatchQueue(
        label: "app.menushelf.bookmark-shelf.io",
        qos: .utility
    )

    /// Debounce timer for `scheduleSave()`. Cancelled on each new
    /// mutation so a burst of edits coalesces into one write
    /// (Requirement 4.4).
    private var pendingSave: DispatchSourceTimer?

    /// Sentinel set to `true` after a successful load OR a successful
    /// write. Until then, a missing file produces an empty tree without
    /// writing anything (Requirement 4.5). On a decode failure we leave
    /// this `false` so the corrupt file stays untouched until the user
    /// explicitly creates a node (Requirement 4.6).
    private var hasMaterialized = false

    /// Snapshot used by `beginTransaction()` / `rollback()` so importers
    /// can roll back on parse failure (Requirement 12.12).
    private var pendingTransaction: [BookmarkNode]?

    /// One-time per-session toast guard for the depth-cap notice
    /// (Requirement 6.2).
    private var didReportFolderDepthError = false

    // MARK: - File location

    /// Resolved canonical URL of `bookmarks.json`. The parent directory
    /// is created lazily on first access with
    /// `withIntermediateDirectories: true` (Requirement 4.1).
    static let fileURL: URL = {
        let appSupport = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        let menuShelfDir = appSupport.appendingPathComponent("MenuShelf", isDirectory: true)
        try? FileManager.default.createDirectory(
            at: menuShelfDir,
            withIntermediateDirectories: true,
            attributes: nil
        )
        return menuShelfDir.appendingPathComponent("bookmarks.json", isDirectory: false)
    }()

    // MARK: - On-disk envelope

    /// Top-level shape of `bookmarks.json` (Requirement 4.2).
    private struct StorageEnvelope: Codable {
        var schemaVersion: Int
        var nodes: [BookmarkNode]
    }

    private struct MigrationResult {
        let nodes: [BookmarkNode]
        let didMigrate: Bool
    }

    // MARK: - Lifecycle

    init() {
        load()
    }

    /// Read `bookmarks.json` from disk, run the in-file migration ladder,
    /// run the decode-time normalization step (Requirements 1.4–1.6,
    /// 1.10), and assign `nodes`. On failure logs only the error type
    /// and surfaces a one-time non-modal error via
    /// `AppContainer.shared.store.showError(_:)`, then falls back to an
    /// empty in-memory tree without writing (Requirement 4.6).
    private func load() {
        let url = Self.fileURL
        guard FileManager.default.fileExists(atPath: url.path) else {
            // First run: empty tree, no write until a mutation occurs
            // (Requirement 4.5).
            self.nodes = []
            return
        }
        do {
            let data = try Data(contentsOf: url)
            let envelope = try JSONDecoder().decode(StorageEnvelope.self, from: data)
            let migrated = Self.migratedNodes(envelope)
            let normalized = Self.normalize(migrated.nodes)
            self.nodes = normalized
            self.hasMaterialized = true
            // If the migration step or the normalization step changed
            // the on-disk shape, persist the new shape so the next
            // launch reads it cheaply.
            if migrated.didMigrate || normalized.count != migrated.nodes.count {
                scheduleSave()
            }
        } catch {
            // Privacy: log only the error type, never the user-supplied
            // file contents (Requirement 19.4 / Property B10).
            DiagnosticsLogger.shared.log(
                "BookmarkShelf load failed: \(type(of: error))"
            )
            AppContainer.shared.store.showError(
                "Bookmark Shelf could not load saved bookmarks. Existing data is preserved."
            )
            self.nodes = []
            // Do NOT set hasMaterialized — the on-disk file stays
            // untouched until the user explicitly creates a node
            // (Requirement 4.6).
        }
    }

    // MARK: - Public mutations (Requirement 5)

    /// Append a new `.bookmark` node under `parentID`. Rejects when the
    /// parent's depth would push the node beyond the 5-level cap
    /// (Requirements 5.1, 5.8, 6.1). Returns the created node, or `nil`
    /// when the operation was rejected.
    @discardableResult
    func addBookmark(
        parentID: UUID?,
        title: String,
        url: String,
        isFavorite: Bool
    ) -> BookmarkNode? {
        guard depth(of: parentID) <= 5 else {
            AppContainer.shared.store.showError(
                "Bookmark folders are limited to 5 levels of nesting."
            )
            return nil
        }
        let nextSort = (nodes.filter { $0.parentID == parentID }
            .map(\.sortOrder).max() ?? -1) + 1
        let node = BookmarkNode.makeBookmark(
            parentID: parentID,
            title: title,
            url: url,
            isFavorite: isFavorite,
            sortOrder: nextSort
        )
        nodes.append(node)
        scheduleSave()
        return node
    }

    /// Append a new `.folder` node under `parentID`. A folder placed
    /// under a parent of depth N becomes depth N+1. Rejects when the new
    /// depth would exceed 5 (Requirement 6.2). Surfaces the depth-cap
    /// toast at most once per process session.
    @discardableResult
    func addFolder(parentID: UUID?, title: String) -> BookmarkNode? {
        guard depth(of: parentID) + 1 <= 5 else {
            if !didReportFolderDepthError {
                didReportFolderDepthError = true
                AppContainer.shared.store.showError(
                    "Bookmark folders are limited to 5 levels of nesting."
                )
            }
            return nil
        }
        let nextSort = (nodes.filter { $0.parentID == parentID }
            .map(\.sortOrder).max() ?? -1) + 1
        let folder = BookmarkNode.makeFolder(
            parentID: parentID,
            title: title,
            sortOrder: nextSort
        )
        nodes.append(folder)
        scheduleSave()
        return folder
    }

    /// Remove the node and every descendant. No-op when `id` is missing
    /// (Requirement 5.3; Property B4 — calling twice equals calling
    /// once).
    func removeNode(id: UUID) {
        guard let stored = nodes.first(where: { $0.id == id }) else { return }
        let originalParent = stored.parentID
        let toRemove = descendantIDs(of: id).union([id])
        nodes.removeAll { toRemove.contains($0.id) }
        // Renumber under the original parent and under the root so any
        // possibly-affected sibling group becomes contiguous and
        // zero-based ascending again.
        renumberSiblings(under: originalParent)
        renumberSiblings(under: nil)
        scheduleSave()
    }

    /// Apply the caller's payload to the matching node, preserving
    /// immutable fields (`id`, `kind`, `parentID`, `sortOrder`,
    /// `createdAt`) and bumping `updatedAt`. No-op when `id` is missing
    /// (Requirement 5.4). `url` is forced to `nil` when the stored kind
    /// is `.folder` (Requirement 1.5).
    func updateNode(_ node: BookmarkNode) {
        guard let index = nodes.firstIndex(where: { $0.id == node.id }) else { return }
        let stored = nodes[index]
        let updated = BookmarkNode(
            id: stored.id,
            kind: stored.kind,
            title: node.title,
            url: stored.kind == .bookmark ? node.url : nil,
            parentID: stored.parentID,
            sortOrder: stored.sortOrder,
            isFavorite: node.isFavorite,
            icon: node.icon,
            iconColorHex: node.iconColorHex,
            createdAt: stored.createdAt,
            updatedAt: Date(),
            lastOpenedAt: node.lastOpenedAt
        )
        nodes[index] = updated
        scheduleSave()
    }

    /// Relocate `id` under `toParentID`, optionally before
    /// `beforeSiblingID`. Renumbers both source-parent's and
    /// destination-parent's siblings. Rejects cycle-creating moves and
    /// depth-cap violations (Requirements 5.5, 6.3, 6.5).
    func moveNode(id: UUID, toParentID: UUID?, beforeSiblingID: UUID?) {
        guard let sourceIndex = nodes.firstIndex(where: { $0.id == id }) else { return }
        let source = nodes[sourceIndex]

        // Reject cycles: the new parent must not be the node itself or
        // any descendant of the node.
        if let target = toParentID {
            if target == id { return }
            if descendantIDs(of: id).contains(target) { return }
        }

        // Reject depth-cap violations: every descendant must end up at
        // depth ≤ 5.
        let newParentDepth = depth(of: toParentID)
        let subtreeMaxAdditionalDepth = maxDescendantDepth(of: id)
        if newParentDepth + 1 + subtreeMaxAdditionalDepth > 5 {
            if !didReportFolderDepthError {
                didReportFolderDepthError = true
                AppContainer.shared.store.showError(
                    "Bookmark folders are limited to 5 levels of nesting."
                )
            }
            return
        }

        let oldParent = source.parentID
        var moved = source
        moved.parentID = toParentID
        moved.updatedAt = Date()

        // Compute the destination sortOrder from the destination
        // siblings sorted ascending. When `beforeSiblingID` matches a
        // destination sibling, place the node at that index, otherwise
        // append.
        let destinationSiblings = nodes
            .filter { $0.parentID == toParentID && $0.id != id }
            .sorted { $0.sortOrder < $1.sortOrder }
        let insertAt: Int
        if let beforeID = beforeSiblingID,
           let beforeIdx = destinationSiblings.firstIndex(where: { $0.id == beforeID }) {
            insertAt = beforeIdx
        } else {
            insertAt = destinationSiblings.count
        }
        moved.sortOrder = insertAt

        nodes[sourceIndex] = moved
        renumberSiblings(under: oldParent)
        renumberSiblings(under: toParentID)
        scheduleSave()
    }

    /// Toggle the favorite flag (Requirement 5.6). No-op on absent id.
    func setFavorite(id: UUID, isFavorite: Bool) {
        guard let index = nodes.firstIndex(where: { $0.id == id }) else { return }
        nodes[index].isFavorite = isFavorite
        nodes[index].updatedAt = Date()
        scheduleSave()
    }

    /// Stamp the node's `lastOpenedAt` to now (Requirement 5.7). Note
    /// this method does NOT bump `updatedAt`: the spec separates the
    /// "user edited the bookmark" timestamp from the "user opened the
    /// bookmark" timestamp. No-op on absent id.
    func recordOpened(id: UUID) {
        guard let index = nodes.firstIndex(where: { $0.id == id }) else { return }
        nodes[index].lastOpenedAt = Date()
        scheduleSave()
    }

    // MARK: - Transactional helpers (Import — Requirement 12.12)

    /// Snapshot the tree. The caller must pair this with `commit()` or
    /// `rollback()`. Nesting is unsupported in v1: a second call without
    /// an intervening commit/rollback returns without overwriting the
    /// snapshot.
    func beginTransaction() {
        guard pendingTransaction == nil else { return }
        pendingTransaction = nodes
    }

    /// Drop the snapshot. Committing keeps the current state; the
    /// already-scheduled debounced save handles persistence.
    func commit() {
        pendingTransaction = nil
    }

    /// Restore the pre-transaction snapshot and persist the rolled-back
    /// state.
    func rollback() {
        guard let snapshot = pendingTransaction else { return }
        nodes = snapshot
        pendingTransaction = nil
        scheduleSave()
    }

    // MARK: - Depth-cap and cycle helpers

    /// Returns the depth of a node by id; -1 for nil (the conceptual
    /// "above-root" depth, so root-level nodes are depth 0). The walk
    /// uses a `visited` set so a corrupt cycle in the in-memory array
    /// cannot loop forever (Requirement 6.5).
    func depth(of nodeID: UUID?) -> Int {
        guard let nodeID else { return -1 }
        var current: UUID? = nodeID
        var d = 0
        var visited = Set<UUID>()
        while let id = current, !visited.contains(id) {
            visited.insert(id)
            guard let node = nodes.first(where: { $0.id == id }) else { return d }
            current = node.parentID
            if current != nil { d += 1 }
        }
        return d
    }

    /// Breadth-first walk over `nodes` collecting every descendant id.
    /// Used by `removeNode` cascade and the moveNode cycle check.
    func descendantIDs(of rootID: UUID) -> Set<UUID> {
        var result = Set<UUID>()
        var queue = [rootID]
        while let head = queue.popLast() {
            for child in nodes where child.parentID == head {
                if result.insert(child.id).inserted {
                    queue.append(child.id)
                }
            }
        }
        return result
    }

    /// Recursive DFS returning the max depth of `rootID`'s descendant
    /// chain relative to `rootID` itself: 0 means `rootID` has no
    /// descendants; 1 means the deepest descendant is a direct child;
    /// and so on. Used by `moveNode` to validate the depth cap before
    /// accepting a relocation.
    private func maxDescendantDepth(of rootID: UUID) -> Int {
        var maxDepth = 0
        for child in nodes where child.parentID == rootID {
            let childDepth = 1 + maxDescendantDepth(of: child.id)
            if childDepth > maxDepth { maxDepth = childDepth }
        }
        return maxDepth
    }

    /// Re-number every sibling under `parentID` so the surviving
    /// `sortOrder`s are contiguous and zero-based ascending. Idempotent.
    private func renumberSiblings(under parentID: UUID?) {
        let siblings = nodes.enumerated()
            .filter { $0.element.parentID == parentID }
            .sorted { lhs, rhs in
                if lhs.element.sortOrder != rhs.element.sortOrder {
                    return lhs.element.sortOrder < rhs.element.sortOrder
                }
                return lhs.element.id.uuidString < rhs.element.id.uuidString
            }
        for (newIndex, pair) in siblings.enumerated() {
            nodes[pair.offset].sortOrder = newIndex
        }
    }

    // MARK: - Persistence

    /// Coalesce mutation bursts and flush to disk on the dedicated I/O
    /// queue. The 500 ms debounce sits inside the 300–1000 ms window
    /// required by Requirement 4.4.
    private func scheduleSave() {
        pendingSave?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + .milliseconds(500))
        timer.setEventHandler { [weak self] in
            self?.write()
        }
        timer.resume()
        pendingSave = timer
    }

    /// Encode the in-memory tree, write to disk atomically (temp file
    /// plus rename), and publish `didFlush`. Runs the encode and the
    /// write on the I/O queue so the main actor never blocks on disk
    /// for more than the cost of `Array.sorted(...)` on a few hundred
    /// elements (Requirements 4.8, 4.9).
    private func write() {
        let snapshot = sortedForOnDisk(nodes)
        let envelope = StorageEnvelope(
            schemaVersion: Self.currentSchemaVersion,
            nodes: snapshot
        )
        // Capture the file URL on the main actor before hopping onto the
        // I/O queue so the Sendable closure does not have to reach back
        // through `Self.fileURL`.
        let url = Self.fileURL
        ioQueue.async { [weak self] in
            guard self != nil else { return }
            let temp = url.appendingPathExtension("tmp")
            do {
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
                encoder.dateEncodingStrategy = .iso8601
                let data = try encoder.encode(envelope)
                try data.write(to: temp, options: .atomic)
                _ = try FileManager.default.replaceItemAt(url, withItemAt: temp)
                Task { @MainActor [weak self] in
                    self?.hasMaterialized = true
                    self?.didFlush.send(())
                }
            } catch {
                Task { @MainActor in
                    DiagnosticsLogger.shared.log(
                        "BookmarkShelf write failed: \(type(of: error))"
                    )
                }
            }
        }
    }

    /// Force a synchronous flush. Used by `BookmarkShelfController.stop()`
    /// to guarantee the final mutation reaches disk before tear-down
    /// releases the storage handle (Requirements 4.9, 7.5).
    func flushNow() {
        pendingSave?.cancel()
        pendingSave = nil
        let snapshot = sortedForOnDisk(nodes)
        let envelope = StorageEnvelope(
            schemaVersion: Self.currentSchemaVersion,
            nodes: snapshot
        )
        let url = Self.fileURL
        ioQueue.sync {
            let temp = url.appendingPathExtension("tmp")
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
            encoder.dateEncodingStrategy = .iso8601
            do {
                let data = try encoder.encode(envelope)
                try data.write(to: temp, options: .atomic)
                _ = try FileManager.default.replaceItemAt(url, withItemAt: temp)
            } catch {
                DiagnosticsLogger.shared.log(
                    "BookmarkShelf flushNow failed: \(type(of: error))"
                )
            }
        }
        hasMaterialized = true
    }

    /// Return `nodes` sorted by `(parentID, sortOrder, id)` ascending so
    /// the on-disk shape is byte-stable across save/load round trips
    /// (Requirement 1.9). Property B3 verifies this ordering invariant
    /// externally.
    private func sortedForOnDisk(_ array: [BookmarkNode]) -> [BookmarkNode] {
        return array.sorted { lhs, rhs in
            let lp = lhs.parentID?.uuidString ?? ""
            let rp = rhs.parentID?.uuidString ?? ""
            if lp != rp { return lp < rp }
            if lhs.sortOrder != rhs.sortOrder { return lhs.sortOrder < rhs.sortOrder }
            return lhs.id.uuidString < rhs.id.uuidString
        }
    }

    // MARK: - Decode-time normalization (Requirements 1.4, 1.5, 1.6, 1.10)

    /// Idempotent four-pass cleanup applied to the array decoded from
    /// disk before it becomes the in-memory tree. Property B12 relies
    /// on `normalize(normalize(x)) == normalize(x)`.
    private static func normalize(_ array: [BookmarkNode]) -> [BookmarkNode] {
        // Step 1: drop bookmarks whose URL is missing or doesn't parse
        // to an http/https scheme. Log only the dropped node's UUID
        // (Requirements 1.4, 19.4).
        let step1 = array.filter { node in
            guard node.kind == .bookmark else { return true }
            guard let raw = node.url?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !raw.isEmpty,
                  let parsed = URL(string: raw),
                  let scheme = parsed.scheme?.lowercased(),
                  scheme == "http" || scheme == "https" else {
                DiagnosticsLogger.shared.log(
                    "BookmarkShelf dropped invalid bookmark id=\(node.id.uuidString)"
                )
                return false
            }
            return true
        }

        // Step 2: clear url on folders (Requirement 1.5).
        let step2 = step1.map { node -> BookmarkNode in
            guard node.kind == .folder else { return node }
            var copy = node
            copy.url = nil
            return copy
        }

        // Step 3: title placeholder substitution (Requirement 1.6).
        let step3 = step2.map { node -> BookmarkNode in
            let trimmed = node.title.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.isEmpty else {
                var copy = node
                copy.title = trimmed
                return copy
            }
            var copy = node
            switch node.kind {
            case .folder:
                copy.title = "Untitled"
            case .bookmark:
                let host = node.url
                    .flatMap(URL.init(string:))?
                    .host
                    .flatMap { $0.isEmpty ? nil : $0 }
                copy.title = host ?? "Untitled"
            }
            return copy
        }

        // Step 4: parent re-rooting (Requirement 1.10) — any parentID
        // referencing a missing id or a bookmark id is rewritten to nil.
        let folderIDs = Set(step3.filter { $0.kind == .folder }.map(\.id))
        return step3.map { node -> BookmarkNode in
            guard let parentID = node.parentID else { return node }
            if folderIDs.contains(parentID) { return node }
            var copy = node
            copy.parentID = nil
            return copy
        }
    }

    // MARK: - In-file migration ladder (Requirement 4.7)

    /// At v1 the ladder is a no-op for `schemaVersion == 1`; future
    /// rungs append where the inline comment indicates, mirroring
    /// `PreferencesStore.migratedSettings`. Property B2 verifies the
    /// identity case.
    private static func migratedNodes(_ envelope: StorageEnvelope) -> MigrationResult {
        let current = envelope
        let didMigrate = false

        // Future rungs go here. The pattern mirrors
        // PreferencesStore.migratedSettings — when the first rung lands,
        // re-declare `current` and `didMigrate` as `var`:
        //
        // var current = envelope
        // var didMigrate = false
        // if current.schemaVersion < 2 {
        //     current.schemaVersion = 2
        //     // ...backfill new fields on each node...
        //     didMigrate = true
        // }

        if current.schemaVersion > Self.currentSchemaVersion {
            // Forward-compatible read: an older build sees a newer
            // file. Decode whatever fields it understands and continue.
            // (Privacy: structural notice only — no user-supplied
            // strings.)
            DiagnosticsLogger.shared.log(
                "BookmarkShelf bookmarks.json is from a newer build "
                + "(schema=\(current.schemaVersion))"
            )
        }

        return MigrationResult(nodes: current.nodes, didMigrate: didMigrate)
    }
}
