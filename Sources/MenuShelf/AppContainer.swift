import Combine
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

    private var clipboardShelfSettingsSubscription: AnyCancellable?
    private var worldClockSettingsSubscription: AnyCancellable?
    private var bookmarkShelfSettingsSubscription: AnyCancellable?

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
        if store.settings.resolvedBrowserFlip.enableBrowserFlip {
            store.refreshBrowsers()
        }

        // Bring up Clipboard Shelf if enabled. The controller is idempotent
        // and will no-op if it's already running. We also subscribe to
        // settings changes so the controller picks up enable/disable
        // toggles and live polling-interval / pasteboard-type changes
        // without an app restart (Requirement 7.9, 2.2).
        let initialClipboardShelf = store.settings.resolvedClipboardShelf
        if initialClipboardShelf.enableClipboardShelf {
            Task { @MainActor in
                ClipboardShelfController.shared.start(with: initialClipboardShelf)
            }
        }
        clipboardShelfSettingsSubscription = store.$settings
            .map { $0.resolvedClipboardShelf }
            .removeDuplicates()
            .dropFirst()
            .sink { newSettings in
                Task { @MainActor in
                    ClipboardShelfController.shared.apply(settings: newSettings)
                }
            }

        // Bring up World Clock if enabled. The controller is idempotent
        // and will no-op if it's already running. We also subscribe to
        // settings changes so the controller picks up enable/disable
        // toggles, clock list edits, and appearance changes without an
        // app restart (Requirement 13.5).
        let initialWorldClock = store.settings.resolvedWorldClock
        if initialWorldClock.enableWorldClock {
            Task { @MainActor in
                WorldClockController.shared.start(with: initialWorldClock)
            }
        }
        worldClockSettingsSubscription = store.$settings
            .map { $0.resolvedWorldClock }
            .removeDuplicates()
            .dropFirst()
            .sink { newSettings in
                Task { @MainActor in
                    WorldClockController.shared.apply(settings: newSettings)
                }
            }

        // Bring up Bookmark Shelf if enabled. The controller is idempotent
        // and will no-op if it's already running. Subscribe to settings
        // changes so the controller picks up enable/disable toggles, popup
        // size and hotkey edits without an app restart (Requirement 17.2,
        // 17.3).
        let initialBookmark = store.settings.resolvedBookmarkShelf
        if initialBookmark.enableBookmarkShelf {
            Task { @MainActor in
                BookmarkShelfController.shared.start(with: initialBookmark)
            }
        }
        bookmarkShelfSettingsSubscription = store.$settings
            .map { $0.resolvedBookmarkShelf }
            .removeDuplicates()
            .dropFirst()
            .sink { newSettings in
                Task { @MainActor in
                    BookmarkShelfController.shared.apply(settings: newSettings)
                }
            }

        statusItemManager.rebuildStatusItems()
    }
}
