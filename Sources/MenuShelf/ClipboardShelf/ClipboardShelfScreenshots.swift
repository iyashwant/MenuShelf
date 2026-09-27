//
//  ClipboardShelfScreenshots.swift
//  MenuShelf
//
//  Shows recent images from the screenshot folders in the Clipboard Shelf
//  popup, next to copied items. The folders are security-scoped bookmarks,
//  kept open while the feature is on. They're rescanned whenever the popup
//  opens or a folder changes, so new screenshots show up and old ones age out.
//  The images are never stored in the clipboard history.
//

import AppKit
import Foundation
import UniformTypeIdentifiers

@MainActor
final class ClipboardShelfScreenshots {
    static let shared = ClipboardShelfScreenshots()

    /// The most images shown, newest first, so a busy folder can't flood the list.
    static let maxItems = 100

    struct ImageFile: Equatable, Sendable {
        let url: URL
        let date: Date
    }

    private struct OpenFolder {
        let config: ClipboardShelfScreenshotFolder
        let url: URL
        let didStartAccessing: Bool
        let watcher: DispatchSourceFileSystemObject?
    }

    private var openFolders: [OpenFolder] = []
    private var maxAgeDays = ClipboardShelfSettings.defaultScreenshotMaxAgeDays
    private var decoratorsByKey: [String: HistoryItemDecorator] = [:]
    private var scanGeneration = 0
    private var pendingRefresh: Task<Void, Never>?

    private init() {}

    // MARK: - Lifecycle

    func configure(with settings: ClipboardShelfSettings) {
        let folders = settings.resolvedShowScreenshots ? settings.resolvedScreenshotFolders : []
        let days = settings.resolvedScreenshotMaxAgeDays
        guard folders != openFolders.map(\.config) || days != maxAgeDays else { return }

        maxAgeDays = days
        if folders != openFolders.map(\.config) {
            closeFolders()
            openFolders = folders.compactMap(openFolder)
        }
        refresh()
    }

    func stop() {
        closeFolders()
        decoratorsByKey = [:]
        History.shared.setScreenshotItems([])
    }

    /// Rescans the folders off the main thread and updates the popup's list.
    func refresh() {
        guard !openFolders.isEmpty else {
            if !History.shared.screenshotItems.isEmpty {
                decoratorsByKey = [:]
                History.shared.setScreenshotItems([])
            }
            return
        }

        scanGeneration += 1
        let generation = scanGeneration
        let folders = openFolders.map(\.url)
        let cutoff = Date().addingTimeInterval(-Double(maxAgeDays) * 86_400)
        let limit = Self.maxItems
        Task {
            let files = await Task.detached(priority: .userInitiated) {
                Self.recentImages(in: folders, since: cutoff, limit: limit)
            }.value
            guard generation == scanGeneration else { return }
            publish(files)
        }
    }

    // MARK: - Scanning

    /// Images directly inside `folders` saved on or after `cutoff`, newest first.
    nonisolated static func recentImages(in folders: [URL], since cutoff: Date, limit: Int) -> [ImageFile] {
        let keys: [URLResourceKey] = [.isRegularFileKey, .contentTypeKey, .creationDateKey, .contentModificationDateKey]
        var seen = Set<String>()
        var files: [ImageFile] = []
        for folder in folders {
            guard let urls = try? FileManager.default.contentsOfDirectory(
                at: folder,
                includingPropertiesForKeys: keys,
                options: [.skipsHiddenFiles]
            ) else { continue }

            for url in urls {
                guard let values = try? url.resourceValues(forKeys: Set(keys)),
                      values.isRegularFile == true,
                      values.contentType?.conforms(to: .image) == true,
                      let date = values.creationDate ?? values.contentModificationDate,
                      date >= cutoff,
                      seen.insert(url.standardizedFileURL.path).inserted else { continue }
                files.append(ImageFile(url: url, date: date))
            }
        }
        return Array(files.sorted { $0.date > $1.date }.prefix(limit))
    }

    private func publish(_ files: [ImageFile]) {
        // Reuse decorators for unchanged files so their thumbnails stay cached.
        var kept: [String: HistoryItemDecorator] = [:]
        let decorators = files.map { file in
            let key = "\(file.url.path)|\(file.date.timeIntervalSinceReferenceDate)"
            let decorator = decoratorsByKey[key] ?? HistoryItemDecorator(Self.makeItem(for: file))
            kept[key] = decorator
            return decorator
        }
        decoratorsByKey = kept

        guard decorators.map(\.id) != History.shared.screenshotItems.map(\.id) else { return }
        History.shared.setScreenshotItems(decorators)
    }

    private static func makeItem(for file: ImageFile) -> HistoryItem {
        let item = HistoryItem(contents: [
            HistoryItemContent(type: NSPasteboard.PasteboardType.fileURL.rawValue, value: file.url.dataRepresentation),
            HistoryItemContent(type: NSPasteboard.PasteboardType.menuShelfScreenshot.rawValue)
        ])
        item.firstCopiedAt = file.date
        item.lastCopiedAt = file.date
        item.title = item.generateTitle()
        return item
    }

    // MARK: - Copying

