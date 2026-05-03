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
        guard commandName(for: url) == "run-shortcut" else { return }

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

    private func commandName(for url: URL) -> String? {
        if url.host == "run-shortcut" {
            return "run-shortcut"
        }

        if url.host == "x-callback-url" {
            return url.pathComponents.dropFirst().first
        }

        return url.pathComponents.dropFirst().first
    }
}
