import KeyboardShortcuts
import SwiftUI

struct PreviewItemView: View {
  var item: HistoryItemDecorator

  @ViewBuilder
  func previewImage(content: () -> some View) -> some View {
    content()
      .aspectRatio(contentMode: .fit)
      .clipShape(.rect(cornerRadius: 5))
  }

  private var previewText: some View {
    Text(item.text)
      .font(.body)
      .frame(maxWidth: .infinity, alignment: .leading)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      if item.hasImage {
        AsyncView<NSImage?, _, _> {
          return await item.asyncGetPreviewImage()
        } content: { image in
          if let image = image {
            FittedImageLayout(naturalSize: image.size) {
              previewImage {
                Image(nsImage: image)
                  .resizable()
              }
            }
          } else {
            previewImage {
              ZStack {
                Color.gray.opacity(0.3)
                  .frame(
                    idealWidth: HistoryItemDecorator.previewImageSize.width,
                    idealHeight: HistoryItemDecorator.previewImageSize.height
                  )
                Image(systemName: "photo.badge.exclamationmark")
                  .symbolRenderingMode(.multicolor)
                  .frame(alignment: .center)
              }
            }
          }
        } placeholder: {
          previewImage {
            ZStack {
              Color.gray.opacity(0.3)
                .frame(
                  idealWidth: HistoryItemDecorator.previewImageSize.width,
                  idealHeight: HistoryItemDecorator.previewImageSize.height
                )
              ProgressView()
                .frame(alignment: .center)
            }
          }
        }
      } else {
        // MenuShelf: short text sizes the card to fit; long text scrolls
        // inside the tallest card the popup allows.
        ViewThatFits(in: .vertical) {
          previewText
            .fixedSize(horizontal: false, vertical: true)
          ScrollView {
            previewText
          }
        }
      }

      Divider()
        .padding(.vertical)

      if let application = item.application {
        HStack(spacing: 3) {
          Text("Application", tableName: "PreviewItemView")
          AppImageView(
            appImage: item.applicationImage,
            size: NSSize(width: 11, height: 11)
          )
          Text(application)
        }
      }

      HStack(spacing: 3) {
        Text("FirstCopyTime", tableName: "PreviewItemView")
        Text(item.item.firstCopiedAt, style: .date)
        Text(item.item.firstCopiedAt, style: .time)
      }

      HStack(spacing: 3) {
        Text("LastCopyTime", tableName: "PreviewItemView")
        Text(item.item.lastCopiedAt, style: .date)
        Text(item.item.lastCopiedAt, style: .time)
      }

      HStack(spacing: 3) {
        Text("NumberOfCopies", tableName: "PreviewItemView")
        Text(String(item.item.numberOfCopies))
      }
    }
    .controlSize(.small)
  }
}

// MenuShelf: sizes an image to fit the space offered without stretching it
// past its own size, and reports that size rather than filling the space, so
// the preview card stays as small as its content.
private struct FittedImageLayout: Layout {
  let naturalSize: CGSize

  func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
    guard naturalSize.width > 0, naturalSize.height > 0 else { return .zero }
    let width = min(proposal.width ?? naturalSize.width, naturalSize.width)
    let height = min(proposal.height ?? naturalSize.height, naturalSize.height)
    let scale = min(width / naturalSize.width, height / naturalSize.height)
    return CGSize(width: naturalSize.width * scale, height: naturalSize.height * scale)
  }

  func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
    for subview in subviews {
      subview.place(at: bounds.origin, proposal: ProposedViewSize(bounds.size))
    }
  }
}
