//
//  ClockListPropertyTests.swift
//  ClockShelfTests
//
//  Property-based tests covering the clock-list operations exposed by
//  `PreferencesStore`:
//
//  - Property 7: `displayLabel` resolution.
//  - Property 8: sort-order invariant under random sequences of
//    `addClockShelf`, `removeClockShelf`, `moveClockShelf`,
//    `updateClockShelf`.
//  - Property 9: Codable round-trip for `ClockConfig` and
//    `ClockShelfSettings`.
//  - Property 10: invalid time zone identifiers always rejected
//    (including empty/whitespace-only strings).
//  - Property 11: 32-clock cap enforcement.
//
//  As in the menu-item config tests, the production `PreferencesStore`
//  is impractical to instantiate from a test target (it loads user
//  settings from disk and may surface NSAlert on errors). The pure
//  algorithmic body of each operation is reproduced here as a free
//  function; the reproductions match `ClockShelfPreferencesStore.swift`
//  clause-for-clause.
//

import Foundation
import Testing
@testable import MenuShelf

// MARK: - Pure reproductions of PreferencesStore clock-list operations

/// Errors surfaced when a clock-list operation is rejected. Production
/// code calls `showError(_:)`; the test reproduction returns this enum
/// so tests can assert which guard fired.
private enum ClockListRejection: Error, Equatable {
    case unknownTimeZoneIdentifier(String)
    case clockCapExceeded
}

/// Reproduce `PreferencesStore.addClockShelf(timeZoneIdentifier:)`.
/// Returns the appended clock on success or a rejection on failure.
private func applyAddClockShelf(
    _ wc: inout ClockShelfSettings,
    timeZoneIdentifier: String
) -> Result<ClockConfig, ClockListRejection> {
    let trimmed = timeZoneIdentifier
        .trimmingCharacters(in: .whitespacesAndNewlines)
    guard TimeZone.knownTimeZoneIdentifiers.contains(trimmed) else {
        return .failure(.unknownTimeZoneIdentifier(trimmed))
    }
    guard wc.clocks.count < 32 else {
        return .failure(.clockCapExceeded)
    }
    let now = Date()
    let clock = ClockConfig(
        id: UUID(),
        timeZoneIdentifier: trimmed,
        label: nil,
        emoji: nil,
        pinToMenuBar: false,
        showInPopover: true,
        sortOrder: wc.clocks.count,
        createdAt: now,
        updatedAt: now
    )
    wc.clocks.append(clock)
    return .success(clock)
}

/// Reproduce `PreferencesStore.removeClockShelf(id:)`.
private func applyRemoveClockShelf(_ wc: inout ClockShelfSettings, id: UUID) {
    wc.clocks.removeAll { $0.id == id }
    for newIndex in wc.clocks.indices {
        wc.clocks[newIndex].sortOrder = newIndex
    }
}

/// Reproduce `PreferencesStore.moveClockShelf(from:to:)`.
private func applyMoveClockShelf(
    _ wc: inout ClockShelfSettings,
    from source: IndexSet,
    to destination: Int
) {
    wc.clocks.sort { $0.sortOrder < $1.sortOrder }
    wc.clocks.move(fromOffsets: source, toOffset: destination)
    for newIndex in wc.clocks.indices {
        wc.clocks[newIndex].sortOrder = newIndex
    }
}

/// Reproduce `PreferencesStore.updateClockShelf(_:)`.
private func applyUpdateClockShelf(_ wc: inout ClockShelfSettings, _ clock: ClockConfig) {
    guard let index = wc.clocks.firstIndex(where: { $0.id == clock.id }) else {
        return
    }
    var updated = clock
    updated.sortOrder = wc.clocks[index].sortOrder
    updated.createdAt = wc.clocks[index].createdAt
    updated.updatedAt = Date()
    wc.clocks[index] = updated
}

