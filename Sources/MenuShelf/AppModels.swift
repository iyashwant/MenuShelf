import AppKit
import Foundation
import UniformTypeIdentifiers

enum DisplayMode: String, Codable, CaseIterable, Identifiable {
    case separateItems
    case groupedItem

    var id: String { rawValue }

    var label: String {
        switch self {
        case .separateItems: "Legacy separate sources"
        case .groupedItem: "Legacy grouped sources"
        }
    }
}

enum MenuViewLayout: String, Codable, CaseIterable, Identifiable {
    case automatic
    case sourceList
    case firstFolderContents

    var id: String { rawValue }

    var label: String {
        switch self {
        case .automatic: "Automatic"
        case .sourceList: "Sources list"
        case .firstFolderContents: "First folder contents"
        }
    }
}

enum ShelfItemKind: String, Codable, CaseIterable, Identifiable {
    case folder
    case app

    var id: String { rawValue }

    var label: String {
        switch self {
        case .folder: "Folder"
        case .app: "App"
        }
    }

    var symbolName: String {
        switch self {
        case .folder: "folder"
        case .app: "app"
        }
    }
}

enum SortKey: String, Codable, CaseIterable, Identifiable {
    case name
    case dateCreated
    case dateModified
    case dateLastOpened
    case dateAdded
    case kind
    case size

    var id: String { rawValue }

    var label: String {
        switch self {
        case .name: "Name"
        case .dateCreated: "Date Created"
        case .dateModified: "Date Modified"
        case .dateLastOpened: "Date Last Opened"
        case .dateAdded: "Date Added"
        case .kind: "Kind"
        case .size: "Size"
        }
    }
}

enum SortDirection: String, Codable, CaseIterable, Identifiable {
    case ascending
    case descending

    var id: String { rawValue }

    var label: String {
        switch self {
        case .ascending: "Ascending"
        case .descending: "Descending"
        }
    }
}

enum FileIconSize: String, Codable, CaseIterable, Identifiable {
    case small
    case medium
    case large

    var id: String { rawValue }

    var label: String {
        switch self {
        case .small: "Small"
        case .medium: "Medium"
        case .large: "Large"
        }
    }

    var pointSize: CGFloat {
        switch self {
        case .small: 16
        case .medium: 22
        case .large: 32
        }
    }
}

enum ShortcutOpenLocation: String, Codable, CaseIterable, Identifiable {
    case menuBarItem
    case cursor

    var id: String { rawValue }

    var label: String {
        switch self {
        case .menuBarItem: "At menu bar icon"
        case .cursor: "At cursor"
        }
    }
}

enum GlobalMoreMenuBehavior: String, Codable, CaseIterable, Identifiable {
    case visibleAtBottom
    case visibleAtTop
    case hiddenUntilOption

    var id: String { rawValue }

    var label: String {
        switch self {
        case .visibleAtBottom: "Bottom"
        case .visibleAtTop: "Top"
        case .hiddenUntilOption: "Hidden until Option"
        }
    }
}

enum MoreItemPosition: String, Codable, CaseIterable, Identifiable {
    case none
    case top
    case bottom

    var id: String { rawValue }

    var label: String {
        switch self {
        case .none: "Hidden"
        case .top: "Top"
        case .bottom: "Bottom"
        }
    }
}

enum FilterMode: String, Codable, CaseIterable, Identifiable {
    case all
    case appsOnly
    case foldersOnly
    case documentsOnly
    case imagesOnly

    var id: String { rawValue }

    var label: String {
        switch self {
        case .all: "All Items"
        case .appsOnly: "Apps Only"
        case .foldersOnly: "Folders Only"
        case .documentsOnly: "Documents Only"
        case .imagesOnly: "Images Only"
        }
    }
}

enum OpenBehavior: String, Codable, CaseIterable, Identifiable {
    case browseFoldersAsSubmenus
    case openFoldersInFinder

    var id: String { rawValue }

    var label: String {
        switch self {
        case .browseFoldersAsSubmenus: "Browse folders as submenus"
        case .openFoldersInFinder: "Open folders in Finder"
        }
    }
}

enum MenuBarStyle: String, Codable, CaseIterable, Identifiable {
    case iconOnly
    case titleOnly
    case iconAndTitle

    var id: String { rawValue }

    var label: String {
        switch self {
        case .iconOnly: "Icon"
        case .titleOnly: "Title"
        case .iconAndTitle: "Icon & Title"
        }
    }
}

enum IconTint: String, Codable, CaseIterable, Identifiable {
    case none
    case accent
    case monochrome

    var id: String { rawValue }
}

enum FolderIconConfig: Codable, Equatable {
    case systemSymbol(name: String, tint: IconTint?)
    case emoji(String)
    case customImage(bookmarkData: Data)
    case folderIcon
    case monogram(String)
}

