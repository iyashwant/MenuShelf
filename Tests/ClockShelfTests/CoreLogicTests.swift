//
//  CoreLogicTests.swift
//  ClockShelfTests
//
//  Unit tests for core, non-UI logic that previously had no direct
//  coverage: the settings migration ladder, FileAccessService directory
//  listing (sort / filter / hidden / ignored / maxItems), and the
//  Shortcuts CLI line parser.
//

import AppKit
import Foundation
import Testing
@testable import MenuShelf

// MARK: - Migration ladder

@Test("migratedSettings bumps any old schema to the current version (17)")
func migrationBumpsSchemaVersion() {
    var old = AppSettings.defaults
    old.schemaVersion = 1
    #expect(PreferencesStore.migratedSettings(old).schemaVersion == 17)
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

// MARK: - Menu view module order

@Test("resolvedModuleOrder defaults to ModuleKind order and skips unattached modules")
func moduleOrderDefaultsToKindOrder() {
    var view = MenuViewConfig.make()
    view.caffeineShelfItem = .make()
    view.browserFlipItem = .make()
    view.bookmarkShelfItem = .make()
    #expect(view.resolvedModuleOrder == [.browserFlip, .bookmarkShelf, .caffeineShelf])
}

@Test("resolvedModuleOrder follows moduleOrder, drops detached kinds, and appends new ones")
func moduleOrderFollowsStoredOrder() {
    var view = MenuViewConfig.make()
    view.browserFlipItem = .make()
    view.clipboardShelfItem = .make()
    view.caffeineShelfItem = .make()
    view.moduleOrder = [.caffeineShelf, .clockShelf, .browserFlip, .caffeineShelf]
    #expect(view.resolvedModuleOrder == [.caffeineShelf, .browserFlip, .clipboardShelf])
}

@Test("MenuViewConfig decodes settings written before moduleOrder existed")
func moduleOrderDecodesLegacySettings() throws {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    var object = try #require(
        JSONSerialization.jsonObject(with: encoder.encode(MenuViewConfig.make())) as? [String: Any]
    )
    object.removeValue(forKey: "moduleOrder")
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let decoded = try decoder.decode(MenuViewConfig.self, from: JSONSerialization.data(withJSONObject: object))
    #expect(decoded.moduleOrder == nil)
}

// MARK: - Status icon hole filling

private func testImage(_ draw: @escaping (NSRect) -> Void) -> NSImage {
    NSImage(size: NSSize(width: 20, height: 20), flipped: false) { rect in
        NSColor.black.set()
        draw(rect)
        return true
    }
}

private func alpha(of image: NSImage, x: Int, y: Int) -> CGFloat? {
    let rep = image.representations
        .compactMap { $0 as? NSBitmapImageRep }
        .max { $0.pixelsWide < $1.pixelsWide }
    return rep?.colorAt(x: x, y: y)?.alphaComponent
}

@Test("fillingLargestEnclosedHole fills a ring's centre and leaves the outside clear")
func holeFillFillsEnclosedRegion() throws {
    let ring = testImage { rect in
        let path = NSBezierPath(ovalIn: rect.insetBy(dx: 3, dy: 3))
        path.lineWidth = 2
        path.stroke()
    }
    let filled = ring.fillingLargestEnclosedHole()
    #expect(filled !== ring)
    #expect(try #require(alpha(of: filled, x: 20, y: 20)) == 1)
    #expect(try #require(alpha(of: filled, x: 0, y: 0)) == 0)
}

@Test("fillingLargestEnclosedHole returns the image unchanged when nothing is enclosed")
func holeFillLeavesSolidShapes() {
    let disc = testImage { rect in
        NSBezierPath(ovalIn: rect.insetBy(dx: 3, dy: 3)).fill()
    }
    #expect(disc.fillingLargestEnclosedHole() === disc)
}

// MARK: - Clipboard content filter

@Test("filterOnOpen opens on Text when the popup has never closed or was closed 60s+ ago")
func contentFilterDefaultsToText() {
    let now = Date()
    #expect(ClipboardContentFilter.filterOnOpen(current: .images, closedAt: nil, now: now) == .text)
    #expect(ClipboardContentFilter.filterOnOpen(current: .all, closedAt: now.addingTimeInterval(-60), now: now) == .text)
    #expect(ClipboardContentFilter.filterOnOpen(current: .images, closedAt: now.addingTimeInterval(-600), now: now) == .text)
}

@Test("filterOnOpen keeps the last filter when the popup reopens within 60s")
func contentFilterRemembersRecentChoice() {
    let now = Date()
    let recently = now.addingTimeInterval(-59)
    #expect(ClipboardContentFilter.filterOnOpen(current: .all, closedAt: recently, now: now) == .all)
    #expect(ClipboardContentFilter.filterOnOpen(current: .images, closedAt: recently, now: now) == .images)
    #expect(ClipboardContentFilter.filterOnOpen(current: .text, closedAt: recently, now: now) == .text)
}

