import AppKit
import Foundation
import UniformTypeIdentifiers

enum FileAccessError: LocalizedError {
    case missingFolder(String)
    case staleBookmark(String)
    case unreadableFolder(String)

    var errorDescription: String? {
        switch self {
        case .missingFolder(let path): "Folder missing: \(path)"
        case .staleBookmark(let path): "Permission needs to be refreshed for: \(path)"
        case .unreadableFolder(let path): "Folder could not be read: \(path)"
        }
    }
}

final class SecurityScopedURL {
    let url: URL
    private let didStartAccessing: Bool

    init(url: URL, didStartAccessing: Bool) {
        self.url = url
        self.didStartAccessing = didStartAccessing
    }

    deinit {
        if didStartAccessing {
            url.stopAccessingSecurityScopedResource()
        }
    }
}

final class FileAccessService {
    // MARK: - AppleScript File Bookmark Helpers

    /// Creates a security-scoped bookmark for an AppleScript file (.scpt or .applescript).
    /// This bookmark can be stored and later resolved to re-gain access to the file.
    static func createAppleScriptBookmark(for url: URL) throws -> Data {
        let access = url.startAccessingSecurityScopedResource()
        defer {
            if access {
                url.stopAccessingSecurityScopedResource()
            }
        }

        let bookmarkData = try url.bookmarkData(
            options: .withSecurityScope,
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
        return bookmarkData
    }

    /// Resolves a security-scoped bookmark and returns the URL if still valid.
    /// Returns nil if the bookmark is stale or invalid.
    static func resolveAppleScriptBookmark(_ bookmark: Data) -> (url: URL, isStale: Bool)? {
        var isStale = false
        guard let url = try? URL(
            resolvingBookmarkData: bookmark,
            options: .withSecurityScope,
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        ) else {
            return nil
        }
        return (url, isStale)
    }

    private let fileManager = FileManager.default

    // Cache of resolved security-scoped URLs keyed by FolderConfig.id.
    // Bookmark resolution is non-trivial; without this, every menu render
    // re-resolves the same bookmarks. The bookmarkData hash invalidates the
    // entry if the user re-grants access via reselectFolder.
    private struct ResolvedBookmark {
        let bookmarkHash: Int
        let url: URL
    }
    private var resolvedCache: [UUID: ResolvedBookmark] = [:]
    private let resolvedCacheLock = NSLock()

    // Short-TTL cache of `directoryListing` results. AppKit calls
    // NSMenuDelegate.menuNeedsUpdate every time a menu opens (or a submenu
    // reopens), and a casual browse can re-stat the same 1000-item folder
    // many times per second. The TTL plus an mtime check keeps the cache
    // honest: we serve stale data for at most `listingCacheTTL`, and any
    // change to the directory's contents (add/remove/rename of an entry)
    // bumps the dir's mtime so we recompute even within the TTL window.
    //
    // ListingCacheKey covers every input the listing depends on. Adding
    // a new MenuSettings field that affects the listing output requires
    // adding it here.
    private struct ListingCacheKey: Hashable {
        let path: String
        let visitedHash: Int
        let sortKey: SortKey
        let sortDirection: SortDirection
        let keepFoldersOnTop: Bool
        let keepAppsOnTop: Bool
        let showHiddenFiles: Bool
        let showFileExtensions: Bool
        let followAliases: Bool
        let followSymlinks: Bool
        let filterMode: FilterMode
        let maxItems: Int?
        let ignoredNames: [String]
    }

    private struct ListingCacheEntry {
        let listing: DirectoryListing
        let timestamp: Date
        let dirMtime: Date?
    }

    private var listingCache: [ListingCacheKey: ListingCacheEntry] = [:]
    private let listingCacheLock = NSLock()
    private let listingCacheTTL: TimeInterval = 2.0
    private let listingCacheLimit = 32

    func accessItem(_ config: FolderConfig) throws -> SecurityScopedURL {
        let bookmarkHash = config.bookmarkData.hashValue

        resolvedCacheLock.lock()
        let cached = resolvedCache[config.id]
        resolvedCacheLock.unlock()

        if let cached, cached.bookmarkHash == bookmarkHash,
           fileManager.fileExists(atPath: cached.url.path) {
            let didStart = cached.url.startAccessingSecurityScopedResource()
            return SecurityScopedURL(url: cached.url, didStartAccessing: didStart)
        }

        var isStale = false
        let url = try URL(
            resolvingBookmarkData: config.bookmarkData,
            options: [.withSecurityScope, .withoutUI],
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        )

        if isStale {
            resolvedCacheLock.lock()
            resolvedCache.removeValue(forKey: config.id)
            resolvedCacheLock.unlock()
            throw FileAccessError.staleBookmark(config.originalPathHint)
        }

        guard fileManager.fileExists(atPath: url.path) else {
            resolvedCacheLock.lock()
            resolvedCache.removeValue(forKey: config.id)
            resolvedCacheLock.unlock()
            throw FileAccessError.missingFolder(config.originalPathHint)
        }

        resolvedCacheLock.lock()
        resolvedCache[config.id] = ResolvedBookmark(bookmarkHash: bookmarkHash, url: url)
        resolvedCacheLock.unlock()

        let didStart = url.startAccessingSecurityScopedResource()
        return SecurityScopedURL(url: url, didStartAccessing: didStart)
    }

    func invalidateCache(for configID: UUID) {
        resolvedCacheLock.lock()
        resolvedCache.removeValue(forKey: configID)
        resolvedCacheLock.unlock()
    }

    func accessFolder(_ config: FolderConfig) throws -> SecurityScopedURL {
        let access = try accessItem(config)
        let url = access.url

        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw FileAccessError.missingFolder(config.originalPathHint)
        }

        return access
    }

