//
//  ClipboardShelfStorage.swift
//  MenuShelf
//
//  Thin MenuShelf-side wrapper around the vendored Maccy `Storage` class.
//  Exists so the Clipboard Shelf controller can surface SwiftData container
//  failures via MenuShelf's normal user-facing error path
//  (`store.showError(_:)`) instead of relying on the vendored fatalError
//  (Requirement 3.8). The wrapper does not own the SwiftData container —
//  it shares `Storage.shared` with the vendored core, but exposes an
//  initializer that throws when that shared container is running on the
//  in-memory fallback.
//

import Foundation
import SwiftData

enum ClipboardShelfStorageError: LocalizedError {
    case couldNotOpenContainer(underlying: Error)

    var errorDescription: String? {
        switch self {
        case .couldNotOpenContainer(let underlying):
            return "Clipboard Shelf could not open its history database: \(underlying.localizedDescription)"
        }
    }
}

@MainActor
final class ClipboardShelfStorage {
    let inner: Storage

    var container: ModelContainer { inner.container }
    var context: ModelContext { inner.context }

    /// Bytes on disk for the SwiftData store, or 0 if the file is missing
    /// or unreadable. Used by the settings pane's "Storage" card.
    var onDiskByteSize: Int64 {
        let url = URL.applicationSupportDirectory.appending(path: "MenuShelf/ClipboardShelf.sqlite")
        guard let size = try? url.resourceValues(forKeys: [.fileSizeKey])
            .allValues.first?.value as? Int64 else {
            return 0
        }
        return size
    }

    /// Throws when the underlying SwiftData container could not be opened
    /// at the configured on-disk URL and the vendored `Storage.shared` is
    /// running on the in-memory fallback. The controller catches this once
    /// per session and surfaces it through `store.showError(_:)`.
    init() throws {
        let storage = Storage.shared
        if storage.isFallbackInMemory, let error = storage.loadError {
            throw ClipboardShelfStorageError.couldNotOpenContainer(underlying: error)
        }
        self.inner = storage
    }
}
