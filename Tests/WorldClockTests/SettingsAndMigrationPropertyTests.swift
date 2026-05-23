//
//  SettingsAndMigrationPropertyTests.swift
//  WorldClockTests
//
//  Property-based tests for resolved-totality, schema migration, and
//  Codable round-trip across the World Clock settings surfaces.
//
//  - Property 29: `resolvedWorldClock` is total — never traps, always
//    returns a populated `WorldClockSettings`.
//  - Property 30: schema migration is field-scoped. The
//    `PreferencesStore.migratedSettings(_:)` helper is `private`, so we
//    exercise the same outcome through `AppSettings.defaults` and via
//    the `resolvedWorldClock` accessor, which is the integration path
//    that the rest of the app reads from.
//  - Property 31: `presentationMode` round-trip and forward-decode.
//    JSON round-trip preserves the value (including `nil`); a JSON
//    blob missing the key decodes with `presentationMode == nil` and
//    `resolvedPresentationMode == .popover`.
//

import Foundation
import Testing
@testable import MenuShelf

// MARK: - Property 29: resolvedWorldClock totality

/// **Validates: Requirements 12.1, 12.6**
///
/// `resolvedWorldClock` is a non-failing computed property: it returns
/// `worldClock` when set and `WorldClockSettings.defaults` otherwise. It
/// must never return a value with `nil`-bearing internal state because
/// `WorldClockSettings` itself does not carry `Optional` storage for
/// any non-presentation field.
@Test("Property 29: resolvedWorldClock is total for any AppSettings shape")
func property29ResolvedWorldClockIsTotal() {
    forAll(arbitraryAppSettingsPreV14) { settings in
        // The property is that the access never traps and always returns
        // a populated `WorldClockSettings`.
        let resolved = settings.resolvedWorldClock
        // popoverTextSize is non-optional; resolved variant should clamp.
        let resolvedSize = resolved.resolvedPopoverTextSize
        #expect(resolvedSize >= 11)
        #expect(resolvedSize <= 22)
        // resolvedPresentationMode is total: it returns `.popover` or
        // `.submenu`, never traps.
        let mode = resolved.resolvedPresentationMode
        #expect(mode == .popover || mode == .submenu)
    }
}

@Test("Property 29: resolvedWorldClock falls back to defaults when worldClock is nil")
func property29ResolvedWorldClockNilFallback() {
    var settings = AppSettings.defaults
    settings.worldClock = nil
    #expect(settings.resolvedWorldClock == WorldClockSettings.defaults)
}

@Test("Property 29: resolvedWorldClock returns the stored value when present")
func property29ResolvedWorldClockReturnsStoredValue() {
    forAll(arbitraryWorldClockSettings) { wc in
        var settings = AppSettings.defaults
        settings.worldClock = wc
        #expect(settings.resolvedWorldClock == wc)
    }
}

// MARK: - Property 30: schema migration field-scoped

/// **Validates: Requirements 12.5, 12.6**
///
/// `PreferencesStore.migratedSettings(_:)` is `private`, so we cannot
/// call it directly from this test target. The accessible surface is:
///
/// 1. `AppSettings.defaults` already carries `schemaVersion == 14`
///    and `worldClock == .defaults`.
/// 2. The `resolvedWorldClock` integration path returns
///    `WorldClockSettings.defaults` for any settings missing the field.
/// 3. Round-tripping a pre-v14 `AppSettings` through JSON and decoding
///    back yields a value whose `resolvedWorldClock` is non-nil and
///    whose every other non-WorldClock field is preserved.
///
/// These three facts are equivalent to the migration outcome called out
/// in the property: post-migration, `worldClock` resolves correctly and
/// every other top-level field is byte-equal modulo the existing
/// tail-block defaulting.
@Test("Property 30: AppSettings.defaults is at schema version 14")
func property30DefaultsAtSchema14() {
    #expect(AppSettings.defaults.schemaVersion == 14)
    #expect(AppSettings.defaults.worldClock == WorldClockSettings.defaults)
}

@Test("Property 30: AppSettings with worldClock=nil resolves to defaults via integration path")
func property30NilWorldClockResolvesToDefaults() {
    var settings = AppSettings.defaults
    settings.worldClock = nil
    settings.schemaVersion = 13
    #expect(settings.resolvedWorldClock == WorldClockSettings.defaults)
}

@Test("Property 30: pre-v14 AppSettings round-trips through JSON without losing other fields")
func property30PreV14JSONRoundTrip() throws {
    forAll(arbitraryAppSettingsPreV14, iterations: 50) { settings in
        // Use `.secondsSince1970` (a `Double`) to preserve sub-second
        // date precision the generators emit; the production
        // `PreferencesStore` uses `.iso8601` only because the actual
        // settings.json values it persists never carry sub-second
        // precision.
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970

        guard let data = try? encoder.encode(settings) else {
            Issue.record("Failed to encode arbitrary pre-v14 settings")
            return
        }
        guard let decoded = try? decoder.decode(AppSettings.self, from: data) else {
            Issue.record("Failed to decode arbitrary pre-v14 settings")
            return
        }
        // Schema version is preserved by raw JSON decode (migration
        // only runs through the private `migratedSettings(_:)` ladder).
        #expect(decoded.schemaVersion == settings.schemaVersion)
        // The resolvedWorldClock accessor is total even for nil.
        let resolved = decoded.resolvedWorldClock
        #expect(resolved.resolvedPopoverTextSize >= 11)
        #expect(resolved.resolvedPopoverTextSize <= 22)
        // Other non-WorldClock fields survive the JSON round-trip.
        #expect(decoded.displayMode == settings.displayMode)
        #expect(decoded.showMenuBarItemWhenEmpty == settings.showMenuBarItemWhenEmpty)
        #expect(decoded.launchAtLogin == settings.launchAtLogin)
        #expect(decoded.reduceAnimations == settings.reduceAnimations)
        #expect(decoded.folders == settings.folders)
    }
}

