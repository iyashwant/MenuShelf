import Defaults
import SwiftUI

struct HistoryItemView: View {
  @Bindable var item: HistoryItemDecorator
  var previous: HistoryItemDecorator?
  var next: HistoryItemDecorator?
  var index: Int

  private var visualIndex: Int? {
    if appState.navigator.isMultiSelectInProgress && item.selectionIndex >= 0 {
      return item.selectionIndex
    }
    return nil
  }

  private var selectionAppearance: SelectionAppearance {
    let previousSelected = previous?.isSelected ?? false
    let nextSelected = next?.isSelected ?? false
    switch (previousSelected, nextSelected) {
    case (true, false):
      return .topConnection
    case (false, true):
      return .bottomConnection
    case (true, true):
      return .topBottomConnection
    default:
      return .none
    }
  }

  @Environment(ClipboardShelfState.self) private var appState

  @State private var rowFrame: CGRect?

  // MenuShelf: tells the preview card where the selected row is.
  private func reportFrameIfSelected() {
    guard item.isSelected, let rowFrame else { return }
    appState.preview.leadRowFrame = rowFrame
  }

  var body: some View {
    ListItemView(
      id: item.id,
      selectionId: item.id,
      appIcon: item.applicationImage,
      image: item.thumbnailImage,
      accessoryImage: item.thumbnailImage != nil ? nil : ColorImage.from(item.title),
      attributedTitle: item.attributedTitle,
      shortcuts: item.shortcuts,
      isSelected: item.isSelected,
      selectionIndex: visualIndex,
      selectionAppearance: selectionAppearance
    ) {
      Text(verbatim: item.title)
    }
    .onAppear {
      item.ensureThumbnailImage()
    }
    .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame in
      rowFrame = frame
      reportFrameIfSelected()
    }
    .onChange(of: item.isSelected, initial: true) {
      reportFrameIfSelected()
    }
    .onTapGesture {
      if NSEvent.modifierFlags.contains(.command) && appState.multiSelectionEnabled {
        appState.navigator.addToSelection(item: item)
      } else {
        Task {
          appState.history.select(item)
        }
      }
    }
  }
}