    func directoryListing(in folderURL: URL, config: FolderConfig, visited: Set<String>) throws -> DirectoryListing {
        let settings = config.menuSettings

        // Build a cache key that captures everything the listing depends on.
        let cacheKey = ListingCacheKey(
            path: folderURL.standardizedFileURL.path,
            visitedHash: visited.hashValue,
            sortKey: settings.sortKey,
            sortDirection: settings.sortDirection,
            keepFoldersOnTop: settings.keepFoldersOnTop,
            keepAppsOnTop: settings.keepAppsOnTop,
            showHiddenFiles: settings.showHiddenFiles,
            showFileExtensions: settings.showFileExtensions,
            followAliases: settings.followAliases,
            followSymlinks: settings.followSymlinks,
            filterMode: settings.filterMode,
            maxItems: settings.maxItems,
            ignoredNames: settings.ignoredNames
        )

        // Cache hit path: serve if the entry is still within TTL and the
        // directory's mtime hasn't moved since we cached it. Looking up
        // mtime is one stat call; cheap compared to re-enumerating.
        listingCacheLock.lock()
        let cachedEntry = listingCache[cacheKey]
        listingCacheLock.unlock()

        if let cachedEntry,
           Date().timeIntervalSince(cachedEntry.timestamp) < listingCacheTTL {
            let currentMtime = (try? fileManager.attributesOfItem(atPath: cacheKey.path)[.modificationDate]) as? Date
            if currentMtime == cachedEntry.dirMtime {
                return cachedEntry.listing
            }
        }

        var options: FileManager.DirectoryEnumerationOptions = []
        if !settings.showHiddenFiles {
            options.insert(.skipsHiddenFiles)
        }

        // Cheap first pass: only ask for the name. We may be enumerating tens of
        // thousands of entries (e.g. ~/Downloads); fetching resource values for all
        // of them just to throw most away is the dominant cost when maxItems is small.
        let nameKeys: [URLResourceKey] = [.nameKey]
        let lightweightURLs = try fileManager.contentsOfDirectory(
            at: folderURL,
            includingPropertiesForKeys: nameKeys,
            options: options
        )

        // Pre-filter by name-only rules so the totalCount we report (and the prefix we
        // resource-load) reflects what the user will actually see.
        let nameFiltered = lightweightURLs.filter { url in
            let lastComponent = url.lastPathComponent
            if settings.ignoredNames.contains(lastComponent) { return false }
            if !settings.showHiddenFiles, lastComponent.hasPrefix(".") { return false }
            return true
        }

        // For sort-by-name we can sort cheaply now and only resource-load the prefix
        // we plan to display. For other sort keys we have no choice but to load
        // everything; we still avoid fetching resource values for ignored entries.
        let needsFullResourceLoad: Bool
        switch settings.sortKey {
        case .name:
            needsFullResourceLoad = false
        case .dateCreated, .dateModified, .dateLastOpened, .dateAdded, .kind, .size:
            needsFullResourceLoad = true
        }

        let cap = settings.maxItems.flatMap { $0 > 0 ? $0 : nil } ?? Int.max
        let candidateURLs: [URL]
        if needsFullResourceLoad {
            candidateURLs = nameFiltered
        } else {
            // Stable name sort with a cheap enough comparator; final sort below applies
            // category ranks and direction, but the prefix we load is correct.
            let sortedByName = nameFiltered.sorted {
                $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending
            }
            // Apply direction by reversing if needed so the top of the prefix matches
            // the eventual visible window.
            candidateURLs = settings.sortDirection == .ascending ? sortedByName : Array(sortedByName.reversed())
        }

        // Reserve some headroom over maxItems because filterMode may drop entries
        // and we still want to fill the menu.
        let prefixCap = needsFullResourceLoad ? candidateURLs.count : min(candidateURLs.count, cap * 2 + 32)
        let toLoad = Array(candidateURLs.prefix(prefixCap))

        let items = toLoad.compactMap { url -> FileMenuItem? in
            guard let item = makeItem(url: url, config: config, visited: visited) else { return nil }
            guard include(item: item, settings: settings) else { return nil }
            return item
        }

        let sorted = sort(items: items, settings: settings)
        let totalCount = nameFiltered.count
        let limited: [FileMenuItem]
        let omittedCount: Int

        if cap < Int.max, sorted.count > cap {
            limited = Array(sorted.prefix(cap))
            omittedCount = max(0, totalCount - cap)
        } else {
            limited = sorted
            omittedCount = max(0, totalCount - sorted.count)
        }

        let listing = DirectoryListing(items: limited, omittedCount: omittedCount, totalCount: totalCount)

        // Capture mtime *after* the listing is computed. If anything changed
        // mid-enumeration, the next call will see a different mtime and recompute.
        let dirMtime = (try? fileManager.attributesOfItem(atPath: cacheKey.path)[.modificationDate]) as? Date

        let entry = ListingCacheEntry(listing: listing, timestamp: Date(), dirMtime: dirMtime)
        listingCacheLock.lock()
        if listingCache.count >= listingCacheLimit, listingCache[cacheKey] == nil {
            // Simple LRU-by-timestamp: evict the oldest entry. Limit is small (32),
            // so a linear scan is fine and avoids pulling in a heap.
            if let oldestKey = listingCache.min(by: { $0.value.timestamp < $1.value.timestamp })?.key {
                listingCache.removeValue(forKey: oldestKey)
            }
        }
        listingCache[cacheKey] = entry
        listingCacheLock.unlock()

        return listing
    }

