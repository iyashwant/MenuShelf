//
//  ClipboardShelfModels.swift
//  MenuShelf
//
//  Standalone Clipboard Shelf data models. The fields that hook them into
//  the broader settings tree (`AppSettings.clipboardShelf` and
//  `MenuViewConfig.clipboardShelfItem`) stay inline in AppModels.swift since
//  they are properties of those host structs.
//

import Foundation
import CoreGraphics

// MARK: - Enums

enum ClipboardShelfSortKey: String, Codable, CaseIterable, Identifiable {
    case firstCopiedAt
    case lastCopiedAt
    case numberOfCopies

    var id: String { rawValue }

    var label: String {
        switch self {
        case .firstCopiedAt: "First copied"
        case .lastCopiedAt: "Last copied"
        case .numberOfCopies: "Number of copies"
        }
    }
}

enum ClipboardShelfSearchMode: String, Codable, CaseIterable, Identifiable {
    case exact
    case fuzzy
    case regularExpression

    var id: String { rawValue }

    var label: String {
        switch self {
        case .exact: "Exact"
        case .fuzzy: "Fuzzy"
        case .regularExpression: "Regular expression"
        }
    }
}

enum ClipboardShelfPinPosition: String, Codable, CaseIterable, Identifiable {
    case top
    case bottom

    var id: String { rawValue }

    var label: String {
        switch self {
        case .top: "Top"
        case .bottom: "Bottom"
        }
    }
}

enum ClipboardShelfPopupPosition: String, Codable, CaseIterable, Identifiable {
    case statusItem
    case cursor
    case screenCenter
    case lastPosition

    var id: String { rawValue }

    var label: String {
        switch self {
        case .statusItem: "At menu bar icon"
        case .cursor: "At cursor"
        case .screenCenter: "Center of screen"
        case .lastPosition: "Last position"
        }
    }
}

// MARK: - ClipboardShelfMenuItemConfig

/// A single Clipboard Shelf entry inside a `MenuViewConfig`. Mirrors
/// `BrowserFlipMenuItemConfig` field-for-field so the existing menu/render
/// patterns transplant cleanly.
struct ClipboardShelfMenuItemConfig: Codable, Identifiable, Equatable {
    var id: UUID
    var titleOverride: String?
    var sectionName: String?
    var createdAt: Date
    var updatedAt: Date

    var displayTitle: String {
        if let trimmed = titleOverride?.trimmingCharacters(in: .whitespacesAndNewlines),
           !trimmed.isEmpty {
            return trimmed
        }
        return "Clipboard Shelf"
    }

    static func make() -> ClipboardShelfMenuItemConfig {
        ClipboardShelfMenuItemConfig(
            id: UUID(),
            titleOverride: nil,
            sectionName: nil,
            createdAt: Date(),
            updatedAt: Date()
        )
    }
}

// MARK: - ClipboardShelfSettings

/// Top-level Clipboard Shelf settings persisted to MenuShelf's `settings.json`
/// under `AppSettings.clipboardShelf`. The `ClipboardShelfController` mirrors
/// these into the vendored `Defaults[...]` keys so the vendored core
/// observes changes through its existing `Defaults.updates(...)` streams.
struct ClipboardShelfSettings: Codable, Equatable {
    var enableClipboardShelf: Bool
    var clipboardCheckInterval: TimeInterval
    var size: Int
    var sortBy: ClipboardShelfSortKey
    var searchMode: ClipboardShelfSearchMode
    var pasteByDefault: Bool
    var removeFormattingByDefault: Bool
    var pinTo: ClipboardShelfPinPosition
    var numberOfUsableHotKey: Int
    var popupPosition: ClipboardShelfPopupPosition
    var popupSize: CGSize
    var pasteDelayMs: Int
    var clearOnQuit: Bool
    var clearPinnedOnQuit: Bool
    var ignoreEvents: Bool
    var ignoreOnlyNextEvent: Bool
    var enabledPasteboardTypes: [String]
    var ignoredApplicationBundleIDs: [String]
    var ignoredRegularExpressions: [String]
    var reduceAnimations: Bool

    static let defaults = ClipboardShelfSettings(
        enableClipboardShelf: false,
        clipboardCheckInterval: 1.0,
        size: 200,
        sortBy: .firstCopiedAt,
        searchMode: .fuzzy,
        pasteByDefault: true,
        removeFormattingByDefault: false,
        pinTo: .top,
        numberOfUsableHotKey: 9,
        popupPosition: .statusItem,
        popupSize: CGSize(width: 380, height: 472),
        pasteDelayMs: 50,
        clearOnQuit: false,
        clearPinnedOnQuit: false,
        ignoreEvents: false,
        ignoreOnlyNextEvent: false,
        enabledPasteboardTypes: [
            "public.file-url",
            "public.html",
            "public.png",
            "public.rtf",
            "public.utf8-plain-text",
            "public.tiff"
        ],
        ignoredApplicationBundleIDs: [],
        ignoredRegularExpressions: [],
        reduceAnimations: false
    )
}