@Test("content filters include the right items and cycle in both directions")
func contentFilterMatchingAndCycling() {
    #expect(ClipboardContentFilter.all.includes(isImage: true))
    #expect(ClipboardContentFilter.all.includes(isImage: false))
    #expect(ClipboardContentFilter.text.includes(isImage: false))
    #expect(!ClipboardContentFilter.text.includes(isImage: true))
    #expect(ClipboardContentFilter.images.includes(isImage: true))
    #expect(!ClipboardContentFilter.images.includes(isImage: false))

    #expect(ClipboardContentFilter.all.cycled() == .text)
    #expect(ClipboardContentFilter.images.cycled() == .all)
    #expect(ClipboardContentFilter.all.cycled(backwards: true) == .images)
    #expect(ClipboardContentFilter.text.cycled(backwards: true) == .all)
}

// MARK: - Clipboard copy time

private func copyTimeFixture() -> (calendar: Calendar, locale: Locale, now: Date) {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    let now = calendar.date(from: DateComponents(year: 2026, month: 9, day: 27, hour: 15, minute: 30))!
    return (calendar, Locale(identifier: "en_GB"), now)
}

@Test("copy time says Today or Yesterday with the time for recent copies")
func copyTimeRelativeDays() {
    let (calendar, locale, now) = copyTimeFixture()
    let earlierToday = calendar.date(from: DateComponents(year: 2026, month: 9, day: 27, hour: 0, minute: 58))!
    let yesterday = calendar.date(from: DateComponents(year: 2026, month: 9, day: 26, hour: 21, minute: 14))!
    let today = ClipboardShelfCopyTime.string(for: earlierToday, now: now, calendar: calendar, locale: locale)
    let yday = ClipboardShelfCopyTime.string(for: yesterday, now: now, calendar: calendar, locale: locale)
    #expect(today.hasPrefix("Today, "))
    #expect(today.contains("58"))
    #expect(yday.hasPrefix("Yesterday, "))
    #expect(yday.contains("14"))
}

@Test("copy time shows the full date with a short month before yesterday")
func copyTimeOlderDates() {
    let (calendar, locale, now) = copyTimeFixture()
    let older = calendar.date(from: DateComponents(year: 2026, month: 9, day: 25, hour: 4, minute: 52))!
    let text = ClipboardShelfCopyTime.string(for: older, now: now, calendar: calendar, locale: locale)
    #expect(text.hasPrefix("25 Sept 2026, ") || text.hasPrefix("25 Sep 2026, "))
    #expect(!text.contains("September"))
    #expect(text.contains("52"))
}

// MARK: - Clipboard screenshots

@Test("screenshot folder follows the macOS location setting and defaults to the Desktop")
func screenshotFolderLocation() {
    let home = URL(fileURLWithPath: "/Users/someone", isDirectory: true)
    #expect(ClipboardShelfScreenshots.screenshotFolder(fromLocation: nil, home: home).path == "/Users/someone/Desktop")
    #expect(ClipboardShelfScreenshots.screenshotFolder(fromLocation: "  ", home: home).path == "/Users/someone/Desktop")
    #expect(ClipboardShelfScreenshots.screenshotFolder(fromLocation: "~/Documents/Screenshots", home: home).path == "/Users/someone/Documents/Screenshots")
    #expect(ClipboardShelfScreenshots.screenshotFolder(fromLocation: "/Volumes/Shots", home: home).path == "/Volumes/Shots")
}

@Test("recentImages keeps only visible images saved since the cutoff, newest first")
func screenshotScanFiltersByTypeAndAge() throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }

    let now = Date()
    func file(_ name: String, age: TimeInterval) throws {
        let url = folder.appendingPathComponent(name)
        try Data([0]).write(to: url)
        let date = now.addingTimeInterval(-age)
        try FileManager.default.setAttributes([.creationDate: date, .modificationDate: date], ofItemAtPath: url.path)
    }
    try file("new.png", age: 60)
    try file("newer.jpg", age: 10)
    try file("old.png", age: 3 * 86_400)
    try file("notes.txt", age: 60)
    try file(".hidden.png", age: 60)

    let files = ClipboardShelfScreenshots.recentImages(in: [folder, folder], since: now.addingTimeInterval(-2 * 86_400), limit: 10)
    #expect(files.map(\.url.lastPathComponent) == ["newer.jpg", "new.png"])

    let limited = ClipboardShelfScreenshots.recentImages(in: [folder], since: now.addingTimeInterval(-2 * 86_400), limit: 1)
    #expect(limited.map(\.url.lastPathComponent) == ["newer.jpg"])
}

@Test("Clipboard Shelf settings written before screenshots existed decode with it off")
func screenshotSettingsDecodeLegacy() throws {
    var legacy = ClipboardShelfSettings.defaults
    legacy.showScreenshots = nil
    legacy.screenshotFolders = nil
    legacy.screenshotMaxAgeDays = nil
    let data = try JSONEncoder().encode(legacy)
    let decoded = try JSONDecoder().decode(ClipboardShelfSettings.self, from: data)
    #expect(decoded.resolvedShowScreenshots == false)
    #expect(decoded.resolvedScreenshotFolders.isEmpty)
    #expect(decoded.resolvedScreenshotMaxAgeDays == 2)

    var tooLong = decoded
    tooLong.screenshotMaxAgeDays = 400
    #expect(tooLong.resolvedScreenshotMaxAgeDays == 30)
}
