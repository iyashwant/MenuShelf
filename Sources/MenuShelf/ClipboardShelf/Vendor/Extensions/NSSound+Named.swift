import AppKit.NSSound

extension NSSound {
  // Resolve sounds via `Bundle.module`, the SPM-generated accessor for the
  // executable target's own resource bundle. The earlier `Bundle.main`
  // lookup was nil at runtime because the .caf files ship inside
  // `MenuShelf_MenuShelf.bundle` at the app root, not under
  // `Contents/Resources/`. Hitting the force-unwrap crashed the process on
  // the first copy event (the pasteboard monitor calls `Notifier.notify(...
  // sound: .write)` for new items), which made the menu bar items vanish.
  static let knock = makeBundledSound(named: "Knock")
  static let write = makeBundledSound(named: "Write")

  private static func makeBundledSound(named name: String) -> NSSound? {
    guard let url = Bundle.module.url(forResource: name, withExtension: "caf") else {
      DiagnosticsLogger.shared.log(
        "ClipboardShelf sound \(name).caf missing from resource bundle; copy notifications will be silent."
      )
      return nil
    }
    return NSSound(contentsOf: url, byReference: true)
  }
}