    /// What copying a screenshot puts on the pasteboard: its image as PNG,
    /// marked transient so Clipboard Shelf doesn't record it a second time.
    static func pasteboardItem(for screenshot: HistoryItem) -> HistoryItem? {
        guard let url = screenshot.fileURLs.first,
              let data = try? Data(contentsOf: url),
              let png = pngData(from: data, url: url) else { return nil }

        let item = HistoryItem(contents: [
            HistoryItemContent(type: NSPasteboard.PasteboardType.png.rawValue, value: png),
            HistoryItemContent(type: NSPasteboard.PasteboardType.transient.rawValue, value: Data())
        ])
        item.title = screenshot.title
        return item
    }

    private static func pngData(from data: Data, url: URL) -> Data? {
        if UTType(filenameExtension: url.pathExtension)?.conforms(to: .png) == true {
            return data
        }
        return NSBitmapImageRep(data: data)?.representation(using: .png, properties: [:])
    }

    // MARK: - Folders

    /// Where macOS saves screenshots: the Screenshot app's "Save to" folder,
    /// or the Desktop when that was never changed.
    static func systemScreenshotFolder() -> URL {
        let location = CFPreferencesCopyAppValue("location" as CFString, "com.apple.screencapture" as CFString) as? String
        return screenshotFolder(fromLocation: location, home: realHomeDirectory)
    }

    nonisolated static func screenshotFolder(fromLocation location: String?, home: URL) -> URL {
        guard let location = location?.trimmingCharacters(in: .whitespacesAndNewlines), !location.isEmpty else {
            return home.appendingPathComponent("Desktop", isDirectory: true)
        }
        if location == "~" {
            return home
        }
        if location.hasPrefix("~/") {
            return home.appendingPathComponent(String(location.dropFirst(2)), isDirectory: true)
        }
        return URL(fileURLWithPath: location, isDirectory: true)
    }

    /// The user's home folder. Inside the sandbox, `NSHomeDirectory()` is the
    /// app's container instead.
    static var realHomeDirectory: URL {
        if let directory = getpwuid(getuid())?.pointee.pw_dir {
            return URL(fileURLWithPath: String(cString: directory), isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
    }

    /// Access to `folder` as a bookmark. A folder MenuShelf already has as a
    /// source is reused; otherwise the user is asked to choose it. Returns nil
    /// when they cancel.
    static func requestAccess(to folder: URL?, reusing sources: [FolderConfig]) -> ClipboardShelfScreenshotFolder? {
        if let folder, let existing = bookmark(for: folder, among: sources) {
            return ClipboardShelfScreenshotFolder(id: UUID(), bookmarkData: existing, path: folder.path)
        }

        let panel = NSOpenPanel()
        panel.title = "Show Screenshots in Clipboard Shelf"
        panel.message = folder == nil
            ? "Choose a folder. Its recent images will show in Clipboard Shelf."
            : "Allow MenuShelf to read this folder so its recent screenshots show in Clipboard Shelf."
        panel.prompt = folder == nil ? "Add Folder" : "Allow"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.directoryURL = folder

        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url,
              let data = try? url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
        else { return nil }
        return ClipboardShelfScreenshotFolder(id: UUID(), bookmarkData: data, path: url.path)
    }

    private static func bookmark(for folder: URL, among sources: [FolderConfig]) -> Data? {
        let wanted = folder.resolvingSymlinksInPath().standardizedFileURL.path
        for source in sources {
            var isStale = false
            guard let url = try? URL(
                resolvingBookmarkData: source.bookmarkData,
                options: [.withSecurityScope, .withoutUI],
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            ), !isStale else { continue }
            if url.resolvingSymlinksInPath().standardizedFileURL.path == wanted {
                return source.bookmarkData
            }
        }
        return nil
    }

    private func openFolder(_ config: ClipboardShelfScreenshotFolder) -> OpenFolder? {
        var isStale = false
        guard let url = try? URL(
            resolvingBookmarkData: config.bookmarkData,
            options: [.withSecurityScope, .withoutUI],
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        ) else {
            DiagnosticsLogger.shared.log("Clipboard Shelf screenshots: could not resolve folder id=\(config.id.uuidString)")
            return nil
        }
        let didStart = url.startAccessingSecurityScopedResource()
        return OpenFolder(config: config, url: url, didStartAccessing: didStart, watcher: makeWatcher(for: url))
    }

    private func closeFolders() {
        pendingRefresh?.cancel()
        for folder in openFolders {
            folder.watcher?.cancel()
            if folder.didStartAccessing {
                folder.url.stopAccessingSecurityScopedResource()
            }
        }
        openFolders = []
    }

    /// Rescans shortly after the folder changes, so a new screenshot is in
    /// the list before the popup opens.
    private func makeWatcher(for url: URL) -> DispatchSourceFileSystemObject? {
        let descriptor = open(url.path, O_EVTONLY)
        guard descriptor >= 0 else { return nil }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor, eventMask: .write, queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                self?.scheduleRefresh()
            }
        }
        source.setCancelHandler {
            close(descriptor)
        }
        source.resume()
        return source
    }

    private func scheduleRefresh() {
        pendingRefresh?.cancel()
        pendingRefresh = Task { [weak self] in
            // Screenshots are written in steps; wait for the file to settle.
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            self?.refresh()
        }
    }
}
