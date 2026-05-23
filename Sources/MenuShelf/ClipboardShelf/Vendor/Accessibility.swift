import AppKit

/// Vendored from Maccy with one MenuShelf edit: when the process is not
/// trusted for AX, route the prompt through `ClipboardShelfController`
/// so the user sees a one-time guidance alert with a deep-link to
/// System Settings → Privacy & Security → Accessibility (Requirement
/// 10.3 / 10.4).
struct Accessibility {
  private static var allowed: Bool { AXIsProcessTrustedWithOptions(nil) }

  static func check() {
    guard !allowed else {
      return
    }
    // Post to the main queue so we satisfy the MainActor isolation
    // requirement of `ClipboardShelfController` without forcing every
    // caller (vendored `Clipboard.paste`, `PasteStack`) to be MainActor.
    DispatchQueue.main.async {
      ClipboardShelfController.shared.handleAccessibilityDenial()
    }
  }
}
