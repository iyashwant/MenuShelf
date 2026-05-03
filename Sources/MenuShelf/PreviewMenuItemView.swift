import AppKit
import QuickLookThumbnailing

final class PreviewMenuItemView: NSView, NSDraggingSource {
    private let imageView = NSImageView()
    private let textField = NSTextField(labelWithString: "")
    private let itemURL: URL
    private var lastMouseDownEvent: NSEvent?

    init(item: FileMenuItem, metadataService: MetadataService) {
        itemURL = item.actionURL
        let width: CGFloat = 280
        let height: CGFloat = metadataService.isTextFile(url: item.actionURL, type: item.kind) ? 156 : 190
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: height))

        wantsLayer = true
        layer?.cornerRadius = 8
        toolTip = "Drag to move. Option-drag to copy."

        if metadataService.isTextFile(url: item.actionURL, type: item.kind),
           let preview = metadataService.textPreview(for: item.actionURL) {
            configureTextPreview(preview)
        } else {
            configureImagePreview(item: item, metadataService: metadataService)
        }
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func mouseDown(with event: NSEvent) {
        lastMouseDownEvent = event
    }

    override func mouseDragged(with event: NSEvent) {
        let draggingItem = NSDraggingItem(pasteboardWriter: itemURL as NSURL)
        let dragImage = imageView.image ?? NSWorkspace.shared.icon(forFile: itemURL.path)
        draggingItem.setDraggingFrame(bounds.insetBy(dx: 20, dy: 20), contents: dragImage)
        beginDraggingSession(with: [draggingItem], event: lastMouseDownEvent ?? event, source: self)
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        NSEvent.modifierFlags.contains(.option) ? .copy : .move
    }

    private func configureTextPreview(_ preview: String) {
        textField.frame = NSRect(x: 12, y: 10, width: bounds.width - 24, height: bounds.height - 20)
        textField.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        textField.lineBreakMode = .byTruncatingTail
        textField.maximumNumberOfLines = 12
        textField.stringValue = preview
        addSubview(textField)
    }

    private func configureImagePreview(item: FileMenuItem, metadataService: MetadataService) {
        imageView.frame = NSRect(x: 12, y: 34, width: bounds.width - 24, height: bounds.height - 46)
        imageView.imageAlignment = .alignCenter
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.image = metadataService.icon(for: item.actionURL, size: 96)
        addSubview(imageView)

        let title = NSTextField(labelWithString: item.displayName)
        title.frame = NSRect(x: 12, y: 8, width: bounds.width - 24, height: 18)
        title.font = .systemFont(ofSize: 11, weight: .medium)
        title.lineBreakMode = .byTruncatingMiddle
        addSubview(title)

        let request = QLThumbnailGenerator.Request(
            fileAt: item.actionURL,
            size: CGSize(width: 240, height: 140),
            scale: NSScreen.main?.backingScaleFactor ?? 2,
            representationTypes: .all
        )

        QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { [weak imageView] representation, _ in
            guard let image = representation?.nsImage else { return }
            DispatchQueue.main.async {
                imageView?.image = image
            }
        }
    }
}
