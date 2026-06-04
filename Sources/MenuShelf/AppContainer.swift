import Combine
import Foundation
import KeyboardShortcuts

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
        if menuShelfModuleShouldRun(.clipboardShelf, in: store.settings) {
            let initialClipboardShelf = store.settings.resolvedClipboardShelf
            Task { @MainActor in
                ClipboardShelfController.shared.start(with: initialClipboardShelf)
            }
        }
        clipboardShelfSettingsSubscription = store.$settings
            .map { ModuleRunState(settings: $0.resolvedClipboardShelf,
                                  run: menuShelfModuleShouldRun(.clipboardShelf, in: $0)) }
            .removeDuplicates()
            .dropFirst()
            .sink { state in
                Task { @MainActor in
                    if state.run {
                        ClipboardShelfController.shared.start(with: state.settings)
                    } else {
                        ClipboardShelfController.shared.stop()
                    }
                }
            }

        // Bring up World Clock if enabled. The controller is idempotent
        // and will no-op if it's already running. We also subscribe to
        // settings changes so the controller picks up enable/disable
        // toggles, clock list edits, and appearance changes without an
        // app restart (Requirement 13.5).
        if menuShelfModuleShouldRun(.worldClock, in: store.settings) {
            let initialWorldClock = store.settings.resolvedWorldClock
            Task { @MainActor in
                WorldClockController.shared.start(with: initialWorldClock)
            }
        }
        worldClockSettingsSubscription = store.$settings
            .map { ModuleRunState(settings: $0.resolvedWorldClock,
                                  run: menuShelfModuleShouldRun(.worldClock, in: $0)) }
            .removeDuplicates()
            .dropFirst()
            .sink { state in
                Task { @MainActor in
                    if state.run {
                        WorldClockController.shared.start(with: state.settings)
                    } else {
                        WorldClockController.shared.stop()
                    }
                }
            }

        // Bring up Bookmark Shelf if enabled. The controller is idempotent
        // and will no-op if it's already running. Subscribe to settings
        // changes so the controller picks up enable/disable toggles, popup
        // size and hotkey edits without an app restart (Requirement 17.2,
        // 17.3).
        if menuShelfModuleShouldRun(.bookmarkShelf, in: store.settings) {
            let initialBookmark = store.settings.resolvedBookmarkShelf
            Task { @MainActor in
                BookmarkShelfController.shared.start(with: initialBookmark)
            }
        }
        bookmarkShelfSettingsSubscription = store.$settings
            .map { ModuleRunState(settings: $0.resolvedBookmarkShelf,
                                  run: menuShelfModuleShouldRun(.bookmarkShelf, in: $0)) }
            .removeDuplicates()
            .dropFirst()
            .sink { state in
                Task { @MainActor in
                    if state.run {
                        BookmarkShelfController.shared.start(with: state.settings)
                    } else {
                        BookmarkShelfController.shared.stop()
                    }
                }
            }

        statusItemManager.rebuildStatusItems()
    }
}

// MARK: - Module run gating

/// A module's settings snapshot plus whether it should currently run.
/// Equatable so the settings subscription only reacts to real changes.
private struct ModuleRunState<S: Equatable>: Equatable {
    let settings: S
    let run: Bool
}

private func menuShelfPopupHotkeyName(for kind: ModuleKind) -> KeyboardShortcuts.Name? {
    switch kind {
    case .clipboardShelf: .popup
    case .worldClock: .worldClockPopup
    case .bookmarkShelf: .bookmarkShelfPopup
    case .browserFlip: nil
    }
}

private func menuShelfModuleEnabled(_ kind: ModuleKind, in s: AppSettings) -> Bool {
    switch kind {
    case .clipboardShelf: s.resolvedClipboardShelf.enableClipboardShelf
    case .worldClock: s.resolvedWorldClock.enableWorldClock
    case .bookmarkShelf: s.resolvedBookmarkShelf.enableBookmarkShelf
    case .browserFlip: s.resolvedBrowserFlip.enableBrowserFlip
    }
}

/// A module's background work (timers, monitors, storage) runs only when it is
/// enabled AND reachable: it has UI presence (a visible standalone item or an
/// item embedded in any menu view) or a configured popup hotkey. An enabled but
/// unreachable module stays idle so it consumes no resources.
private func menuShelfModuleShouldRun(_ kind: ModuleKind, in s: AppSettings) -> Bool {
    guard menuShelfModuleEnabled(kind, in: s) else { return false }
    if s.hasModulePresence(kind) { return true }
    if let name = menuShelfPopupHotkeyName(for: kind), KeyboardShortcuts.getShortcut(for: name) != nil {
        return true
    }
    return false
}
