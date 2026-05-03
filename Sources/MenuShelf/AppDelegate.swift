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
        installRescueStatusItem()
        container.start()
        removeRescueStatusItem()

        if container.store.settings.resolvedMenuViews.isEmpty {
            container.settingsWindowController.show()
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
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
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            DiagnosticsLogger.shared.log(
                "Rescue status item attached title=\(item.button?.title ?? "nil") window=\(String(describing: item.button?.window)) windowFrame=\(String(describing: item.button?.window?.frame)) frame=\(String(describing: item.button?.frame)) visible=\(item.isVisible)"
            )
        }
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