struct KeyboardShortcutConfig: Codable, Equatable {
    var isEnabled: Bool
    var keyEquivalent: String
    var modifierFlags: UInt
    var keyCode: UInt16?

    static let disabled = KeyboardShortcutConfig(isEnabled: false, keyEquivalent: "", modifierFlags: 0, keyCode: nil)

    var displayString: String {
        guard isEnabled, !keyEquivalent.isEmpty else { return "Record Shortcut" }

        var parts: [String] = []
        let flags = NSEvent.ModifierFlags(rawValue: modifierFlags)
        if flags.contains(.control) { parts.append("⌃") }
        if flags.contains(.option) { parts.append("⌥") }
        if flags.contains(.shift) { parts.append("⇧") }
        if flags.contains(.command) { parts.append("⌘") }
        parts.append(keyEquivalent.uppercased())
        return parts.joined()
    }
}

struct MenuSettings: Codable, Equatable {
    var sortKey: SortKey
    var sortDirection: SortDirection
    var keepFoldersOnTop: Bool
    var keepAppsOnTop: Bool
    var maxItems: Int?
    var showHiddenFiles: Bool
    var showFileExtensions: Bool
    var showPreview: Bool
    var showMetadata: Bool
    var followAliases: Bool
    var followSymlinks: Bool
    var showMoreItemPosition: MoreItemPosition
    var filterMode: FilterMode
    var ignoredNames: [String]
    var fileIconSize: FileIconSize?
    var showFolderTitle: Bool?
    var showOpenWithForSubfolders: Bool?
    var showTips: Bool?
    var enableModifierActions: Bool?

    static let defaults = MenuSettings(
        sortKey: .name,
        sortDirection: .ascending,
        keepFoldersOnTop: true,
        keepAppsOnTop: false,
        maxItems: 200,
        showHiddenFiles: false,
        showFileExtensions: true,
        showPreview: true,
        showMetadata: true,
        followAliases: true,
        followSymlinks: true,
        showMoreItemPosition: .bottom,
        filterMode: .all,
        ignoredNames: [".DS_Store"],
        fileIconSize: .medium,
        showFolderTitle: true,
        showOpenWithForSubfolders: false,
        showTips: true,
        enableModifierActions: true
    )

    var resolvedFileIconSize: FileIconSize { fileIconSize ?? .medium }
    var resolvedShowFolderTitle: Bool { showFolderTitle ?? true }
    var resolvedShowOpenWithForSubfolders: Bool { showOpenWithForSubfolders ?? false }
    var resolvedShowTips: Bool { showTips ?? true }
    var resolvedEnableModifierActions: Bool { enableModifierActions ?? true }
}

struct FolderConfig: Codable, Identifiable, Equatable {
    var id: UUID
    var displayName: String
    var bookmarkData: Data
    var originalPathHint: String
    var itemKind: ShelfItemKind?
    var isVisible: Bool
    var displayModeOverride: DisplayMode?
    var icon: FolderIconConfig
    var menuBarStyle: MenuBarStyle
    var menuSettings: MenuSettings
    var shortcut: KeyboardShortcutConfig?
    var openBehavior: OpenBehavior
    var iconColorHex: String?
    var createdAt: Date
    var updatedAt: Date

    var resolvedItemKind: ShelfItemKind {
        itemKind ?? (originalPathHint.hasSuffix(".app") ? .app : .folder)
    }

    static func make(url: URL, bookmarkData: Data, defaults: MenuSettings, itemKind: ShelfItemKind? = nil) -> FolderConfig {
        let inferredKind = itemKind ?? (url.pathExtension.lowercased() == "app" ? .app : .folder)
        var settings = defaults
        if url.lastPathComponent == "Applications" || url.path == "/Applications" {
            settings.keepAppsOnTop = true
        }

        return FolderConfig(
            id: UUID(),
            displayName: FileManager.default.displayName(atPath: url.path),
            bookmarkData: bookmarkData,
            originalPathHint: url.path,
            itemKind: inferredKind,
            isVisible: true,
            displayModeOverride: nil,
            icon: .folderIcon,
            menuBarStyle: .iconOnly,
            menuSettings: settings,
            shortcut: .disabled,
            openBehavior: .browseFoldersAsSubmenus,
            iconColorHex: nil,
            createdAt: Date(),
            updatedAt: Date()
        )
    }
}

struct MenuViewItem: Codable, Identifiable, Equatable {
    var id: UUID
    var sourceID: UUID
    var titleOverride: String?
    var sectionName: String?
    var iconOverride: FolderIconConfig?
    var iconColorHexOverride: String?
    var menuSettingsOverride: MenuSettings?
    var createdAt: Date
    var updatedAt: Date

