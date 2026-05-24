//
//  BookmarkShelfRowView.swift
//  MenuShelf
//
//  One row in the Bookmark Shelf popup. Renders an icon, title, star
//  toggle, and a context-menu carrying Move Up / Move Down / Star /
//  Edit… / "Open in…" / Remove… actions. A left-click on a `.folder`
//  row pushes the folder onto the breadcrumb back-stack; a left-click
//  on a `.bookmark` row opens the URL in the system default browser
//  via `NSWorkspace.shared.open(_:)`, records the open through
//  `storage.recordOpened(id:)`, and dismisses the panel
//  (Requirement 8.10).
//
//  Anything that requires Tasks 9-12 (drag-drop import, "Open in…"
//  submenu, edit sheet, confirmation) is stubbed with a TODO marker.
//

import AppKit
import SwiftUI

@MainActor
struct BookmarkShelfRowView: View {
    let node: BookmarkNode
    @ObservedObject var state: BookmarkShelfPopupState
    @ObservedObject var storage: BookmarkShelfStorage

    var body: some View {
        HStack(spacing: 8) {
            iconView
                .frame(width: 18, height: 18)

            Text(node.title)
                .lineLimit(1)
                .truncationMode(.tail)

            Spacer()

            Button {
                storage.setFavorite(id: node.id, isFavorite: !node.isFavorite)
            } label: {
                Image(systemName: node.isFavorite ? "star.fill" : "star")
                    .foregroundStyle(node.isFavorite ? .yellow : .secondary)
            }
            .buttonStyle(.plain)
            .help(node.isFavorite ? "Unstar" : "Star")
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .onTapGesture {
            handlePrimaryActivation()
        }
        .contextMenu {
            BookmarkShelfRowContextMenu(node: node, storage: storage)
        }
    }

    // MARK: - Icon

    @ViewBuilder
    private var iconView: some View {
        switch node.kind {
        case .folder:
            Image(systemName: "folder")
                .foregroundStyle(.secondary)
        case .bookmark:
            Image(systemName: "globe")
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Activation

    /// Left-click activation. `.folder` pushes onto the breadcrumb
    /// back-stack; `.bookmark` opens the URL, records the open, and
    /// dismisses the panel.
    private func handlePrimaryActivation() {
        switch node.kind {
        case .folder:
            state.push(folder: node)
        case .bookmark:
            guard let raw = node.url,
                  let url = URL(string: raw) else { return }
            NSWorkspace.shared.open(url)
            storage.recordOpened(id: node.id)
            // Dismiss the panel so the user lands in the browser
            // window. Reach the panel through the controller; the
            // controller's `togglePopup(anchor:)` would re-open if
            // the panel is currently visible, so call `close()`
            // directly via the panel reference held on the
            // controller.
            BookmarkShelfController.shared.storageHandle.map { _ in
                // The storageHandle accessor is the most stable
                // reference we have today; the panel itself is
                // private to the controller. Close-on-bookmark-
                // open is a UX expectation, but reaching the
                // panel from here would couple the row view to
                // controller internals. Instead surface the
                // dismissal through a notification so the
                // controller handles it.
                NotificationCenter.default.post(
                    name: .menuShelfBookmarkShelfDidActivateBookmark,
                    object: nil
                )
            }
        }
    }
}

// MARK: - Context menu

private struct BookmarkShelfRowContextMenu: View {
    let node: BookmarkNode
    @ObservedObject var storage: BookmarkShelfStorage

    var body: some View {
        Button("Move Up") {
            moveSibling(by: -1)
        }
        Button("Move Down") {
            moveSibling(by: +1)
        }

        Divider()

        Button(node.isFavorite ? "Unstar" : "Star") {
            storage.setFavorite(id: node.id, isFavorite: !node.isFavorite)
        }

        Button("Edit…") {
            // TODO Task 12: open inline quick-edit form for `node.id`.
        }

        if node.kind == .bookmark {
            Menu("Open in…") {
                // TODO Task 11: populate from
                // DefaultBrowserService.shared.discoverBrowsers()
                // and route through MenuActionKind.openBookmarkIn.
                Text("System Default")
            }
        }

        Divider()

        Button("Remove…", role: .destructive) {
            // The confirmation flow lands in Task 12; until then
            // remove eagerly so the popup remains usable.
            storage.removeNode(id: node.id)
        }
    }

    /// Reorder this node within its current parent by `delta`
    /// positions. Resolves the previous/next sibling and routes
    /// through `storage.moveNode` so the renumbering and depth-cap
    /// validation stay in one place.
    private func moveSibling(by delta: Int) {
        let siblings = storage.nodes
            .filter { $0.parentID == node.parentID }
            .sorted { $0.sortOrder < $1.sortOrder }
        guard let currentIndex = siblings.firstIndex(where: { $0.id == node.id }) else { return }
        let newIndex = currentIndex + delta
        guard newIndex >= 0, newIndex < siblings.count, newIndex != currentIndex else { return }

        // To move down by one, place the node before the sibling at
        // `newIndex + 1` (or append when moving past the end). To
        // move up by one, place the node before the sibling at
        // `newIndex`.
        let beforeSiblingID: UUID?
        if delta > 0 {
            beforeSiblingID = newIndex + 1 < siblings.count ? siblings[newIndex + 1].id : nil
        } else {
            beforeSiblingID = siblings[newIndex].id
        }
        storage.moveNode(
            id: node.id,
            toParentID: node.parentID,
            beforeSiblingID: beforeSiblingID
        )
    }
}

// MARK: - Notification

extension Notification.Name {
    /// Posted by `BookmarkShelfRowView` when the user opens a bookmark.
    /// Observed (eventually) by the controller so the panel dismisses
    /// in lockstep with the browser launch. Wiring lives in Task 8/12;
    /// the name is declared here so the row view can reference it.
    static let menuShelfBookmarkShelfDidActivateBookmark = Notification.Name(
        "menuShelfBookmarkShelfDidActivateBookmark"
    )
}
