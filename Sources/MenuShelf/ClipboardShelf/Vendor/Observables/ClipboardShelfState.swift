import AppKit
import Defaults
import Foundation
import SwiftUI

/// Vendored from Maccy's `AppState` (renamed). MenuShelf-specific edits:
/// - Removed `import Settings` and the bundled SettingsWindowController
///   (MenuShelf owns the settings window via `SettingsWindowController.swift`).
/// - Removed `About`/`AppDelegate` couplings.
/// - `openPreferences()` and `openAbout()` are routed through MenuShelf
///   handlers configured at runtime by `ClipboardShelfController`.
@Observable
final class ClipboardShelfState: @unchecked Sendable {
  static let shared = ClipboardShelfState(history: History.shared, footer: Footer())

  let multiSelectionEnabled = false

  /// MenuShelf-supplied handler invoked when the user picks "Preferences…"
  /// from the clipboard popup footer. Set by `ClipboardShelfController`.
  var openPreferencesHandler: (() -> Void)?

  /// MenuShelf-supplied handler invoked when the user picks "About"
  /// from the clipboard popup footer. Optional; if unset, the menu item is
  /// effectively a no-op.
  var openAboutHandler: (() -> Void)?

  /// The floating panel hosting the clipboard popup. Set by
  /// `ClipboardShelfController` after the panel is built. Read by the
  /// vendored `SlideoutController` for window-frame-relative animations.
  var panel: NSWindow?

  var popup: Popup
  var history: History
  var footer: Footer
  var navigator: NavigationManager
  var preview: SlideoutController

  var searchVisible: Bool {
    if !Defaults[.showSearch] { return false }
    switch Defaults[.searchVisibility] {
    case .always: return true
    case .duringSearch: return !history.searchQuery.isEmpty
    }
  }

  var menuIconText: String {
    var title = history.unpinnedItems.first?.text.shortened(to: 100)
      .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    title.unicodeScalars.removeAll(where: CharacterSet.newlines.contains)
    return title.shortened(to: 20)
  }

  init(history: History, footer: Footer) {
    self.history = history
    self.footer = footer
    popup = Popup()
    navigator = NavigationManager(history: history, footer: footer)
    preview = SlideoutController(
      onContentResize: { contentWidth in
        Defaults[.windowSize].width = contentWidth
      },
      onSlideoutResize: { previewWidth in
        Defaults[.previewWidth] = previewWidth
      })
    preview.contentWidth = Defaults[.windowSize].width
    preview.slideoutWidth = Defaults[.previewWidth]
  }

  @MainActor
  func select() {
    if !navigator.selection.isEmpty {
      if navigator.isMultiSelectInProgress {
        navigator.isManualMultiSelect = false
        history.startPasteStack(selection: &navigator.selection)
      } else {
        history.select(navigator.selection.first)
      }
    } else if let item = footer.selectedItem {
      // TODO: Use item.suppressConfirmation, but it's not updated!
      if item.confirmation != nil, Defaults[.suppressClearAlert] == false {
        item.showConfirmation = true
      } else {
        item.action()
      }
    } else {
      Clipboard.shared.copy(history.searchQuery)
      history.searchQuery = ""
    }
  }

  @MainActor
  func togglePin() {
    withTransaction(Transaction()) {
      navigator.selection.forEach { _, item in
        history.togglePin(item)
      }
    }
  }

  @MainActor
  func removePasteStack() {
    history.interruptPasteStack()
    navigator.highlightFirst()
  }

  @MainActor
  func deleteSelection() {
    guard let leadItem = navigator.leadHistoryItem else { return }
    let nextUnselectedItem = history.visibleItems.nearest(to: leadItem) { !$0.isSelected }

    withTransaction(Transaction()) {
      navigator.selection.forEach { _, item in
        history.delete(item)
      }
      navigator.select(item: nextUnselectedItem)
    }
  }

  func openAbout() {
    openAboutHandler?()
  }

  @MainActor
  func openPreferences() {
    openPreferencesHandler?()
  }

  func quit() {
    NSApp.terminate(self)
  }
}
