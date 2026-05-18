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

    // NSWorkspace.icon(forFile:) returns a shared instance whose size we previously
    // mutated in place, which polluted other callers. Cache copies keyed by (path, size)
    // so a 1000-item folder costs ~1000 lookups on first open and ~0 thereafter.
    //
    // The limit is generous because folder sources can include repos with thousands
    // of entries (Xcode builds, node_modules, etc.). Each entry is a small NSImage,
    // so 4096 cached at a few KB each is well under a megabyte.
    private let iconCache: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 4096
        return cache
    }()

    func icon(for url: URL, size: CGFloat = 18) -> NSImage {
        let key = "\(url.path)|\(Int(size))" as NSString
        if let cached = iconCache.object(forKey: key) {
            return cached
        }

        let workspaceIcon = NSWorkspace.shared.icon(forFile: url.path)
        let image = (workspaceIcon.copy() as? NSImage) ?? workspaceIcon
        image.size = NSSize(width: size, height: size)
        iconCache.setObject(image, forKey: key)
        return image
    }

    /// Drop a path from the icon cache (e.g. when a file is renamed or trashed).
    func invalidateIcon(for url: URL) {
        for size in [16, 18, 22, 24, 32, 48, 64] {
            iconCache.removeObject(forKey: "\(url.path)|\(size)" as NSString)
        }
    }

    func enrichedMetadata(for item: FileMenuItem) -> FileMetadata {
        var metadata = item.metadata

        if metadata.dimensions == nil, item.kind?.conforms(to: .image) == true {
            metadata.dimensions = imageDimensions(for: item.actionURL)
        }

        // Video dimensions and duration require async AVFoundation APIs on
        // macOS 13+. They're fetched lazily by callers that can `await`,
        // never on the main thread during menu construction.

        return metadata
    }

    /// Async metadata enrichment for video assets. Safe to call from any
    /// context. Returns the unchanged metadata if the URL is not a movie.
    func enrichedMetadataAsync(for item: FileMenuItem) async -> FileMetadata {
        var metadata = enrichedMetadata(for: item)

        guard item.kind?.conforms(to: .movie) == true || item.kind?.conforms(to: .audiovisualContent) == true else {
            return metadata
        }

        let asset = AVURLAsset(url: item.actionURL)

        if metadata.dimensions == nil {
            metadata.dimensions = await loadVideoDimensions(asset: asset)
        }
        if metadata.duration == nil {
            metadata.duration = await loadVideoDuration(asset: asset)
        }

        return metadata
    }

    private func loadVideoDimensions(asset: AVURLAsset) async -> CGSize? {
        do {
            let tracks = try await asset.loadTracks(withMediaType: .video)
            guard let track = tracks.first else { return nil }
            let (size, transform) = try await track.load(.naturalSize, .preferredTransform)
            let transformed = size.applying(transform)
            return CGSize(width: abs(transformed.width), height: abs(transformed.height))
        } catch {
            return nil
        }
    }

    private func loadVideoDuration(asset: AVURLAsset) async -> TimeInterval? {
        do {
            let duration = try await asset.load(.duration)
            let seconds = CMTimeGetSeconds(duration)
            return seconds.isFinite ? seconds : nil
        } catch {
            return nil
        }
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

    private func imageDimensions(for url: URL) -> CGSize? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? CGFloat,
              let height = properties[kCGImagePropertyPixelHeight] as? CGFloat else {
            return nil
        }

        return CGSize(width: width, height: height)
    }
}
