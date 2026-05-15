import Foundation

final class AppContainer {
    static let shared = AppContainer()

    let store: PreferencesStore
    let shortcutsService: ShortcutsService
    let fileAccessService: FileAccessService
    let metadataService: MetadataService
    let appleScriptService: AppleScriptService
    let actionHandler: MenuActionHandler
    let menuBuilder: MenuBuilder
    let presentationCoordinator: MenuPresentationCoordinator
    let hotkeyService: GlobalHotkeyService
    let intentBridge: AppIntentVisibilityBridge
    let shortcutURLRouter: ShortcutURLRouter
    let statusItemManager: StatusItemManager
    let settingsWindowController: SettingsWindowController

    private init() {
        shortcutsService = ShortcutsService()
        fileAccessService = FileAccessService()
        appleScriptService = AppleScriptService()
        store = PreferencesStore(shortcutsService: shortcutsService, fileAccessService: fileAccessService)
        metadataService = MetadataService()
        actionHandler = MenuActionHandler(
            store: store,
            fileAccessService: fileAccessService,
            metadataService: metadataService,
            shortcutsService: shortcutsService,
            appleScriptService: appleScriptService
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
        shortcutURLRouter = ShortcutURLRouter(
            store: store,
            shortcutsService: shortcutsService
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
