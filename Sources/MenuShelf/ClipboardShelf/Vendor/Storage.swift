import Foundation
import SwiftData

/// Vendored from Maccy with two MenuShelf edits:
///
/// 1. The on-disk path moves under MenuShelf's support directory
///    (Requirement 3.1 / 3.2 / 8.4).
/// 2. The original `fatalError` on container open failure is replaced with
///    an in-memory fallback so the rest of MenuShelf keeps launching when
///    the SwiftData container is unavailable. The user-facing failure is
///    reported through `ClipboardShelfStorage` (Requirement 3.8).
@MainActor
class Storage {
  static let shared = Storage()

  var container: ModelContainer
  var context: ModelContext { container.mainContext }
  var size: String {
    guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).allValues.first?.value as? Int64, size > 1 else {
      return ""
    }

    return ByteCountFormatter().string(fromByteCount: size)
  }

  /// `true` when the SwiftData container could not be opened at the
  /// configured on-disk URL and we are running on an in-memory fallback.
  /// The Clipboard Shelf controller uses this to surface a one-time error.
  let isFallbackInMemory: Bool

  /// The underlying load error, populated when `isFallbackInMemory` is true.
  let loadError: Error?

  private let url = URL.applicationSupportDirectory.appending(path: "MenuShelf/ClipboardShelf.sqlite")

  init() {
    var config = ModelConfiguration(url: url)

    #if DEBUG
    if CommandLine.arguments.contains("enable-testing") {
      config = ModelConfiguration(isStoredInMemoryOnly: true)
    }
    #endif

    do {
      container = try ModelContainer(for: HistoryItem.self, configurations: config)
      isFallbackInMemory = false
      loadError = nil
    } catch {
      DiagnosticsLogger.shared.log("ClipboardShelf storage open failed at \(url.path): \(error.localizedDescription); falling back to in-memory container.")
      let fallbackConfig = ModelConfiguration(isStoredInMemoryOnly: true)
      do {
        container = try ModelContainer(for: HistoryItem.self, configurations: fallbackConfig)
      } catch {
        // Should never happen for an in-memory container; if it does we can't
        // continue. Log and fall through to the original crash semantics.
        DiagnosticsLogger.shared.log("ClipboardShelf in-memory fallback failed: \(error.localizedDescription)")
        fatalError("Cannot load Clipboard Shelf database: \(error.localizedDescription).")
      }
      isFallbackInMemory = true
      loadError = error
    }
  }
}
