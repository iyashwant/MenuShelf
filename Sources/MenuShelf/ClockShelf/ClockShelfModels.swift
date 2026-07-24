//
//  ClockShelfModels.swift
//  MenuShelf
//
//  Standalone Clock Shelf data models. The fields that hook them into the
//  broader settings tree (`AppSettings.clockShelf` and
//  `MenuViewConfig.clockShelfItem`) stay inline in `AppModels.swift` since
//  they are properties of those host structs.
//

import Foundation

// MARK: - ClockShelfMenuItemConfig

/// A single Clock Shelf entry inside a `MenuViewConfig`. Mirrors
/// `BrowserFlipMenuItemConfig` and `ClipboardShelfMenuItemConfig`
/// field-for-field so the existing menu/render patterns transplant cleanly.
struct ClockShelfMenuItemConfig: Codable, Identifiable, Equatable {
    var id: UUID
    var titleOverride: String?
    var sectionName: String?
    var createdAt: Date
    var updatedAt: Date

    /// Returns the trimmed override when non-empty, or "Clock Shelf".
    var displayTitle: String {
        if let trimmed = titleOverride?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !trimmed.isEmpty {
            return trimmed
        }
        return "Clock Shelf"
    }

    static func make() -> ClockShelfMenuItemConfig {
        ClockShelfMenuItemConfig(
            id: UUID(),
            titleOverride: nil,
            sectionName: nil,
            createdAt: Date(),
            updatedAt: Date()
        )
    }
}

// MARK: - ClockShelfPresentationMode

/// Selector controlling whether a `ClockShelfMenuItemConfig` renders as a
/// single click target opening the popover, or as a parent `NSMenuItem`
/// whose `submenu` lists the configured clocks inline.
enum ClockShelfPresentationMode: String, Codable, CaseIterable, Identifiable {
    case popover
    case submenu

    var id: String { rawValue }

    var label: String {
        switch self {
        case .popover: "Popover"
        case .submenu: "Submenu"
        }
    }
}

// MARK: - ClockConfig

/// A single user-configured clock. `sortOrder` is maintained by
/// `PreferencesStore` to remain contiguous and zero-based.
struct ClockConfig: Codable, Identifiable, Equatable {
    var id: UUID
    /// IANA identifier such as "America/Los_Angeles". Validated against
    /// `TimeZone.knownTimeZoneIdentifiers` at write-time.
    var timeZoneIdentifier: String
    var label: String?
    var emoji: String?
    var pinToMenuBar: Bool
    var showInPopover: Bool
    var sortOrder: Int
    var createdAt: Date
    var updatedAt: Date

    /// Resolved display label: trimmed `label` when non-empty, otherwise
    /// the localized city portion of the time zone identifier (the last
    /// `/`-delimited segment with underscores replaced by spaces).
    var displayLabel: String {
        if let trimmed = label?.trimmingCharacters(in: .whitespacesAndNewlines),
           !trimmed.isEmpty {
            return trimmed
        }
        let segment = timeZoneIdentifier
            .split(separator: "/")
            .last
            .map(String.init) ?? timeZoneIdentifier
        return segment.replacingOccurrences(of: "_", with: " ")
    }

    /// The Foundation `TimeZone`, falling back to `.current` if the stored
    /// identifier is no longer recognized by the system.
    var resolvedTimeZone: TimeZone {
        TimeZone(identifier: timeZoneIdentifier) ?? .current
    }
}

// MARK: - ClockShelfSettings

/// Top-level Clock Shelf settings persisted to MenuShelf's `settings.json`
/// under `AppSettings.clockShelf`.
struct ClockShelfSettings: Codable, Equatable {
    var enableClockShelf: Bool
    var clocks: [ClockConfig]
    var use24HourTime: Bool
    var popoverTextSize: Int
    var resetOffsetOnClose: Bool
    /// Optional so older settings.json (pre-Requirement 3.5) decodes
    /// cleanly via Swift's synthesized `Codable`. UI code reads through
    /// `resolvedPresentationMode` to get the non-optional default.
    var presentationMode: ClockShelfPresentationMode?

    static let defaults = ClockShelfSettings(
        enableClockShelf: false,
        clocks: [],
        use24HourTime: false,
        popoverTextSize: 13,
        resetOffsetOnClose: true,
        presentationMode: .submenu
    )

    /// Clamped value used by the SwiftUI stepper (range 11...22).
    var resolvedPopoverTextSize: Int {
        min(max(popoverTextSize, 11), 22)
    }

    /// Resolves the presentation mode, falling back to `.submenu` for
    /// settings.json predating Requirement 3.5 (where the field is
    /// missing) and for any future writes that explicitly nil the field.
    ///
    /// `.submenu` is the default so that a Clock Shelf item sitting in a
    /// menu view alongside folders behaves like every other row there:
    /// hover reveals an inline `NSMenu`, and the trailing "Open Clock
    /// Shelf…" action escalates to the popover. The standalone status
    /// item is unaffected either way — `StandaloneModuleClickRouter`
    /// opens the popover directly and never consults this mode.
    var resolvedPresentationMode: ClockShelfPresentationMode {
        presentationMode ?? .submenu
    }
}
