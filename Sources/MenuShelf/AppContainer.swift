import Foundation

final class AppContainer {
    static let shared = AppContainer()

    let store: PreferencesStore
    let fileAccessService: FileAccessService
    let metadataService: MetadataService
    let actionHandler: MenuActionHandler
    let menuBuilder: MenuBuilder
    let presentationCoordinator: MenuPresentationCoordinator
    let hotkeyService: GlobalHotkeyService
    let intentBridge: AppIntentVisibilityBridge
    let statusItemManager: StatusItemManager
    let settingsWindowController: SettingsWindowController

    private init() {
        store = PreferencesStore()
        fileAccessService = FileAccessService()
        metadataService = MetadataService()
        actionHandler = MenuActionHandler(
            store: store,
            fileAccessService: fileAccessService,
            metadataService: metadataService
        )
        menuBuilder = MenuBuilder(
            store: store,
            fileAccessService: fileAccessService,
            metadataService: metadataService,
            actionHandler: actionHandler
        )
        presentationCoordinator = MenuPresentationCoordinator(
            store: store,
            menuBuilder: menuBuilder
        )
        hotkeyService = GlobalHotkeyService()
        intentBridge = AppIntentVisibilityBridge(
            store: store,
            presentationCoordinator: presentationCoordinator
        )
        statusItemManager = StatusItemManager(
            store: store,
            menuBuilder: menuBuilder,
            actionHandler: actionHandler,
            metadataService: metadataService,
            presentationCoordinator: presentationCoordinator,
            hotkeyService: hotkeyService
        )
        settingsWindowController = SettingsWindowController(store: store)
    }

    func start() {
        statusItemManager.rebuildStatusItems()
    }
}
