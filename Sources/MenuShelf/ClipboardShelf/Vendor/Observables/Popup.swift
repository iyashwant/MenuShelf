import AppKit.NSRunningApplication
import Defaults
import KeyboardShortcuts
import Observation

enum PopupState {
  // Default; shortcut will toggle the popup
  case toggle
  // In this mode, every additional press of the main key
  // will cycle to the next item in the paste history list.
  // Releasing the modifier keys will accept selection and close the popup
  case cycle
  // Transition state when the shortcut is first pressed and
  // we don't know whether we are in "toggle" or "cycle" mode.
  case opening
}

@Observable
class Popup {
  static let verticalSeparatorPadding = 6.0
  static let horizontalSeparatorPadding = 6.0
  static let verticalPadding: CGFloat = 5
  static let horizontalPadding: CGFloat = 5
  static let minimumPreviewHeight: CGFloat = 150

  // Radius used for items inset by the padding. Ensures they visually have the same curvature
  // as the menu.
  static let cornerRadius: CGFloat = if #available(macOS 26.0, *) {
    7
  } else {
    4
  }

  static let itemHeight: CGFloat = if #available(macOS 26.0, *) {
    24
  } else {
    22
  }

  var needsResize = false
  var height: CGFloat = 0
  var headerHeight: CGFloat = 0
  var extraTopHeight: CGFloat = 0
  var extraBottomHeight: CGFloat = 0
  var footerHeight: CGFloat = 0

  private var eventsMonitor: Any?

  private var state: PopupState = .toggle

  init() {
    KeyboardShortcuts.onKeyDown(for: .popup, action: handleFirstKeyDown)
    initEventsMonitor()
  }

  deinit {
    deinitEventsMonitor()
  }

  func initEventsMonitor() {
    guard eventsMonitor == nil else { return }

    self.eventsMonitor = NSEvent.addLocalMonitorForEvents(
      matching: [.flagsChanged, .keyDown],
      handler: handleEvent
    )
  }

  func deinitEventsMonitor() {
    guard let eventsMonitor else { return }

    NSEvent.removeMonitor(eventsMonitor)
  }

  func open(height: CGFloat, at popupPosition: PopupPosition = Defaults[.popupPosition]) {
    (ClipboardShelfState.shared.panel as? FloatingPanel<ClipboardShelfContentView>)?.open(height: height, at: popupPosition)
  }

  func reset() {
    state = .toggle
    KeyboardShortcuts.enable(.popup)
  }

  func close() {
    (ClipboardShelfState.shared.panel as? FloatingPanel<ClipboardShelfContentView>)?.close()  // close() calls reset
  }

  func isClosed() -> Bool {
    (ClipboardShelfState.shared.panel as? FloatingPanel<ClipboardShelfContentView>)?.isPresented != true
  }

  func preferredHeight(for newHeight: CGFloat) -> CGFloat {
    var height = newHeight

    var minimumHeight = 0.0
    // If the preview is non-empty make sure the window accomodates for it to be visible.
    if ClipboardShelfState.shared.preview.state.isOpen && ClipboardShelfState.shared.navigator.leadSelection != nil {
      minimumHeight += Self.minimumPreviewHeight
    }
    minimumHeight = max(headerHeight + Self.verticalPadding, minimumHeight)

    height = max(height, minimumHeight)
    height = min(height, Self.maximumHeight)
    return height
  }

  // MenuShelf: the popup grows with its items up to the height of the
  // screen it's on, minus a small gap above the Dock.
  static var maximumHeight: CGFloat {
    let screen = ClipboardShelfState.shared.panel?.screen ?? NSScreen.forPopup
    guard let visibleHeight = screen?.visibleFrame.height else {
      return Defaults[.windowSize].height
    }
    return visibleHeight - 10
  }

  func resize(height: CGFloat) {
    self.height = height + headerHeight + extraTopHeight + extraBottomHeight + footerHeight
    (ClipboardShelfState.shared.panel as? FloatingPanel<ClipboardShelfContentView>)?.verticallyResize(to: preferredHeight(for: self.height))
    needsResize = false
  }

  private func handleFirstKeyDown() {
    if isClosed() {
      open(height: height)
      state = .opening
      KeyboardShortcuts.disable(.popup)  // Handle events via eventsMonitor. Re-enable on popup close
      return
    }

    // Maccy was not opened via shortcut. We assume toggle mode and close it
    close()
  }

  private func handleEvent(_ event: NSEvent) -> NSEvent? {
    switch event.type {
    case .keyDown:
      return handleKeyDown(event)
    case .flagsChanged:
      return handleFlagsChanged(event)
    default:
      return event
    }
  }

  private func handleKeyDown(_ event: NSEvent) -> NSEvent? {
    if isHotKeyCode(Int(event.keyCode)) {
      if let item = History.shared.pressedShortcutItem {
        ClipboardShelfState.shared.navigator.select(item: item)
        Task { @MainActor in
          ClipboardShelfState.shared.history.select(item)
        }
        return nil
      }

      if state == .opening {
        state = .cycle
        // Next 'if' will highlight next item and then return nil
      }

      if state == .cycle {
        let navigator = ClipboardShelfState.shared.navigator
        // MenuShelf: the popup opens with nothing selected. Start from the
        // latest item so the first extra press still moves to the one before.
        if navigator.leadSelection == nil {
          let history = ClipboardShelfState.shared.history
          navigator.select(item: history.firstVisibleItem(where: \.isUnpinned) ?? history.firstVisibleItem)
        }
        navigator.highlightNext(allowCycle: true)
        return nil
      }

      if state == .toggle && isHotKeyModifiers(event.modifierFlags) {
        close()
        return nil
      }
    }

    return event
  }

  private func handleFlagsChanged(_ event: NSEvent) -> NSEvent? {
    // If we are in cycle mode, releasing modifiers triggers a selection
    if state == .cycle && allModifiersReleased(event) {
      DispatchQueue.main.async {
        ClipboardShelfState.shared.select()
      }
      return nil
    }

    // Otherwise if in opening mode, enter toggle mode
    if state == .opening && allModifiersReleased(event) {
      state = .toggle
      return event
    }

    return event
  }

  private func isHotKeyCode(_ keyCode: Int) -> Bool {
    guard let shortcut = KeyboardShortcuts.Name.popup.shortcut else {
      return false
    }

    return shortcut.key?.rawValue == keyCode
  }

  private func isHotKeyModifiers(_ modifiers: NSEvent.ModifierFlags) -> Bool {
    guard let shortcut = KeyboardShortcuts.Name.popup.shortcut else {
      return false
    }

    return modifiers.intersection(.deviceIndependentFlagsMask) ==
      shortcut.modifiers.intersection(.deviceIndependentFlagsMask)
  }

  private func allModifiersReleased(_ event: NSEvent) -> Bool {
    return event.modifierFlags.isDisjoint(with: .deviceIndependentFlagsMask)
  }
}