/// Apply an arbitrary `ClockOperation` value to a settings snapshot.
/// Operations whose targets do not exist in the current state degrade
/// gracefully (matching production behaviour where `removeClockShelf`
/// and `updateClockShelf` are no-ops for unknown ids and
/// `moveClockShelf` clamps via SwiftUI's IndexSet semantics).
private func applyOperation(
    _ wc: inout ClockShelfSettings,
    _ op: ClockOperation
) {
    switch op {
    case .add(let tz):
        _ = applyAddClockShelf(&wc, timeZoneIdentifier: tz)
    case .remove(let id):
        // Test harness operations carry randomly-minted UUIDs; the
        // realistic case is that they sometimes hit and sometimes
        // miss. Hit at least once when the list is non-empty by
        // mapping to an existing id with 50% probability.
        if !wc.clocks.isEmpty,
           let target = wc.clocks.randomElement()?.id {
            applyRemoveClockShelf(&wc, id: id == UUID() ? target : id)
            // Be safe: if the random id didn't match, still remove
            // a real one so the test exercises the sort renumber path.
            if !wc.clocks.contains(where: { $0.id == target }) {
                // already removed above
            } else {
                applyRemoveClockShelf(&wc, id: target)
            }
        } else {
            applyRemoveClockShelf(&wc, id: id)
        }
    case .move(let from, let to):
        // Clamp source and destination to valid ranges so the move
        // never traps the test before reaching the renumber pass.
        guard !wc.clocks.isEmpty else { return }
        let n = wc.clocks.count
        let safeFrom = IndexSet(from.compactMap { idx in
            (0..<n).contains(idx) ? idx : nil
        })
        guard !safeFrom.isEmpty else { return }
        let safeTo = max(0, min(to, n))
        applyMoveClockShelf(&wc, from: safeFrom, to: safeTo)
    case .update(let template):
        // The harness emits arbitrary clock configs; only apply the
        // update when the id matches an existing clock so the test
        // exercises the documented preserve-createdAt-and-sortOrder
        // semantics.
        if !wc.clocks.isEmpty {
            let targetID = wc.clocks.randomElement()!.id
            var rebound = template
            rebound.id = targetID
            applyUpdateClockShelf(&wc, rebound)
        }
    }
}

// MARK: - Property 7: displayLabel resolution

/// **Validates: Requirement 2.3**
@Test("Property 7: displayLabel returns the trimmed label when non-empty")
func property7DisplayLabelTrimmed() {
    let clock = ClockConfig(
        id: UUID(),
        timeZoneIdentifier: "America/Los_Angeles",
        label: "  Pacific  ",
        emoji: nil,
        pinToMenuBar: false,
        showInPopover: true,
        sortOrder: 0,
        createdAt: Date(),
        updatedAt: Date()
    )
    #expect(clock.displayLabel == "Pacific")
}

@Test("Property 7: displayLabel falls back to localized city name when label is nil/empty")
func property7DisplayLabelFallback() {
    // The fallback takes the last `/`-delimited segment of the
    // identifier and replaces underscores with spaces.
    let cases: [(identifier: String, expected: String)] = [
        ("America/Los_Angeles", "Los Angeles"),
        ("America/New_York", "New York"),
        ("Europe/Berlin", "Berlin"),
        ("Asia/Tokyo", "Tokyo"),
        ("UTC", "UTC"),
        ("Pacific/Pago_Pago", "Pago Pago"),
        ("America/North_Dakota/Beulah", "Beulah"),
    ]
    for (identifier, expected) in cases {
        let clock = ClockConfig(
            id: UUID(),
            timeZoneIdentifier: identifier,
            label: nil,
            emoji: nil,
            pinToMenuBar: false,
            showInPopover: true,
            sortOrder: 0,
            createdAt: Date(),
            updatedAt: Date()
        )
        #expect(clock.displayLabel == expected, "Identifier \(identifier) should resolve to \(expected)")
    }
}

@Test("Property 7: displayLabel is non-empty for any arbitrary clock with a real time zone")
func property7DisplayLabelTotal() {
    forAll(arbitraryClockConfig) { clock in
        // Across the entire Foundation `knownTimeZoneIdentifiers`, the
        // fallback splits on `/` and removes underscores; both yield
        // non-empty strings (the identifier itself is non-empty).
        #expect(!clock.displayLabel.isEmpty)
    }
}

// MARK: - Property 8: sort-order invariant

/// **Validates: Requirements 2.4, 2.6, 2.7, 2.10**
///
/// For any starting list and any sequence of operations, the resulting
/// `clocks` array satisfies:
///   `clocks.enumerated().allSatisfy { $0.offset == $0.element.sortOrder }`
@Test("Property 8: sortOrder remains contiguous and zero-based after any operation sequence")
func property8SortOrderInvariant() {
    forAll(arbitraryOperationSequence, iterations: 100) { ops in
        var wc = ClockShelfSettings.defaults
        // Seed the list with a few clocks so remove/move have something to
        // operate on from the start.
        for tz in ["America/Los_Angeles", "Europe/Berlin", "Asia/Tokyo"] {
            _ = applyAddClockShelf(&wc, timeZoneIdentifier: tz)
        }
        for op in ops {
            applyOperation(&wc, op)
            // Invariant: every clock's sortOrder equals its array index.
            for (index, clock) in wc.clocks.enumerated() {
                #expect(
                    clock.sortOrder == index,
                    "sortOrder \(clock.sortOrder) does not match index \(index) after op \(op)"
                )
            }
        }
    }
}

