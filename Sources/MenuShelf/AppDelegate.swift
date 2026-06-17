import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private lazy var container = AppContainer.shared
    private var rescueStatusItem: NSStatusItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let policySuccess = NSApp.setActivationPolicy(.accessory)
        DiagnosticsLogger.shared.log("Set activation policy to accessory: \(policySuccess)")
        DiagnosticsLogger.shared.log("Application did finish launching")
        DiagnosticsLogger.shared.log(
            "Runtime bundlePath=\(Bundle.main.bundlePath) executable=\(Bundle.main.executablePath ?? "nil") activationPolicy=\(NSApp.activationPolicy().rawValue) mainThread=\(Thread.isMainThread)"
        )
        // The rescue status item flashes a placeholder in the menu bar while the
        // real items are being built. It's only useful when chasing startup
        // ordering bugs, so gate it behind verbose diagnostics rather than
        // showing it on every normal launch.
        let useRescue = container.store.settings.resolvedEnableVerboseDiagnostics
        if useRescue { installRescueStatusItem() }
        container.start()
        if useRescue { removeRescueStatusItem() }

        if container.store.settings.resolvedMenuViews.isEmpty {
            container.settingsWindowController.show()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        DiagnosticsLogger.shared.log("Application will terminate")
        // Stop Clock Shelf first so its pinned status items are removed
        // and the minute-aligned timer is invalidated before the
        // Clipboard Shelf controller releases its container. Both stops
        // run before the settings flush so any future quit-time logic
        // inside either controller has a chance to run.
        ClockShelfController.shared.stop()
        // Stop Clipboard Shelf monitor and release its container before
        // settings flush so any clearOnQuit/clearPinnedOnQuit logic that
        // future tasks add inside the controller has a chance to run.
        ClipboardShelfController.shared.stop()
        // Synchronously clear the lid-closed `disablesleep` system flag (if we
        // set it) BEFORE stopping — an async reset might not finish before the
        // process exits, which would leave the Mac unable to sleep.
        CaffeineShelfController.shared.flushLidStateForQuit()
        // Stop CaffeineShelf so its IOKit power assertion is always released
        // before the process exits — a leaked assertion would keep the Mac
        // awake after MenuShelf quits.
        CaffeineShelfController.shared.stop()
        // Flush any debounced settings save so user changes don't get lost on quit.
        container.store.flushPendingSave()
        DiagnosticsLogger.shared.endSession()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        DiagnosticsLogger.shared.log("Open URLs: \(urls.map(\.absoluteString).joined(separator: ", "))")

        // Route http(s) and the custom menushelf-ask:// scheme into the
        // "Ask Everytime" picker. This runs when MenuShelf is set as the
        // system default browser.
        var pickerURLs: [URL] = []
        var routerURLs: [URL] = []
        for url in urls {
            switch url.scheme?.lowercased() {
            case "http", "https", "menushelf-ask":
                pickerURLs.append(url)
            default:
                routerURLs.append(url)
            }
        }

        if !pickerURLs.isEmpty {
            MenuShelfPickerController.shared.handle(urls: pickerURLs)
        }
        if !routerURLs.isEmpty {
            container.shortcutURLRouter.handle(routerURLs)
        }
    }

    func application(_ application: NSApplication, willContinueUserActivityWithType userActivityType: String) -> Bool {
        return userActivityType == NSUserActivityTypeBrowsingWeb
    }

    func application(_ application: NSApplication, continue userActivity: NSUserActivity, restorationHandler: @escaping ([any NSUserActivityRestoring]) -> Void) -> Bool {
        if let url = userActivity.webpageURL {
            MenuShelfPickerController.shared.handle(urls: [url])
            return true
        }
        return false
    }

    private func installRescueStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: 72)
        item.length = 72

        if let button = item.button {
            button.title = "MS RUN"
            button.image = NSImage(systemSymbolName: "shippingbox", accessibilityDescription: "MenuShelf")
            button.image?.isTemplate = true
            button.imagePosition = .imageLeading
            button.toolTip = "MenuShelf"
        }

        let menu = NSMenu(title: "MenuShelf")
        menu.autoenablesItems = false

        let settings = NSMenuItem(title: "Open Settings", action: #selector(openSettingsFromRescueItem(_:)), keyEquivalent: "")
        settings.target = self
        menu.addItem(settings)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit MenuShelf", action: #selector(NSApplication.terminate(_:)), keyEquivalent: ""))

        item.menu = menu
        rescueStatusItem = item
        DiagnosticsLogger.shared.log("Installed rescue status item title=\(item.button?.title ?? "nil") length=\(item.length)")
    }

    @objc private func openSettingsFromRescueItem(_ sender: Any?) {
        container.settingsWindowController.show()
    }

    private func removeRescueStatusItem() {
        guard let item = rescueStatusItem else { return }
        NSStatusBar.system.removeStatusItem(item)
        rescueStatusItem = nil
        DiagnosticsLogger.shared.log("Removed rescue status item")
    }
}
