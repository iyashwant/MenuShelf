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

      // MenuShelf: readable labels (the vendored string table isn't bundled,
      // so the raw keys showed), one "Copied at" line for a single copy, and
      // the source app shown by its icon and name alone.
      if let application = item.application {
        HStack(spacing: 3) {
          AppImageView(
            appImage: item.applicationImage,
            size: NSSize(width: 11, height: 11)
          )
          Text(application)
        }
        .lineLimit(1)
      }

      if item.item.isScreenshot {
        // A screenshot shows the folder it's in and when it was saved.
        if let folder = item.item.fileURLs.first?.deletingLastPathComponent() {
          HStack(spacing: 3) {
            Image(systemName: "folder")
              .font(.system(size: 10))
            Text(folder.lastPathComponent)
          }
          .lineLimit(1)
        }
        detailRow("Saved at", ClipboardShelfCopyTime.string(for: item.item.lastCopiedAt))
      } else if item.item.numberOfCopies > 1 {
        detailRow("First copied at", ClipboardShelfCopyTime.string(for: item.item.firstCopiedAt))
        detailRow("Last copied at", ClipboardShelfCopyTime.string(for: item.item.lastCopiedAt))
        detailRow("Copies", String(item.item.numberOfCopies))
      } else {
        detailRow("Copied at", ClipboardShelfCopyTime.string(for: item.item.lastCopiedAt))
      }
    }
    .controlSize(.small)
  }

  private func detailLabel(_ label: String) -> some View {
    Text(label)
      .foregroundStyle(.secondary)
  }

  private func detailRow(_ label: String, _ value: String) -> some View {
    HStack(spacing: 3) {
      detailLabel(label)
      Text(value)
    }
    .lineLimit(1)
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
