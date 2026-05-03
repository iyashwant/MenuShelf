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
    private let fileManager = FileManager.default

    func accessItem(_ config: FolderConfig) throws -> SecurityScopedURL {
        var isStale = false
        let url = try URL(
            resolvingBookmarkData: config.bookmarkData,
            options: [.withSecurityScope, .withoutUI],
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        )

        if isStale {
            throw FileAccessError.staleBookmark(config.originalPathHint)
        }

        guard fileManager.fileExists(atPath: url.path) else {
            throw FileAccessError.missingFolder(config.originalPathHint)
        }

        let didStart = url.startAccessingSecurityScopedResource()
        return SecurityScopedURL(url: url, didStartAccessing: didStart)
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
        let resourceKeys: Set<URLResourceKey> = [
            .isDirectoryKey,
            .isPackageKey,
            .isAliasFileKey,
            .isSymbolicLinkKey,
            .isHiddenKey,
            .localizedTypeDescriptionKey,
            .contentTypeKey,
            .fileSizeKey,
            .creationDateKey,
            .contentModificationDateKey,
            .contentAccessDateKey,
            .addedToDirectoryDateKey
        ]

        var options: FileManager.DirectoryEnumerationOptions = []
        if !settings.showHiddenFiles {
            options.insert(.skipsHiddenFiles)
        }

        let urls = try fileManager.contentsOfDirectory(
            at: folderURL,
            includingPropertiesForKeys: Array(resourceKeys),
            options: options
        )

        let items = urls.compactMap { url -> FileMenuItem? in
            guard !settings.ignoredNames.contains(url.lastPathComponent) else { return nil }
            if !settings.showHiddenFiles, url.lastPathComponent.hasPrefix(".") { return nil }

            guard let item = makeItem(url: url, config: config, visited: visited) else { return nil }
            guard include(item: item, settings: settings) else { return nil }
            return item
        }

        let sorted = sort(items: items, settings: settings)
        let limited: [FileMenuItem]
        let omittedCount: Int

        if let maxItems = settings.maxItems, maxItems > 0, sorted.count > maxItems {
            limited = Array(sorted.prefix(maxItems))
            omittedCount = sorted.count - maxItems
        } else {
            limited = sorted
            omittedCount = 0
        }

        return DirectoryListing(items: limited, omittedCount: omittedCount, totalCount: sorted.count)
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

        if isDirectory, visited.contains(targetURL.standardizedFileURL.path) {
            isDirectory = false
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
            icon: NSWorkspace.shared.icon(forFile: targetURL.path),
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
