//
//  BookmarkShelfPopupView.swift
//  MenuShelf
//
//  SwiftUI tree for the Bookmark Shelf popup. Composed of:
//
//  - Optional breadcrumb header rendered when `!state.isAtRoot`,
//    formatted as `"Root › Folder A › Folder B"` with each crumb
//    a tappable button (Requirement 8.5).
//  - Optional "Favorites" section rendered above the regular list
//    when `state.isAtRoot` and the user has not turned the section
//    off in settings (Requirement 8.6).
//  - The current folder's children, with `.folder` rows above
//    `.bookmark` rows within the same `sortOrder` band (Requirement
//    8.3).
//  - An inline "+ Add URL" form at the bottom of every folder view
//    (Requirement 8.7).
//
//  The popup binds NO 1-9 number-key shortcuts in v1 (Requirement
//  8.12). Drag-drop wiring to `BookmarkShelfImportService` lands in
//  Task 9; this view leaves a TODO marker at the drop site.
//

import AppKit
import SwiftUI

@MainActor
struct BookmarkShelfPopupView: View {
    @ObservedObject var state: BookmarkShelfPopupState
    @ObservedObject var storage: BookmarkShelfStorage

    /// Pull the live setting on every render so toggling
    /// `showFavoritesSection` in the settings pane takes effect on
    /// the next popup open (or, when the popup is already open, on
    /// the next state change).
    private var showFavoritesSection: Bool {
        AppContainer.shared.store.settings
            .resolvedBookmarkShelf.showFavoritesSection
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !state.isAtRoot {
                BreadcrumbHeader(state: state)
                Divider()
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if state.isAtRoot && showFavoritesSection {
                        FavoritesSection(state: state, storage: storage)
                    }

                    childrenSection
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
            }
            // TODO: wire to BookmarkShelfImportService when Task 9 lands
            // (drop target accepting public.url and public.text UTIs,
            // dispatching into
            // `BookmarkShelfImportService.shared.importDroppedURLs(_:
            // intoFolderID: state.currentFolderID)`).

            Divider()
            AddURLForm(state: state, storage: storage)
        }
        .frame(minWidth: 280, minHeight: 360)
        .background(.background)
    }

    // MARK: - Children section

    @ViewBuilder
    private var childrenSection: some View {
        let children = visibleChildren
        if children.isEmpty {
            HStack(spacing: 8) {
                Image(systemName: "tray")
                    .foregroundStyle(.secondary)
                Text("Empty")
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.vertical, 8)
        } else {
            ForEach(children) { node in
                BookmarkShelfRowView(node: node, state: state, storage: storage)
            }
        }
    }

    /// Children of the currently-viewed folder, sorted ascending by
    /// `sortOrder`, with `.folder` rows above `.bookmark` rows within
    /// the same band so users can scan folder structure first
    /// (Requirement 8.3).
    private var visibleChildren: [BookmarkNode] {
        let parentID = state.currentFolderID
        return storage.nodes
            .filter { $0.parentID == parentID }
            .sorted { lhs, rhs in
                if lhs.sortOrder != rhs.sortOrder {
                    return lhs.sortOrder < rhs.sortOrder
                }
                if lhs.kind != rhs.kind {
                    return lhs.kind == .folder
                }
                return lhs.id.uuidString < rhs.id.uuidString
            }
    }
}

// MARK: - Breadcrumb header

private struct BreadcrumbHeader: View {
    @ObservedObject var state: BookmarkShelfPopupState

    var body: some View {
        HStack(spacing: 4) {
            Button("Root") {
                state.popTo(level: 0)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)

            ForEach(Array(state.breadcrumb.enumerated()), id: \.element.id) { index, entry in
                Text("›")
                    .foregroundStyle(.secondary)
                Button(entry.title) {
                    state.popTo(level: index + 1)
                }
                .buttonStyle(.plain)
                .lineLimit(1)
                .foregroundStyle(index == state.breadcrumb.count - 1 ? .primary : .secondary)
            }
            Spacer()
        }
        .font(.caption)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }
}

// MARK: - Favorites section

private struct FavoritesSection: View {
    @ObservedObject var state: BookmarkShelfPopupState
    @ObservedObject var storage: BookmarkShelfStorage

    private var favorites: [BookmarkNode] {
        storage.nodes
            .filter { $0.isFavorite }
            .sorted { lhs, rhs in
                if lhs.sortOrder != rhs.sortOrder {
                    return lhs.sortOrder < rhs.sortOrder
                }
                return lhs.updatedAt < rhs.updatedAt
            }
    }

    var body: some View {
        let items = favorites
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Image(systemName: "star.fill")
                        .foregroundStyle(.yellow)
                    Text("Favorites")
                        .font(.caption.smallCaps())
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(.horizontal, 4)
                .padding(.vertical, 4)

                ForEach(items) { node in
                    BookmarkShelfRowView(node: node, state: state, storage: storage)
                }

                Divider()
                    .padding(.vertical, 4)
            }
        }
    }
}

// MARK: - Add URL form

private struct AddURLForm: View {
    @ObservedObject var state: BookmarkShelfPopupState
    @ObservedObject var storage: BookmarkShelfStorage

    @State private var title: String = ""
    @State private var urlString: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                TextField("Title", text: $title)
                    .textFieldStyle(.roundedBorder)
                TextField("https://", text: $urlString)
                    .textFieldStyle(.roundedBorder)
                Button("Add") {
                    addBookmark()
                }
                .disabled(!isValid)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var isValid: Bool {
        let trimmedURL = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedURL.isEmpty,
              let parsed = URL(string: trimmedURL),
              let scheme = parsed.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else { return false }
        return true
    }

    private func addBookmark() {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedURL = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedTitle = trimmedTitle.isEmpty
            ? (URL(string: trimmedURL)?.host ?? "Untitled")
            : trimmedTitle

        _ = storage.addBookmark(
            parentID: state.currentFolderID,
            title: resolvedTitle,
            url: trimmedURL,
            isFavorite: false
        )
        title = ""
        urlString = ""
    }
}
