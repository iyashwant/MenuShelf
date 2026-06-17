//
//  CoreLogicTests.swift
//  WorldClockTests
//
//  Unit tests for core, non-UI logic that previously had no direct
//  coverage: the settings migration ladder, FileAccessService directory
//  listing (sort / filter / hidden / ignored / maxItems), and the
//  Shortcuts CLI line parser.
//

import Foundation
import Testing
@testable import MenuShelf

// MARK: - Migration ladder

@Test("migratedSettings bumps any old schema to the current version (16)")
func migrationBumpsSchemaVersion() {
    var old = AppSettings.defaults
    old.schemaVersion = 1
    #expect(PreferencesStore.migratedSettings(old).schemaVersion == 16)
}

@Test("migratedSettings is idempotent")
func migrationIsIdempotent() {
    var old = AppSettings.defaults
    old.schemaVersion = 1
    let once = PreferencesStore.migratedSettings(old)
    let twice = PreferencesStore.migratedSettings(once)
    #expect(once == twice)
}

@Test("migratedSettings backfills nil optional collections with defaults")
func migrationBackfillsOptionals() {
    var old = AppSettings.defaults
    old.schemaVersion = 1
    old.appleScripts = nil
    old.bookmarkShelf = nil
    old.standaloneModules = nil

    let migrated = PreferencesStore.migratedSettings(old)
    #expect(migrated.appleScripts == [])
    #expect(migrated.bookmarkShelf == BookmarkShelfSettings.defaults)
    #expect(migrated.standaloneModules == [])
}

@Test("migratedSettings (<2) forces every folder to iconOnly menu bar style")
func migrationForcesIconOnlyStyle() {
    var folder = FolderConfig.make(url: URL(fileURLWithPath: "/tmp/x"), bookmarkData: Data(), defaults: .defaults, itemKind: .folder)
    folder.menuBarStyle = .titleOnly

    var old = AppSettings.defaults
    old.schemaVersion = 1
    old.folders = [folder]

    let migrated = PreferencesStore.migratedSettings(old)
    #expect(migrated.folders.first?.menuBarStyle == .iconOnly)
}

@Test("migratedSettings drops menu-view items that reference a missing source")
func migrationDropsOrphanedItems() {
    var view = MenuViewConfig.make()
    view.items = [MenuViewItem.make(sourceID: UUID())] // references no real folder

    var old = AppSettings.defaults
    old.schemaVersion = 1
    old.folders = []
    old.menuViews = [view]

    let migrated = PreferencesStore.migratedSettings(old)
    #expect(migrated.menuViews?.first?.items.isEmpty == true)
}

// MARK: - FileAccessService directory listing

private func makeTempDir() throws -> URL {
    let dir = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("MenuShelfTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

private func populate(_ dir: URL) throws {
    let fm = FileManager.default
    try Data().write(to: dir.appendingPathComponent("alpha.txt"))
    try Data().write(to: dir.appendingPathComponent("beta.txt"))
    try fm.createDirectory(at: dir.appendingPathComponent("Zebra"), withIntermediateDirectories: true)
    try Data().write(to: dir.appendingPathComponent(".DS_Store"))
    try Data().write(to: dir.appendingPathComponent(".hidden.txt"))
}

private func config(_ settings: MenuSettings) -> FolderConfig {
    FolderConfig.make(url: URL(fileURLWithPath: "/tmp"), bookmarkData: Data(), defaults: settings, itemKind: .folder)
}

@Test("directoryListing sorts by name with folders on top, skipping hidden/ignored")
func directoryListingDefaultSortAndFilter() throws {
    let dir = try makeTempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    try populate(dir)

    var settings = MenuSettings.defaults
    settings.maxItems = nil
    settings.keepFoldersOnTop = true

    let listing = try FileAccessService().directoryListing(in: dir, config: config(settings), visited: [])
    #expect(listing.items.map(\.displayName) == ["Zebra", "alpha.txt", "beta.txt"])
    #expect(listing.totalCount == 3) // .DS_Store + .hidden.txt excluded
}

@Test("directoryListing foldersOnly returns only directories")
func directoryListingFoldersOnly() throws {
    let dir = try makeTempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    try populate(dir)

    var settings = MenuSettings.defaults
    settings.maxItems = nil
    settings.filterMode = .foldersOnly

    let listing = try FileAccessService().directoryListing(in: dir, config: config(settings), visited: [])
    #expect(listing.items.map(\.displayName) == ["Zebra"])
}

@Test("directoryListing includes hidden files when showHiddenFiles is on and nothing is ignored")
func directoryListingShowsHidden() throws {
    let dir = try makeTempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    try populate(dir)

    var settings = MenuSettings.defaults
    settings.maxItems = nil
    settings.showHiddenFiles = true
    settings.ignoredNames = []

    let listing = try FileAccessService().directoryListing(in: dir, config: config(settings), visited: [])
    #expect(listing.totalCount == 5)
    #expect(listing.items.contains { $0.displayName.hasSuffix(".hidden") || $0.displayName == ".hidden.txt" })
}

@Test("directoryListing caps at maxItems and reports omittedCount")
func directoryListingMaxItems() throws {
    let dir = try makeTempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    try populate(dir)

    var settings = MenuSettings.defaults
    settings.maxItems = 1
    settings.keepFoldersOnTop = true

    let listing = try FileAccessService().directoryListing(in: dir, config: config(settings), visited: [])
    #expect(listing.items.count == 1)
    #expect(listing.items.first?.displayName == "Zebra")
    #expect(listing.totalCount == 3)
    #expect(listing.omittedCount == 2)
}

// MARK: - Shortcuts CLI parser

@Test("parseShortcutsWithIdentifiers extracts trailing UUIDs and tolerates plain lines")
func parseShortcutsIdentifiers() {
    let output = """
    My Shortcut (A1B2C3D4-0000-1111-2222-ABCDEFABCDEF)
    Plain Name

    Another (deadbeef-0000-1111-2222-abcdefabcdef)
    """
    let parsed = parseShortcutsWithIdentifiers(output)
    #expect(parsed.count == 3)
    #expect(parsed[0].name == "My Shortcut")
    #expect(parsed[0].identifier == "A1B2C3D4-0000-1111-2222-ABCDEFABCDEF")
    #expect(parsed[1].name == "Plain Name")
    #expect(parsed[1].identifier == nil)
    #expect(parsed[2].identifier == "deadbeef-0000-1111-2222-abcdefabcdef")
}