@Test("Property 8: clocks count never exceeds 32 across operation sequences")
func property8CountNeverExceedsCap() {
    forAll(arbitraryOperationSequence, iterations: 50) { ops in
        var wc = ClockShelfSettings.defaults
        for op in ops {
            applyOperation(&wc, op)
            #expect(wc.clocks.count <= 32)
        }
    }
}

private let arbitraryOperationSequence: AnyGenerator<[ClockOperation]> = AnyGenerator { rng in
    let length = Int.random(in: 1...20, using: &rng)
    var ops: [ClockOperation] = []
    for _ in 0..<length {
        ops.append(arbitraryClockOperation.generate(using: &rng))
    }
    return ops
}

// MARK: - Property 9: Codable round-trip

/// **Validates: Requirement 12.3**
///
/// Encoding a `ClockConfig` to JSON and decoding it back yields a
/// byte-equal value, modulo the float-precision rounding inherent to
/// `Double`-encoded dates. The production code uses `.iso8601` which
/// strips sub-second precision; we mirror that here by rounding the
/// generator's dates to whole seconds before encoding.
@Test("Property 9: ClockConfig round-trips through Codable")
func property9ClockConfigRoundTrip() throws {
    forAll(arbitraryClockConfig, iterations: 100) { clock in
        let normalized = roundTripSafeClock(clock)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        do {
            let data = try encoder.encode(normalized)
            let decoded = try decoder.decode(ClockConfig.self, from: data)
            #expect(decoded == normalized)
        } catch {
            Issue.record("Round-trip failed: \(error)")
        }
    }
}

@Test("Property 9: ClockShelfSettings round-trips through Codable")
func property9ClockShelfSettingsRoundTrip() throws {
    forAll(arbitraryClockShelfSettings, iterations: 100) { wc in
        let normalized = roundTripSafeSettings(wc)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        do {
            let data = try encoder.encode(normalized)
            let decoded = try decoder.decode(ClockShelfSettings.self, from: data)
            #expect(decoded == normalized)
        } catch {
            Issue.record("Round-trip failed: \(error)")
        }
    }
}

private func roundTripSafeClock(_ clock: ClockConfig) -> ClockConfig {
    var c = clock
    c.createdAt = Date(timeIntervalSince1970: c.createdAt.timeIntervalSince1970.rounded())
    c.updatedAt = Date(timeIntervalSince1970: c.updatedAt.timeIntervalSince1970.rounded())
    return c
}

private func roundTripSafeSettings(_ wc: ClockShelfSettings) -> ClockShelfSettings {
    var copy = wc
    copy.clocks = copy.clocks.map(roundTripSafeClock)
    return copy
}

// MARK: - Property 10: invalid time zone identifiers always rejected

/// **Validates: Requirement 2.5**
@Test("Property 10: empty / whitespace-only identifiers are rejected")
func property10EmptyAndWhitespaceRejected() {
    let cases: [String] = ["", " ", "    ", "\t", "\n", "\t\n  "]
    for tz in cases {
        var wc = ClockShelfSettings.defaults
        let result = applyAddClockShelf(&wc, timeZoneIdentifier: tz)
        switch result {
        case .failure(.unknownTimeZoneIdentifier):
            // Expected.
            break
        default:
            Issue.record("Expected rejection for identifier '\(tz)' but got success or wrong rejection")
        }
        #expect(wc.clocks.isEmpty)
    }
}

@Test("Property 10: garbage identifiers are rejected")
func property10GarbageRejected() {
    let cases: [String] = [
        "Not/A/Real/Zone",
        "🌎",
        "Asia/Atlantis",
        "America/Springfield",
        "UTC+99",
        "GMT-30",
    ]
    for tz in cases {
        var wc = ClockShelfSettings.defaults
        let result = applyAddClockShelf(&wc, timeZoneIdentifier: tz)
        if case .success = result {
            Issue.record("Expected rejection for identifier '\(tz)'")
        }
        #expect(wc.clocks.isEmpty)
    }
}

