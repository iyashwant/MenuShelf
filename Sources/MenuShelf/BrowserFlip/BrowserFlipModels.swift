//
//  BrowserFlipModels.swift
//  MenuShelf
//
//  Standalone Browser Flip data models. The fields that hook them into
//  the broader settings tree (`AppSettings.browserFlip` and
//  `MenuViewConfig.browserFlipItem`) stay inline in AppModels.swift since
//  they are properties of those host structs.
//

import Foundation

struct BrowserFlipMenuItemConfig: Codable, Identifiable, Equatable {
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
        return "Default Browser"
    }

    static func make() -> BrowserFlipMenuItemConfig {
        BrowserFlipMenuItemConfig(
            id: UUID(),
            titleOverride: nil,
            sectionName: nil,
            createdAt: Date(),
            updatedAt: Date()
        )
    }
}

struct BrowserFlipSettings: Codable, Equatable {
    var enableBrowserFlip: Bool
    var savedBrowsers: [BrowserInfo]

    static let defaults = BrowserFlipSettings(
        enableBrowserFlip: false,
        savedBrowsers: []
    )
}
