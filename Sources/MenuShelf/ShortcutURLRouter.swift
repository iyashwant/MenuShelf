import Foundation

final class ShortcutURLRouter {
    private let store: PreferencesStore
    private let shortcutsService: ShortcutsService

    init(store: PreferencesStore, shortcutsService: ShortcutsService) {
        self.store = store
        self.shortcutsService = shortcutsService
    }

    func handle(_ urls: [URL]) {
        for url in urls {
            handle(url)
        }
    }

    func handle(_ url: URL) {
        guard url.scheme?.lowercased() == "menushelf" else { return }
        let command = commandName(for: url)
        switch command {
        case "run-shortcut":
            routeRunShortcut(url: url)
        case "run-applescript":
            routeRunAppleScript(url: url)
        default:
            return
        }
    }

    private func routeRunShortcut(url: URL) {
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let queryItems = components?.queryItems ?? []
        let name = queryItems.first { $0.name == "name" }?.value
        let identifier = queryItems.first { $0.name == "id" }?.value
        let inputType = queryItems.first { $0.name == "input" }?.value
        let text = queryItems.first { $0.name == "text" }?.value

        guard let identifierOrName = identifier ?? name else {
            store.showError("menushelf://run-shortcut requires a name or id parameter.")
            return
        }

        let textInput = inputType == "text" ? text : nil
        Task { [shortcutsService] in
            do {
                try await shortcutsService.runShortcut(identifierOrName: identifierOrName, textInput: textInput)
            } catch {
                await MainActor.run {
                    self.store.showError("Could not run shortcut: \(error.localizedDescription)")
                }
            }
        }
    }

    private func routeRunAppleScript(url: URL) {
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let queryItems = components?.queryItems ?? []
        let idValue = queryItems.first { $0.name == "id" }?.value
        let nameValue = queryItems.first { $0.name == "name" }?.value

        let scripts = store.settings.resolvedAppleScripts

        if let idValue {
            guard let uuid = UUID(uuidString: idValue) else {
                store.showError("menushelf://run-applescript: id is not a valid UUID (\(idValue)).")
                DiagnosticsLogger.shared.log("run-applescript invalid id=\(idValue)")
                return
            }
            guard scripts.contains(where: { $0.id == uuid }) else {
                store.showError("AppleScript not found: \(idValue)")
                DiagnosticsLogger.shared.log("run-applescript missing id=\(uuid.uuidString)")
                return
            }
            DiagnosticsLogger.shared.log("run-applescript dispatch id=\(uuid.uuidString)")
            AppContainer.shared.actionHandler.appleScriptCoordinator.run(scriptID: uuid, fromMenuViewID: nil)
            return
        }

        guard let nameValue, !nameValue.isEmpty else {
            store.showError("menushelf://run-applescript requires either id or name.")
            return
        }
        guard nameValue.count <= 255 else {
            store.showError("AppleScript name parameter is too long.")
            DiagnosticsLogger.shared.log("run-applescript name too long (\(nameValue.count) chars)")
            return
        }

        let matches = scripts.filter { $0.name == nameValue }
        if matches.count == 1 {
            let id = matches[0].id
            DiagnosticsLogger.shared.log("run-applescript dispatch name=\(nameValue) id=\(id.uuidString)")
            AppContainer.shared.actionHandler.appleScriptCoordinator.run(scriptID: id, fromMenuViewID: nil)
        } else if matches.isEmpty {
            store.showError("AppleScript not found: \(nameValue)")
            DiagnosticsLogger.shared.log("run-applescript missing name=\(nameValue)")
        } else {
            store.showError("Multiple AppleScripts named \(nameValue). Use the id parameter to disambiguate.")
            DiagnosticsLogger.shared.log("run-applescript ambiguous name=\(nameValue) count=\(matches.count)")
        }
    }

    private func commandName(for url: URL) -> String? {
        if let host = url.host?.lowercased(), host == "run-shortcut" || host == "run-applescript" {
            return host
        }

        if url.host == "x-callback-url" {
            return url.pathComponents.dropFirst().first
        }

        return url.pathComponents.dropFirst().first
    }
}
