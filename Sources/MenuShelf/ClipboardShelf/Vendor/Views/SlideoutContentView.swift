import SwiftUI

// MenuShelf: the preview is a card sized to its content, attached to the side
// of the list, centred on the selected row and kept inside the popup.
struct SlideoutContentView: View {
  @Environment(ClipboardShelfState.self) var appState

  @State private var cardHeight: CGFloat = 0

  private var hasContent: Bool {
    appState.navigator.leadHistoryItem != nil
      || (appState.history.pasteStack != nil && appState.navigator.pasteStackSelected)
  }

  var body: some View {
    GeometryReader { geometry in
      if hasContent {
        let top = cardTop(in: geometry.frame(in: .global))

        card
          .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { cardHeight = $0 }
          .frame(width: geometry.size.width)
          .frame(maxHeight: geometry.size.height, alignment: .top)
          .offset(y: top)
          .onChange(of: top) { invalidateShadow() }
          .onChange(of: cardHeight) { invalidateShadow() }
      }
    }
  }

  private var card: some View {
    VStack(spacing: 0) {
      ToolbarView()

      if let item = appState.navigator.leadHistoryItem {
        // A fresh view per item, so the image loader in `AsyncView` reruns
        // instead of keeping the previous image.
        PreviewItemView(item: item)
          .id(item.id)
      } else if let pasteStack = appState.history.pasteStack,
        appState.navigator.pasteStackSelected {
        PasteStackPreviewView(pasteStack: pasteStack)
      }
    }
    .padding(.horizontal)
    .padding(.bottom)
    .padding(.top, Popup.verticalPadding)
    .glassEffect(.regular, in: cardShape)
  }

  // Square on the side that touches the list, so the two read as one piece.
  private var cardShape: UnevenRoundedRectangle {
    let radius = PanelGlass.cornerRadius
    let attachedOnLeading = appState.preview.placement == .right
    return UnevenRoundedRectangle(
      topLeadingRadius: attachedOnLeading ? 0 : radius,
      bottomLeadingRadius: attachedOnLeading ? 0 : radius,
      bottomTrailingRadius: attachedOnLeading ? radius : 0,
      topTrailingRadius: attachedOnLeading ? radius : 0
    )
  }

  // Centres the card on the selected row, then slides it down or up as far as
  // needed to keep it inside the popup.
  private func cardTop(in column: CGRect) -> CGFloat {
    let lowest = max(column.height - cardHeight, 0)
    guard let row = appState.preview.leadRowFrame else { return 0 }
    let centred = row.midY - column.minY - cardHeight / 2
    return min(max(centred, 0), lowest)
  }

  // The window's shadow follows its opaque shape, which changes as the card moves.
  private func invalidateShadow() {
    DispatchQueue.main.async {
      appState.panel?.invalidateShadow()
    }
  }
}
