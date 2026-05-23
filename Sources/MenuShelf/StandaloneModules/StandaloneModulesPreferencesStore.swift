import AppKit
import Foundation
import UniformTypeIdentifiers

extension PreferencesStore {
    /// Append a new standalone module with `Module_Defaults` for `kind`.
    /// Returns the created value.
    @discardableResult
    func addStandaloneModule(kind: ModuleKind) -> StandaloneModuleConfig {
        var array = settings.resolvedStandaloneModules
        let entry = StandaloneModuleConfig.make(kind: kind, sortOrder: array.count)
        array.append(entry)
        settings.standaloneModules = array
        return entry
    }

    /// Remove the matching entry and renumber `sortOrder` to be
    /// contiguous, zero-based, and ascending in the same relative
    /// order. No-op when `id` is not present (Requirement 4.8).
    func removeStandaloneModule(id: UUID) {
        var array = settings.resolvedStandaloneModules
        guard array.contains(where: { $0.id == id }) else { return }
        array.removeAll { $0.id == id }
        for newIndex in array.indices {
            array[newIndex].sortOrder = newIndex
        }
        settings.standaloneModules = array
    }

    /// Locate the matching entry by `id`, preserve `kind`,
    /// `sortOrder`, and `createdAt`, apply every other field from the
    /// caller-provided value, and bump `updatedAt`. No-op when `id`
    /// is not present (Requirement 4.9). The defensive re-read of
    /// `kind` enforces Requirement 1.7 even if a future caller
    /// hand-constructs a struct with a mismatched `kind`.
    func updateStandaloneModule(_ config: StandaloneModuleConfig) {
        var array = settings.resolvedStandaloneModules
        guard let index = array.firstIndex(where: { $0.id == config.id }) else { return }
        let stored = array[index]
        let updated = StandaloneModuleConfig(
            id: stored.id,                  // immutable
            kind: stored.kind,              // immutable (Req 1.7)
            isVisible: config.isVisible,
            title: config.title,
            icon: config.icon,
            iconColorHex: config.iconColorHex,
            menuBarStyle: config.menuBarStyle,
            shortcut: config.shortcut,
            sortOrder: stored.sortOrder,    // preserved
            createdAt: stored.createdAt,    // preserved
            updatedAt: Date()               // bumped
        )
        array[index] = updated
        settings.standaloneModules = array
    }

    /// Apply SwiftUI `.move` semantics over a `sortOrder`-sorted
    /// snapshot of the array, then renumber `sortOrder` to be
    /// contiguous, zero-based, and ascending.
    func moveStandaloneModules(fromOffsets source: IndexSet, toOffset destination: Int) {
        var array = settings.resolvedStandaloneModules
        array.sort { $0.sortOrder < $1.sortOrder }
        array.move(fromOffsets: source, toOffset: destination)
        for newIndex in array.indices {
            array[newIndex].sortOrder = newIndex
        }
        settings.standaloneModules = array
    }

    // MARK: - Visibility convenience (Requirement 4.5)

    /// Convenience that flips `isVisible` only and bumps `updatedAt`.
    /// Internally builds the equivalent `updateStandaloneModule(_:)`
    /// semantics inline so the immutable-field guarantees still
    /// hold: `id` and `kind` are `let` on `StandaloneModuleConfig`,
    /// and `sortOrder` / `createdAt` are preserved by mutating only
    /// `isVisible` and `updatedAt` on the stored value. No-op when
    /// `id` is not present (mirrors `updateStandaloneModule(_:)`).
    func setStandaloneModuleVisibility(id: UUID, isVisible: Bool) {
        var array = settings.resolvedStandaloneModules
        guard let index = array.firstIndex(where: { $0.id == id }) else { return }
        var updated = array[index]
        updated.isVisible = isVisible
        updated.updatedAt = Date()
        array[index] = updated
        settings.standaloneModules = array
    }
}

extension PreferencesStore {
    /// Mirror of `selectCustomIconForMenuView(id:)` for standalone
    /// modules. Prompts the user with an `NSOpenPanel`, copies the
    /// selected image into the app's support directory, captures a
    /// security-scoped bookmark, and assigns it to the matching
    /// standalone module via `updateStandaloneModule(_:)`.
    func selectCustomIconForStandaloneModule(id: UUID) {
        let panel = NSOpenPanel()
        panel.title = "Choose Standalone Module Icon"
        panel.message = "Choose an image to use for this menu bar icon."
        panel.prompt = "Choose"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.allowedContentTypes = [.image]

        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            let iconsURL = supportURL.appendingPathComponent("Icons", isDirectory: true)
            try FileManager.default.createDirectory(at: iconsURL, withIntermediateDirectories: true)
            let destination = iconsURL.appendingPathComponent("\(id.uuidString).\(url.pathExtension.isEmpty ? "png" : url.pathExtension)")
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.copyItem(at: url, to: destination)
            let bookmarkData = try destination.bookmarkData(
                options: [.withSecurityScope],
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )

            guard var module = settings.resolvedStandaloneModules.first(where: { $0.id == id }) else { return }
            module.icon = .customImage(bookmarkData: bookmarkData)
            module.iconColorHex = nil
            updateStandaloneModule(module)
        } catch {
            showError("Could not use custom icon: \(error.localizedDescription)")
        }
    }
}
