import Foundation

/// The kind of a `BookmarkNode`. Cases are declared in the order required
/// by Requirement 1.2: `.bookmark` first, `.folder` second.
///
/// A node's `kind` is set at creation time and is never changed afterwards.
/// To "convert" between kinds the user must remove the node and add a new
/// one. `BookmarkShelfStorage.updateNode(_:)` defensively re-reads the
/// stored `kind` so even an explicit caller-supplied struct with a
/// mismatched `kind` cannot mutate the binding (Requirement 1.3).
enum BookmarkNodeKind: String, Codable, CaseIterable, Equatable, Identifiable {
    case bookmark
    case folder

    var id: String { rawValue }
}

/// A single node in the Bookmark Shelf tree. Persisted to
/// `~/Library/Application Support/MenuShelf/bookmarks.json` as part of a
/// flat array keyed by `id`; the parent/child relationship is expressed
/// exclusively via `parentID` (Requirement 1.7).
///
/// `id` and `kind` are declared `let` so Swift's value-semantics prevent
/// in-place mutation through `update*` operations (Requirement 1.3).
struct BookmarkNode: Codable, Identifiable, Equatable {
    let id: UUID
    let kind: BookmarkNodeKind
    var title: String
    var url: String?
    var parentID: UUID?
    var sortOrder: Int
    var isFavorite: Bool
    var icon: FolderIconConfig?
    var iconColorHex: String?
    var createdAt: Date
    var updatedAt: Date
    var lastOpenedAt: Date?

    /// Build a fresh `.bookmark` node. Trims `title` and `url` and
    /// pre-populates timestamps. The caller is responsible for validating
    /// the URL's scheme; the storage layer's add path also re-validates,
    /// so this factory is safe to call from tests.
    static func makeBookmark(
        parentID: UUID?,
        title: String,
        url: String,
        isFavorite: Bool,
        sortOrder: Int
    ) -> BookmarkNode {
        let now = Date()
        return BookmarkNode(
            id: UUID(),
            kind: .bookmark,
            title: title.trimmingCharacters(in: .whitespacesAndNewlines),
            url: url.trimmingCharacters(in: .whitespacesAndNewlines),
            parentID: parentID,
            sortOrder: sortOrder,
            isFavorite: isFavorite,
            icon: nil,
            iconColorHex: nil,
            createdAt: now,
            updatedAt: now,
            lastOpenedAt: nil
        )
    }

    /// Build a fresh `.folder` node. `url` is forced to `nil` per
    /// Requirement 1.5; `isFavorite` defaults to `false` for folders.
    static func makeFolder(
        parentID: UUID?,
        title: String,
        sortOrder: Int
    ) -> BookmarkNode {
        let now = Date()
        return BookmarkNode(
            id: UUID(),
            kind: .folder,
            title: title.trimmingCharacters(in: .whitespacesAndNewlines),
            url: nil,
            parentID: parentID,
            sortOrder: sortOrder,
            isFavorite: false,
            icon: nil,
            iconColorHex: nil,
            createdAt: now,
            updatedAt: now,
            lastOpenedAt: nil
        )
    }
}
