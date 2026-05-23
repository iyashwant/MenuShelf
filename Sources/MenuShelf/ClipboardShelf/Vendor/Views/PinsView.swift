import SwiftUI

struct PinsView: View {
  @Environment(ClipboardShelfState.self) private var appState

  var items: [HistoryItemDecorator]

  var body: some View {
    MultipleSelectionListView(items: items) { previous, item, next, index in
      HistoryItemView(item: item, previous: previous, next: next, index: index)
    }
  }
}