    private func makeItem(url: URL, config: FolderConfig, visited: Set<String>) -> FileMenuItem? {
        let settings = config.menuSettings
        let originalValues = try? url.resourceValues(forKeys: [
            .isDirectoryKey,
            .isPackageKey,
            .isAliasFileKey,
            .isSymbolicLinkKey,
            .localizedTypeDescriptionKey,
            .contentTypeKey,
            .fileSizeKey,
            .creationDateKey,
            .contentModificationDateKey,
            .contentAccessDateKey,
            .addedToDirectoryDateKey
        ])

        let isAlias = originalValues?.isAliasFile == true
        let isSymlink = originalValues?.isSymbolicLink == true
        var resolvedURL: URL?
        var aliasIsBroken = false

        if isAlias, settings.followAliases {
            do {
                resolvedURL = try URL(resolvingAliasFileAt: url, options: [.withoutUI])
            } catch {
                aliasIsBroken = true
            }
        }

        if isSymlink, settings.followSymlinks {
            do {
                let destination = try fileManager.destinationOfSymbolicLink(atPath: url.path)
                if destination.hasPrefix("/") {
                    resolvedURL = URL(fileURLWithPath: destination).standardizedFileURL
                } else {
                    resolvedURL = url.deletingLastPathComponent().appendingPathComponent(destination).standardizedFileURL
                }
            } catch {
                resolvedURL = nil
            }
        }

        let targetURL = resolvedURL ?? url
        let targetValues = try? targetURL.resourceValues(forKeys: [
            .isDirectoryKey,
            .isPackageKey,
            .localizedTypeDescriptionKey,
            .contentTypeKey,
            .fileSizeKey,
            .creationDateKey,
            .contentModificationDateKey,
            .contentAccessDateKey,
            .addedToDirectoryDateKey
        ])

        var isDirectory = targetValues?.isDirectory == true
        var isPackage = targetValues?.isPackage == true
        let isApplication = targetURL.pathExtension.lowercased() == "app"

        if isApplication {
            isDirectory = false
            isPackage = true
        }

        var hasSymlinkLoop = false
        if isDirectory, visited.contains(targetURL.standardizedFileURL.path) {
            // Don't recurse into a target we've already visited; mark the entry
            // so MenuBuilder can present a clear "loop" indicator instead of a
            // silently-clickable leaf.
            isDirectory = false
            hasSymlinkLoop = true
        }

        let kind = targetValues?.contentType ?? UTType(filenameExtension: targetURL.pathExtension)
        var displayName = FileManager.default.displayName(atPath: url.path)
        if !settings.showFileExtensions, !isDirectory, !isApplication {
            displayName = (displayName as NSString).deletingPathExtension
        }

        let metadata = FileMetadata(
            kindDescription: targetValues?.localizedTypeDescription ?? kind?.localizedDescription ?? fallbackKind(isDirectory: isDirectory, isApplication: isApplication),
            size: targetValues?.fileSize.map(Int64.init),
            createdAt: targetValues?.creationDate,
            modifiedAt: targetValues?.contentModificationDate,
            lastOpenedAt: targetValues?.contentAccessDate,
            addedAt: targetValues?.addedToDirectoryDate,
            dimensions: nil,
            duration: nil
        )

        return FileMenuItem(
            url: url,
            resolvedURL: resolvedURL,
            displayName: displayName,
            kind: kind,
            isDirectory: isDirectory,
            isPackage: isPackage,
            isApplication: isApplication,
            isAlias: isAlias,
            isSymlink: isSymlink,
            aliasIsBroken: aliasIsBroken,
            hasSymlinkLoop: hasSymlinkLoop,
            metadata: metadata
        )
    }

