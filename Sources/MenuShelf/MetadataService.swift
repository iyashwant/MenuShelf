import AppKit
import AVFoundation
import Foundation
import ImageIO
import UniformTypeIdentifiers

final class MetadataService {
    private let byteFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter
    }()

    private let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()

    func icon(for url: URL, size: CGFloat = 18) -> NSImage {
        let image = NSWorkspace.shared.icon(forFile: url.path)
        image.size = NSSize(width: size, height: size)
        return image
    }

    func enrichedMetadata(for item: FileMenuItem) -> FileMetadata {
        var metadata = item.metadata

        if metadata.dimensions == nil {
            metadata.dimensions = dimensions(for: item.actionURL, type: item.kind)
        }

        if metadata.duration == nil, item.kind?.conforms(to: .movie) == true {
            metadata.duration = videoDuration(for: item.actionURL)
        }

        return metadata
    }

    func formattedSize(_ size: Int64?) -> String? {
        guard let size else { return nil }
        return byteFormatter.string(fromByteCount: size)
    }

    func formattedDate(_ date: Date?) -> String? {
        guard let date else { return nil }
        return dateFormatter.string(from: date)
    }

    func formattedDimensions(_ dimensions: CGSize?) -> String? {
        guard let dimensions else { return nil }
        return "\(Int(abs(dimensions.width)))x\(Int(abs(dimensions.height)))"
    }

    func formattedDuration(_ duration: TimeInterval?) -> String? {
        guard let duration, duration.isFinite else { return nil }
        let minutes = Int(duration) / 60
        let seconds = Int(duration) % 60
        return String(format: "%d:%02d", minutes, seconds)
    }

    func isTextFile(url: URL, type: UTType?) -> Bool {
        if type?.conforms(to: .text) == true { return true }
        let textExtensions = ["txt", "md", "markdown", "swift", "json", "xml", "yaml", "yml", "csv", "log", "rtf", "html", "css", "js", "ts", "tsx", "jsx"]
        return textExtensions.contains(url.pathExtension.lowercased())
    }

    func textPreview(for url: URL, maxBytes: Int = 4096) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }

        guard let data = try? handle.read(upToCount: maxBytes), !data.isEmpty else { return nil }
        let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .ascii)
        return text?.components(separatedBy: .newlines).prefix(12).joined(separator: "\n")
    }

    private func dimensions(for url: URL, type: UTType?) -> CGSize? {
        if type?.conforms(to: .image) == true {
            return imageDimensions(for: url)
        }

        if type?.conforms(to: .movie) == true || type?.conforms(to: .audiovisualContent) == true {
            return videoDimensions(for: url)
        }

        return nil
    }

    private func imageDimensions(for url: URL) -> CGSize? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? CGFloat,
              let height = properties[kCGImagePropertyPixelHeight] as? CGFloat else {
            return nil
        }

        return CGSize(width: width, height: height)
    }

    private func videoDimensions(for url: URL) -> CGSize? {
        let asset = AVURLAsset(url: url)
        guard let track = asset.tracks(withMediaType: .video).first else { return nil }
        let transformed = track.naturalSize.applying(track.preferredTransform)
        return CGSize(width: abs(transformed.width), height: abs(transformed.height))
    }

    private func videoDuration(for url: URL) -> TimeInterval? {
        let asset = AVURLAsset(url: url)
        let seconds = CMTimeGetSeconds(asset.duration)
        return seconds.isFinite ? seconds : nil
    }
}