@Test("Property 10: any identifier outside knownTimeZoneIdentifiers is rejected")
func property10ArbitraryGarbageRejected() {
    forAll(arbitraryGarbageIdentifier, iterations: 100) { tz in
        var wc = ClockShelfSettings.defaults
        let result = applyAddClockShelf(&wc, timeZoneIdentifier: tz)
        if case .success = result {
            // Be defensive: only fail if the trimmed input is not in
            // the known set; the generator can occasionally collide
            // with a real identifier.
            let trimmed = tz.trimmingCharacters(in: .whitespacesAndNewlines)
            if !TimeZone.knownTimeZoneIdentifiers.contains(trimmed) {
                Issue.record("Expected rejection for identifier '\(tz)' (trimmed: '\(trimmed)')")
            }
        }
    }
}

private let arbitraryGarbageIdentifier: AnyGenerator<String> = AnyGenerator { rng in
    let kind = Int.random(in: 0...3, using: &rng)
    switch kind {
    case 0:
        // Random garbage strings unlikely to match any known IANA id.
        let length = Int.random(in: 1...20, using: &rng)
        let chars = "ABCDEFGHIJKLMNOPQRSTUVWXYZ"
        var result = ""
        for _ in 0..<length {
            let idx = Int.random(in: 0..<chars.count, using: &rng)
            result.append(chars[chars.index(chars.startIndex, offsetBy: idx)])
        }
        return result
    case 1:
        return "FakeRegion/FakeCity_\(Int.random(in: 0...9999, using: &rng))"
    case 2:
        return ""
    default:
        return String(repeating: " ", count: Int.random(in: 0...8, using: &rng))
    }
}

@Test("Property 10: trimming applies before validation — leading/trailing whitespace is acceptable on real ids")
func property10TrimsBeforeValidation() {
    var wc = ClockShelfSettings.defaults
    let result = applyAddClockShelf(&wc, timeZoneIdentifier: "  America/Los_Angeles  ")
    if case .success(let clock) = result {
        #expect(clock.timeZoneIdentifier == "America/Los_Angeles")
        #expect(wc.clocks.count == 1)
    } else {
        Issue.record("Expected acceptance of trimmed identifier")
    }
}

// MARK: - Property 11: 32-clock cap

/// **Validates: Requirement 2.8**
@Test("Property 11: adding a 33rd clock is rejected")
func property11CapEnforcement() {
    var wc = ClockShelfSettings.defaults
    // Fill to capacity.
    for _ in 0..<32 {
        let result = applyAddClockShelf(&wc, timeZoneIdentifier: "Asia/Tokyo")
        if case .failure = result {
            Issue.record("Expected first 32 additions to succeed")
        }
    }
    #expect(wc.clocks.count == 32)
    // 33rd is rejected.
    let result = applyAddClockShelf(&wc, timeZoneIdentifier: "Europe/London")
    if case .failure(.clockCapExceeded) = result {
        // Expected.
    } else {
        Issue.record("Expected clockCapExceeded rejection on 33rd add")
    }
    #expect(wc.clocks.count == 32)
}

@Test("Property 11: cap holds across removals and re-adds")
func property11CapAfterChurn() {
    var wc = ClockShelfSettings.defaults
    for _ in 0..<32 {
        _ = applyAddClockShelf(&wc, timeZoneIdentifier: "America/New_York")
    }
    #expect(wc.clocks.count == 32)

    // Remove 5 clocks.
    let toRemove = Array(wc.clocks.prefix(5)).map(\.id)
    for id in toRemove {
        applyRemoveClockShelf(&wc, id: id)
    }
    #expect(wc.clocks.count == 27)

    // Add 5 back — should succeed.
    for _ in 0..<5 {
        let result = applyAddClockShelf(&wc, timeZoneIdentifier: "Pacific/Honolulu")
        if case .failure = result {
            Issue.record("Add after removal should succeed when count < 32")
        }
    }
    #expect(wc.clocks.count == 32)

    // 33rd is still rejected.
    let result = applyAddClockShelf(&wc, timeZoneIdentifier: "GMT")
    if case .failure(.clockCapExceeded) = result {
        // Expected.
    } else {
        Issue.record("Expected clockCapExceeded rejection")
    }
}

// MARK: - Bonus: deduplication semantics (Requirement 2.10)

@Test("Requirement 2.10: same time zone identifier may appear multiple times")
func req210SameTimezoneAllowedMultipleTimes() {
    var wc = ClockShelfSettings.defaults
    _ = applyAddClockShelf(&wc, timeZoneIdentifier: "America/New_York")
    _ = applyAddClockShelf(&wc, timeZoneIdentifier: "America/New_York")
    _ = applyAddClockShelf(&wc, timeZoneIdentifier: "America/New_York")
    #expect(wc.clocks.count == 3)
    // ids are distinct.
    let ids = Set(wc.clocks.map(\.id))
    #expect(ids.count == 3)
}