    private func include(item: FileMenuItem, settings: MenuSettings) -> Bool {
        switch settings.filterMode {
        case .all:
            return true
        case .appsOnly:
            return item.isApplication
        case .foldersOnly:
            return item.isDirectory
        case .documentsOnly:
            return !item.isDirectory && !item.isApplication
        case .imagesOnly:
            return item.kind?.conforms(to: .image) == true
        }
    }

    private func sort(items: [FileMenuItem], settings: MenuSettings) -> [FileMenuItem] {
        items.sorted { first, second in
            let firstRank = categoryRank(first, settings: settings)
            let secondRank = categoryRank(second, settings: settings)
            if firstRank != secondRank {
                return firstRank < secondRank
            }

            let comparison: ComparisonResult
            switch settings.sortKey {
            case .name:
                comparison = first.displayName.localizedStandardCompare(second.displayName)
            case .dateCreated:
                comparison = compare(first.metadata.createdAt, second.metadata.createdAt)
            case .dateModified:
                comparison = compare(first.metadata.modifiedAt, second.metadata.modifiedAt)
            case .dateLastOpened:
                comparison = compare(first.metadata.lastOpenedAt, second.metadata.lastOpenedAt)
            case .dateAdded:
                comparison = compare(first.metadata.addedAt, second.metadata.addedAt)
            case .kind:
                comparison = first.metadata.kindDescription.localizedStandardCompare(second.metadata.kindDescription)
            case .size:
                comparison = compare(first.metadata.size, second.metadata.size)
            }

            if comparison == .orderedSame {
                return first.displayName.localizedStandardCompare(second.displayName) == .orderedAscending
            }

            return settings.sortDirection == .ascending ? comparison == .orderedAscending : comparison == .orderedDescending
        }
    }

    private func categoryRank(_ item: FileMenuItem, settings: MenuSettings) -> Int {
        if settings.keepFoldersOnTop, item.isDirectory { return 0 }
        if settings.keepAppsOnTop, item.isApplication { return 1 }
        return 2
    }

    private func compare(_ first: Date?, _ second: Date?) -> ComparisonResult {
        switch (first, second) {
        case let (first?, second?):
            return first.compare(second)
        case (nil, nil):
            return .orderedSame
        case (nil, _):
            return .orderedDescending
        case (_, nil):
            return .orderedAscending
        }
    }

    private func compare(_ first: Int64?, _ second: Int64?) -> ComparisonResult {
        switch (first, second) {
        case let (first?, second?) where first < second: return .orderedAscending
        case let (first?, second?) where first > second: return .orderedDescending
        case (_?, _?): return .orderedSame
        case (nil, nil): return .orderedSame
        case (nil, _): return .orderedDescending
        case (_, nil): return .orderedAscending
        }
    }

    private func fallbackKind(isDirectory: Bool, isApplication: Bool) -> String {
        if isApplication { return "Application" }
        if isDirectory { return "Folder" }
        return "File"
    }
}
