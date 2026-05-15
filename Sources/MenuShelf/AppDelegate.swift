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
        // Flush any debounced settings save so user changes don't get lost on quit.
        container.store.flushPendingSave()
        DiagnosticsLogger.shared.endSession()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        DiagnosticsLogger.shared.log("Open URLs: \(urls.map(\.absoluteString).joined(separator: ", "))")
        container.shortcutURLRouter.handle(urls)
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
