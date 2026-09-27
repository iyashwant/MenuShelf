import SwiftUI

/// MenuShelf: the All / Text / Images switch under the search field.
struct ContentFilterView: View {
  @Environment(ClipboardShelfState.self) private var appState

  var body: some View {
    HStack(spacing: 6) {
      ForEach(ClipboardContentFilter.allCases, id: \.self) { filter in
        let isSelected = appState.history.contentFilter == filter

        ToolbarButton {
          appState.history.contentFilter = filter
        } label: {
          HStack(spacing: 4) {
            if let symbolName = filter.symbolName {
              Image(systemName: symbolName)
                .font(.system(size: 10, weight: .medium))
            }
            Text(filter.title)
              .font(.system(size: 12, weight: isSelected ? .semibold : .regular))
          }
          .foregroundStyle(isSelected ? .primary : .secondary)
          .padding(.horizontal, 9)
          .frame(height: 20)
          .background(Capsule().fill(Color.primary.opacity(isSelected ? 0.16 : 0.06)))
          .contentShape(Capsule())
        }
        .help(filter.helpText)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
      }

      Spacer(minLength: 0)
    }
  }
}