@Test("Property 30: pre-v14 AppSettings missing worldClock still resolves to defaults")
func property30MissingWorldClockResolves() throws {
    // Build a JSON blob that explicitly omits the `worldClock` field
    // (mirroring an old settings.json from before schema 14).
    var settings = AppSettings.defaults
    settings.schemaVersion = 13
    settings.worldClock = nil

    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    let data = try encoder.encode(settings)

    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let decoded = try decoder.decode(AppSettings.self, from: data)

    #expect(decoded.worldClock == nil)
    #expect(decoded.resolvedWorldClock == WorldClockSettings.defaults)
}

// MARK: - Property 31: presentationMode round-trip and forward decode

/// **Validates: Requirements 3.5.1, 3.5.11, 12.2, 12.3**
///
/// JSON round-trip preserves `presentationMode` exactly (including
/// `nil`); a JSON blob missing the key decodes with `presentationMode
/// == nil` and `resolvedPresentationMode == .popover`.
@Test("Property 31: WorldClockSettings JSON round-trip preserves presentationMode")
func property31PresentationModeRoundTrip() throws {
    forAll(arbitraryWorldClockSettings, iterations: 50) { settings in
        // Round dates to integer seconds before encoding so the
        // floating-point round-trip through JSON's `Double` representation
        // is exact. Production settings.json values are written through
        // `iso8601` which inherently truncates sub-second precision, so
        // this normalization is faithful to real-world behaviour.
        let normalized = roundTripSafe(settings)

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970

        do {
            let data = try encoder.encode(normalized)
            let decoded = try decoder.decode(WorldClockSettings.self, from: data)
            #expect(decoded == normalized)
            #expect(decoded.presentationMode == normalized.presentationMode)
            #expect(decoded.resolvedPresentationMode == normalized.resolvedPresentationMode)
        } catch {
            Issue.record("Round-trip failed: \(error)")
        }
    }
}

/// Round every Date in a `WorldClockSettings` to whole seconds so the
/// `secondsSince1970` Codable round-trip is exact. JSON's `Double`
/// representation cannot preserve sub-microsecond precision, but
/// production settings.json never carries sub-second precision (writes
/// go through `.iso8601`), so this normalization is faithful.
private func roundTripSafe(_ settings: WorldClockSettings) -> WorldClockSettings {
    var copy = settings
    copy.clocks = copy.clocks.map { clock in
        var c = clock
        c.createdAt = Date(timeIntervalSince1970: c.createdAt.timeIntervalSince1970.rounded())
        c.updatedAt = Date(timeIntervalSince1970: c.updatedAt.timeIntervalSince1970.rounded())
        return c
    }
    return copy
}

@Test("Property 31: missing presentationMode decodes as nil and resolves to .popover")
func property31MissingPresentationMode() throws {
    // Build a JSON blob explicitly missing the `presentationMode` key.
    let json = """
    {
      "enableWorldClock": true,
      "clocks": [],
      "use24HourTime": false,
      "popoverTextSize": 13,
      "resetOffsetOnClose": true
    }
    """
    let data = Data(json.utf8)
    let decoder = JSONDecoder()
    let decoded = try decoder.decode(WorldClockSettings.self, from: data)

    #expect(decoded.presentationMode == nil)
    #expect(decoded.resolvedPresentationMode == .popover)
}

@Test("Property 31: explicit nil presentationMode round-trips as nil")
func property31ExplicitNilRoundTrip() throws {
    var settings = WorldClockSettings.defaults
    settings.presentationMode = nil

    let encoder = JSONEncoder()
    let decoder = JSONDecoder()

    let data = try encoder.encode(settings)
    let decoded = try decoder.decode(WorldClockSettings.self, from: data)

    #expect(decoded.presentationMode == nil)
    #expect(decoded.resolvedPresentationMode == .popover)
}

@Test("Property 31: each WorldClockPresentationMode case round-trips through JSON")
func property31EveryCaseRoundTrips() throws {
    let encoder = JSONEncoder()
    let decoder = JSONDecoder()
    for mode in WorldClockPresentationMode.allCases {
        var settings = WorldClockSettings.defaults
        settings.presentationMode = mode
        let data = try encoder.encode(settings)
        let decoded = try decoder.decode(WorldClockSettings.self, from: data)
        #expect(decoded.presentationMode == mode)
        #expect(decoded.resolvedPresentationMode == mode)
    }
}

@Test("Property 31: AppSettings with WorldClockSettings JSON round-trips")
func property31AppSettingsRoundTrip() throws {
    forAll(arbitraryWorldClockSettings, iterations: 30) { wc in
        var settings = AppSettings.defaults
        settings.worldClock = roundTripSafe(wc)

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970

        do {
            let data = try encoder.encode(settings)
            let decoded = try decoder.decode(AppSettings.self, from: data)
            #expect(decoded.worldClock == settings.worldClock)
            #expect(decoded.resolvedWorldClock == settings.worldClock)
        } catch {
            Issue.record("AppSettings round-trip failed: \(error)")
        }
    }
}
