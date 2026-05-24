//
//  BookmarkShelfPopupState.swift
//  MenuShelf
//
//  In-memory state container driving `BookmarkShelfPopupView`. Holds
//  the breadcrumb back-stack and the currently-viewed folder ID.
//  Reset to root on panel close (Requirements 8.4, 8.5, 8.11).
//
//  Conforms to `ObservableObject` rather than the modern `@Observable`
//  macro so it composes naturally with the `BookmarkShelfStorage`
//  ObservableObject the popup view also subscribes to. The two views
//  are tied together through SwiftUI's `@ObservedObject` machinery.
//

import Combine
import Foundation

/// One entry in the breadcrumb back-stack. Carries the folder's `id`
/// so the popup can pop back to a specific level by index, and the
/// folder's `title` so the breadcrumb can render `"Root › Folder A"`
/// without re-resolving the node from the storage tree on every render.
struct BreadcrumbEntry: Equatable, Identifiable {
    let id: UUID
    let title: String
}

/// Observable backing for the popup SwiftUI tree. The panel owns one
/// instance for its lifetime; the controller's `handlePanelClose()`
/// calls `popToRoot()` so reopening the popup always lands at the
/// root (Requirement 8.11).
@MainActor
final class BookmarkShelfPopupState: ObservableObject {
    /// `nil` means the root level. Otherwise the `id` of the folder
    /// whose children are currently visible.
    @Published var currentFolderID: UUID?

    /// Breadcrumb back-stack. The first entry is the topmost child of
    /// root; `breadcrumb.count` equals the depth below root. Empty
    /// means we are at root.
    @Published var breadcrumb: [BreadcrumbEntry] = []

    init(currentFolderID: UUID? = nil, breadcrumb: [BreadcrumbEntry] = []) {
        self.currentFolderID = currentFolderID
        self.breadcrumb = breadcrumb
    }

    /// Push `folder` onto the back-stack and view its children. The
    /// caller is responsible for ensuring `folder.kind == .folder`.
    func push(folder: BookmarkNode) {
        breadcrumb.append(BreadcrumbEntry(id: folder.id, title: folder.title))
        currentFolderID = folder.id
    }

    /// Truncate the back-stack so its length equals `level`, then
    /// update `currentFolderID` to match. `level == 0` clears the
    /// stack entirely; `level == breadcrumb.count` is a no-op. Out-of-
    /// range values are clamped.
    func popTo(level: Int) {
        let clamped = max(0, min(level, breadcrumb.count))
        if clamped == 0 {
            breadcrumb.removeAll()
            currentFolderID = nil
            return
        }
        breadcrumb = Array(breadcrumb.prefix(clamped))
        currentFolderID = breadcrumb.last?.id
    }

    /// Convenience: clear the back-stack and return to the root view.
    func popToRoot() {
        breadcrumb.removeAll()
        currentFolderID = nil
    }

    /// `true` when the popup is showing the root level (no folder
    /// selected). Used by the popup view to decide whether to render
    /// the breadcrumb header and the Favorites section.
    var isAtRoot: Bool { breadcrumb.isEmpty }
}
