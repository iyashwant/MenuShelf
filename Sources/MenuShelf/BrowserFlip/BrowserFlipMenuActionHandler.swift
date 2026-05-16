//
//  BrowserFlipMenuActionHandler.swift
//  MenuShelf
//
//  Browser-flip-specific menu action handling. The `.switchBrowser` enum case
//  must stay in MenuActionHandler.execute(_:) since it's inside an exhaustive
//  switch, but its result handling lives here.
//

import AppKit

extension MenuActionHandler {
    func handleBrowserSwitchResult(_ result: DefaultBrowserSwitchResult, browser: BrowserInfo, store: PreferencesStore) {
        store.currentDefaultBrowserID = DefaultBrowserService.shared.currentDefaultBrowserID()

        switch result {
        case .success:
            break

        case .userKeptPrevious(let currentName):
            let alert = NSAlert()
            alert.messageText = "Default Browser Not Changed"
            alert.informativeText = "macOS kept the previous default browser (\(currentName)).\n\nIf a confirmation prompt appeared, please choose \"Use \(browser.name).\" You can also change it manually in System Settings."
            alert.alertStyle = .warning
            alert.addButton(withTitle: "Open System Settings")
            alert.addButton(withTitle: "OK")
            if alert.runModal() == .alertFirstButtonReturn {
                if let url = URL(string: "x-apple.systempreferences:com.apple.Desktop-Settings.extension") {
                    NSWorkspace.shared.open(url)
                }
            }

        case .partialFailure(let httpChanged, let httpsChanged, _):
            var message = "Only partial success:\n"
            message += "HTTP: \(httpChanged ? "✓ Changed" : "✗ Unchanged")\n"
            message += "HTTPS: \(httpsChanged ? "✓ Changed" : "✗ Unchanged")\n\n"
            message += "Try again or change manually in System Settings."
            let alert = NSAlert()
            alert.messageText = "Partial Failure"
            alert.informativeText = message
            alert.alertStyle = .warning
            alert.addButton(withTitle: "OK")
            alert.runModal()

        case .browserUnavailable:
            let alert = NSAlert()
            alert.messageText = "Browser Not Found"
            alert.informativeText = "\(browser.name) appears to have been moved or deleted. Please refresh browsers in Settings."
            alert.alertStyle = .warning
            alert.addButton(withTitle: "OK")
            alert.runModal()

        case .timeout:
            let alert = NSAlert()
            alert.messageText = "Waiting for Confirmation"
            alert.informativeText = "macOS is waiting for your confirmation. Look for a default-browser confirmation dialog and click \"Use \(browser.name).\"\n\nIf no dialog appeared, try again or change manually in System Settings."
            alert.alertStyle = .warning
            alert.addButton(withTitle: "OK")
            alert.runModal()

        case .systemError(let error, _):
            var message = error.localizedDescription
            if let dbError = error as? DefaultBrowserError, case .permissionDenied = dbError {
                message = "macOS blocked the browser change.\n\nIf you are running an unsigned copy of MenuShelf, try signing it with:\ncodesign --force --deep --sign - /path/to/MenuShelf.app"
            }
            let alert = NSAlert()
            alert.messageText = "Failed to Change Default Browser"
            alert.informativeText = message
            alert.alertStyle = .warning
            alert.addButton(withTitle: "OK")
            alert.runModal()
        }
    }
}
