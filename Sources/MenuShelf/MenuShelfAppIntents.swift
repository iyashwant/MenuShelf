import AppIntents
import Foundation

struct MenuShelfMenuViewEntity: AppEntity {
    static var typeDisplayRepresentation = TypeDisplayRepresentation(name: "MenuShelf Menu View")
    static var defaultQuery = MenuShelfMenuViewQuery()

    let id: String
    let name: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)")
    }
}

struct MenuShelfMenuViewQuery: EntityQuery {
    func entities(for identifiers: [String]) async throws -> [MenuShelfMenuViewEntity] {
        let views = await MainActor.run {
            AppContainer.shared.intentBridge.menuViewsSnapshot()
        }

        return views.compactMap { view in
            guard identifiers.contains(view.id.uuidString) else { return nil }
            return MenuShelfMenuViewEntity(id: view.id.uuidString, name: view.title)
        }
    }

    func suggestedEntities() async throws -> [MenuShelfMenuViewEntity] {
        let views = await MainActor.run {
            AppContainer.shared.intentBridge.menuViewsSnapshot()
        }

        return views.map { view in
            MenuShelfMenuViewEntity(id: view.id.uuidString, name: view.title)
        }
    }
}

enum MenuViewVisibilityAppMode: String, AppEnum {
    case showSelected
    case hideSelected
    case showOnlySelected
    case showAll

    static var typeDisplayRepresentation = TypeDisplayRepresentation(name: "Menu View Visibility Mode")
    static var caseDisplayRepresentations: [MenuViewVisibilityAppMode: DisplayRepresentation] = [
        .showSelected: "Show selected folders",
        .hideSelected: "Hide selected folders",
        .showOnlySelected: "Show only selected folders",
        .showAll: "Show all folders"
    ]

    var bridgeMode: FolderVisibilityIntentMode {
        switch self {
        case .showSelected: .showSelected
        case .hideSelected: .hideSelected
        case .showOnlySelected: .showOnlySelected
        case .showAll: .showAll
        }
    }
}

struct SetFolderVisibilityIntent: AppIntent {
    static var title: LocalizedStringResource = "Set Menu View Visibility"
    static var description = IntentDescription("Shows or hides MenuShelf menu views for project-focused menu bar setups.")

    @Parameter(title: "Mode")
    var mode: MenuViewVisibilityAppMode

    @Parameter(title: "Menu Views")
    var menuViews: [MenuShelfMenuViewEntity]?

    @MainActor
    func perform() async throws -> some IntentResult {
        let ids = (menuViews ?? []).compactMap { UUID(uuidString: $0.id) }
        AppContainer.shared.intentBridge.setVisibility(mode: mode.bridgeMode, folderIDs: ids)
        return .result()
    }
}

struct OpenMenuViewIntent: AppIntent {
    static var title: LocalizedStringResource = "Open Menu View"
    static var description = IntentDescription("Opens a MenuShelf menu view from Shortcuts.")

    @Parameter(title: "Menu View")
    var folder: MenuShelfMenuViewEntity?

    @MainActor
    func perform() async throws -> some IntentResult {
        AppContainer.shared.intentBridge.openMenu(folderID: folder.flatMap { UUID(uuidString: $0.id) })
        return .result()
    }
}

struct MenuShelfShortcutsProvider: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: SetFolderVisibilityIntent(),
            phrases: ["Set \(.applicationName) menu view visibility"],
            shortTitle: "Set View Visibility",
            systemImageName: "slider.horizontal.3"
        )

        AppShortcut(
            intent: OpenMenuViewIntent(),
            phrases: ["Open \(.applicationName) menu view"],
            shortTitle: "Open Menu View",
            systemImageName: "menubar.rectangle"
        )
    }
}
