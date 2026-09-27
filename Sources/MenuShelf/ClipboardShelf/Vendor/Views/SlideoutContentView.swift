import SwiftUI

struct SlideoutContentView: View {
  @Environment(ClipboardShelfState.self) var appState

  var body: some View {
    VStack {
      ToolbarView()

      if let item = appState.navigator.leadHistoryItem {
        // MenuShelf: a fresh view per item, so the image loader in
        // `AsyncView` reruns instead of keeping the previous image.
        PreviewItemView(item: item)
          .id(item.id)
      } else if let pasteStack = appState.history.pasteStack,
        appState.navigator.pasteStackSelected {
        PasteStackPreviewView(pasteStack: pasteStack)
      } else {
        EmptyView()
      }
    }
    .padding(.horizontal)
    .padding(.bottom)
    .padding(.top, Popup.verticalPadding)
  }

}