    static func make(sourceID: UUID) -> MenuViewItem {
        MenuViewItem(
            id: UUID(),
            sourceID: sourceID,
            titleOverride: nil,
            sectionName: nil,
            iconOverride: nil,
            iconColorHexOverride: nil,
            menuSettingsOverride: nil,
            createdAt: Date(),
            updatedAt: Date()
        )
    }
}

struct MenuViewConfig: Codable, Identifiable, Equatable {
    var id: UUID
    var title: String
    var isVisible: Bool
    var icon: FolderIconConfig
    var iconColorHex: String?
    var menuBarStyle: MenuBarStyle
    var shortcut: KeyboardShortcutConfig?
    var openLocation: ShortcutOpenLocation?
    var layout: MenuViewLayout?
    var menuSettings: MenuSettings
    var items: [MenuViewItem]
    var createdAt: Date
    var updatedAt: Date

    var resolvedOpenLocation: ShortcutOpenLocation? { openLocation }
    var resolvedLayout: MenuViewLayout { layout ?? .automatic }

    static func make(title: String = "MenuShelf", defaults: MenuSettings = .defaults, sourceIDs: [UUID] = []) -> MenuViewConfig {
        MenuViewConfig(
            id: UUID(),
            title: title,
            isVisible: true,
            icon: .folderIcon,
            iconColorHex: nil,
            menuBarStyle: .iconAndTitle,
            shortcut: .disabled,
            openLocation: nil,
            layout: .automatic,
            menuSettings: defaults,
            items: sourceIDs.map { MenuViewItem.make(sourceID: $0) },
            createdAt: Date(),
            updatedAt: Date()
        )
    }
}

struct AppSettings: Codable, Equatable {
    var schemaVersion: Int
    // Deprecated: kept only so older settings decode cleanly while menuViews take over.
    var displayMode: DisplayMode
    var showMenuBarItemWhenEmpty: Bool
    var launchAtLogin: Bool
    var reduceAnimations: Bool
    var defaultMenuSettings: MenuSettings
    var folders: [FolderConfig]
    var menuViews: [MenuViewConfig]?
    var showFileAndFolderIcons: Bool?
    var showFileSubmenus: Bool?
    var showFolderSubmenus: Bool?
    var shortcutOpenLocation: ShortcutOpenLocation?
    var showTopLevelFolderIcons: Bool?
    var topLevelFolderIconSize: FileIconSize?
    var moreMenuBehavior: GlobalMoreMenuBehavior?

    static let defaults = AppSettings(
        schemaVersion: 6,
        displayMode: .groupedItem,
        showMenuBarItemWhenEmpty: true,
        launchAtLogin: false,
        reduceAnimations: false,
        defaultMenuSettings: .defaults,
        folders: [],
        menuViews: [],
        showFileAndFolderIcons: true,
        showFileSubmenus: true,
        showFolderSubmenus: true,
        shortcutOpenLocation: .menuBarItem,
        showTopLevelFolderIcons: true,
        topLevelFolderIconSize: .small,
        moreMenuBehavior: .visibleAtBottom
    )

    var resolvedShowFileAndFolderIcons: Bool { showFileAndFolderIcons ?? true }
    var resolvedShowFileSubmenus: Bool { showFileSubmenus ?? true }
    var resolvedShowFolderSubmenus: Bool { showFolderSubmenus ?? true }
    var resolvedShortcutOpenLocation: ShortcutOpenLocation { shortcutOpenLocation ?? .menuBarItem }
    var resolvedShowTopLevelFolderIcons: Bool { showTopLevelFolderIcons ?? true }
    var resolvedTopLevelFolderIconSize: FileIconSize { topLevelFolderIconSize ?? .small }
    var resolvedMoreMenuBehavior: GlobalMoreMenuBehavior { moreMenuBehavior ?? .visibleAtBottom }
    var resolvedMenuViews: [MenuViewConfig] { menuViews ?? [] }
}

struct FileMetadata: Equatable {
    var kindDescription: String
    var size: Int64?
    var createdAt: Date?
    var modifiedAt: Date?
    var lastOpenedAt: Date?
    var addedAt: Date?
    var dimensions: CGSize?
    var duration: TimeInterval?

    static let empty = FileMetadata(kindDescription: "", size: nil, createdAt: nil, modifiedAt: nil, lastOpenedAt: nil, addedAt: nil, dimensions: nil, duration: nil)
}

struct FileMenuItem: Equatable {
    var url: URL
    var resolvedURL: URL?
    var displayName: String
    var kind: UTType?
    var isDirectory: Bool
    var isPackage: Bool
    var isApplication: Bool
    var isAlias: Bool
    var isSymlink: Bool
    var aliasIsBroken: Bool
    var icon: NSImage
    var metadata: FileMetadata

    var actionURL: URL { resolvedURL ?? url }
}

struct DirectoryListing {
    var items: [FileMenuItem]
    var omittedCount: Int
    var totalCount: Int
}
