import Foundation

enum FolderVisibilityIntentMode: String, Codable, CaseIterable {
    case showSelected
    case hideSelected
    case showOnlySelected
    case showAll
}

final class AppIntentVisibilityBridge {
    private let store: PreferencesStore
    private let presentationCoordinator: MenuPresentationCoordinator

    init(store: PreferencesStore, presentationCoordinator: MenuPresentationCoordinator) {
        self.store = store
        self.presentationCoordinator = presentationCoordinator
    }

    @MainActor
    func menuViewsSnapshot() -> [MenuViewConfig] {
        store.settings.resolvedMenuViews
    }

    @MainActor
    func setVisibility(mode: FolderVisibilityIntentMode, folderIDs: [UUID]) {
        switch mode {
        case .showSelected:
            for id in folderIDs {
                store.setMenuViewVisibility(id: id, isVisible: true)
            }

        case .hideSelected:
            for id in folderIDs {
                store.setMenuViewVisibility(id: id, isVisible: false)
            }

        case .showOnlySelected:
            let selected = Set(folderIDs)
            // Use the documented update channel rather than mutating
            // store.settings.menuViews directly. This preserves invariants in
            // updateMenuView (timestamping, persistence, rebuild).
            for view in store.settings.resolvedMenuViews {
                store.setMenuViewVisibility(id: view.id, isVisible: selected.contains(view.id))
            }

        case .showAll:
            store.showAllMenuViews()
        }
    }

    @MainActor
    func openMenu(folderID: UUID?) {
        if let folderID {
            presentationCoordinator.presentMenu(
                forMenuViewID: folderID,
                location: store.settings.resolvedShortcutOpenLocation
            )
        } else {
            presentationCoordinator.presentGroupedMenu(atCursor: store.settings.resolvedShortcutOpenLocation == .cursor)
        }
    }
}
