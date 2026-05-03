import AppKit
import SwiftUI

final class SettingsWindowController: NSObject {
    private let store: PreferencesStore
    private var window: NSWindow?

    init(store: PreferencesStore) {
        self.store = store
    }

    @objc func showFromMenu(_ sender: Any?) {
        show()
    }

    func show(selectedFolderID: UUID? = nil, selectedMenuViewID: UUID? = nil) {
        if let selectedMenuViewID {
            store.selectedMenuViewID = selectedMenuViewID
        }

        if let selectedFolderID {
            store.selectedFolderID = selectedFolderID
        }

        if window == nil {
            let rootView = SettingsView()
                .environmentObject(store)

            let hostingController = NSHostingController(rootView: rootView)
            let settingsWindow = NSWindow(contentViewController: hostingController)
            settingsWindow.title = "MenuShelf Settings"
            settingsWindow.setContentSize(NSSize(width: 900, height: 620))
            settingsWindow.minSize = NSSize(width: 760, height: 520)
            settingsWindow.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
            settingsWindow.titlebarAppearsTransparent = true
            settingsWindow.isReleasedWhenClosed = false
            settingsWindow.center()
            window = settingsWindow
        }

        NSRunningApplication.current.activate(options: [.activateAllWindows, .activateIgnoringOtherApps])
        window?.makeKeyAndOrderFront(nil)
        window?.orderFrontRegardless()
        DiagnosticsLogger.shared.log("Settings window ordered front")
    }
}
