//
//  PropertyTesting.swift
//  ClockShelfTests
//
//  Minimal in-tree property-based testing harness for the Clock Shelf
//  module. Mirrors the shape pinned by the design's *Testing Strategy*:
//  swift-testing's `@Test` for example-based assertions plus a tiny
//  `forAll` helper backed by `SystemRandomNumberGenerator` for
//  property-based assertions. Each property test is expected to run at
//  least 100 iterations.
//
//  No external dependency is introduced — every generator is a thin
//  wrapper over Foundation primitives.
//

import Foundation
@testable import MenuShelf

// MARK: - Generator protocol and adapters

/// A pure-Swift generator that produces values of `Value` from a
/// caller-supplied random source. Matches the shape pinned by the
/// design's Testing Strategy table.
protocol Generator<Value> {
    associatedtype Value
    func generate(using rng: inout SystemRandomNumberGenerator) -> Value
}

/// Type-erased generator so module-level generator constants can be
/// expressed as plain values.
struct AnyGenerator<Value>: Generator {
    private let _generate: (inout SystemRandomNumberGenerator) -> Value

    init(_ generate: @escaping (inout SystemRandomNumberGenerator) -> Value) {
        self._generate = generate
    }

    func generate(using rng: inout SystemRandomNumberGenerator) -> Value {
        _generate(&rng)
    }
}

// MARK: - forAll helper

/// Default iteration count. Property tests run at least 100 iterations
/// per the design's Testing Strategy section.
let defaultPropertyIterations = 100

/// Runs `assertion` against `iterations` independently generated values.
/// The harness is deliberately minimal: any failure in `assertion`
/// (including swift-testing's `#expect`/`#require` traps) propagates
/// immediately, surfacing the offending value through whatever assertion
/// mechanism the caller used.
func forAll<G: Generator>(
    _ generator: G,
    iterations: Int = defaultPropertyIterations,
    _ assertion: (G.Value) throws -> Void
) rethrows {
    var rng = SystemRandomNumberGenerator()
    for _ in 0..<iterations {
        let value = generator.generate(using: &rng)
        try assertion(value)
    }
}

// MARK: - Generator helpers

private let knownTimeZoneIdentifiers: [String] = TimeZone.knownTimeZoneIdentifiers

/// A small, deliberately diverse set of single-grapheme emoji used to
/// exercise label rendering and the diagnostics PII boundary.
private let arbitraryEmojiAlphabet: [String] = [
    "🌍", "🌎", "🌏", "🕐", "🕑", "🕒", "🕓", "⏰", "⌚️",
    "🌞", "🌜", "🌝", "🌚", "✨", "⭐️"
]

/// Characters drawn from to compose `arbitraryString`. Includes ASCII
/// letters, digits, spaces, and a handful of accented characters so
/// trim-on-write and Unicode round-trips both get exercised.
private let arbitraryStringAlphabet: [Character] = Array(
    "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789 -_éñü"
)

private func randomElement<T>(
    of array: [T],
    using rng: inout SystemRandomNumberGenerator
) -> T {
    // Precondition: array is non-empty. All call sites pass static,
    // non-empty alphabets.
    let index = Int.random(in: 0..<array.count, using: &rng)
    return array[index]
}

private func randomBool(using rng: inout SystemRandomNumberGenerator) -> Bool {
    Bool.random(using: &rng)
}

private func randomInt(
    in range: ClosedRange<Int>,
    using rng: inout SystemRandomNumberGenerator
) -> Int {
    Int.random(in: range, using: &rng)
}

private func randomDouble(
    in range: ClosedRange<Double>,
    using rng: inout SystemRandomNumberGenerator
) -> Double {
    Double.random(in: range, using: &rng)
}

/// Generates a string of length `0...maxLength`. With ~25% probability
/// the string is whitespace-only so generators exercise the trim path.
private func arbitraryString(
    maxLength: Int = 16,
    using rng: inout SystemRandomNumberGenerator
) -> String {
    let length = randomInt(in: 0...maxLength, using: &rng)
    let whitespaceOnly = randomInt(in: 0...3, using: &rng) == 0
    if whitespaceOnly {
        return String(repeating: " ", count: length)
    }
    var characters: [Character] = []
    characters.reserveCapacity(length)
    for _ in 0..<length {
        characters.append(randomElement(of: arbitraryStringAlphabet, using: &rng))
    }
    return String(characters)
}

/// Returns a known IANA identifier from the Foundation database.
private func arbitraryTimeZoneIdentifier(
    using rng: inout SystemRandomNumberGenerator
) -> String {
    randomElement(of: knownTimeZoneIdentifiers, using: &rng)
}

/// Returns a random emoji ~70% of the time, otherwise `nil`.
private func arbitraryOptionalEmoji(
    using rng: inout SystemRandomNumberGenerator
) -> String? {
    let drop = randomInt(in: 0...9, using: &rng) < 3
    if drop { return nil }
    return randomElement(of: arbitraryEmojiAlphabet, using: &rng)
}

/// Returns an arbitrary `Date` within ±10 years of the reference epoch
/// (2001-01-01). Generators don't rely on real wall-clock time.
private func arbitraryDate(
    using rng: inout SystemRandomNumberGenerator
) -> Date {
    let tenYears: TimeInterval = 10 * 365 * 24 * 3600
    let offset = randomDouble(in: -tenYears...tenYears, using: &rng)
    return Date(timeIntervalSinceReferenceDate: offset)
}

// MARK: - arbitraryClockConfig

/// Generates a `ClockConfig` drawn from
/// `(UUID, knownTimeZoneIdentifiers, randomString, randomEmoji?, Bool,
/// Bool, Int)`. `label` includes whitespace-only strings to exercise
/// the trim path; `emoji` covers a representative set of single-grapheme
/// emoji.
let arbitraryClockConfig: AnyGenerator<ClockConfig> = AnyGenerator { rng in
    let label = arbitraryString(using: &rng)
    let emoji = arbitraryOptionalEmoji(using: &rng)
    return ClockConfig(
        id: UUID(),
        timeZoneIdentifier: arbitraryTimeZoneIdentifier(using: &rng),
        label: label.isEmpty ? nil : label,
        emoji: emoji,
        pinToMenuBar: randomBool(using: &rng),
        showInPopover: randomBool(using: &rng),
        sortOrder: randomInt(in: 0...64, using: &rng),
        createdAt: arbitraryDate(using: &rng),
        updatedAt: arbitraryDate(using: &rng)
    )
}

// MARK: - arbitraryClockShelfSettings

/// Generates a `ClockShelfSettings` drawn from
/// `Bool × [arbitraryClockConfig] (≤32) × Bool × Int (11..22) × Bool`.
/// The 32-clock cap is enforced at construction so generators never
/// violate cardinality.
let arbitraryClockShelfSettings: AnyGenerator<ClockShelfSettings> = AnyGenerator { rng in
    let count = randomInt(in: 0...32, using: &rng)
    var clocks: [ClockConfig] = []
    clocks.reserveCapacity(count)
    for index in 0..<count {
        var clock = arbitraryClockConfig.generate(using: &rng)
        clock.sortOrder = index
        clocks.append(clock)
    }
    // ~10% of the time emit `nil` for `presentationMode` so Property 31's
    // forward-decode branch gets exercised.
    let presentationMode: ClockShelfPresentationMode?
    let drop = randomInt(in: 0...9, using: &rng) == 0
    if drop {
        presentationMode = nil
    } else {
        presentationMode = randomBool(using: &rng) ? .popover : .submenu
    }
    return ClockShelfSettings(
        enableClockShelf: randomBool(using: &rng),
        clocks: clocks,
        use24HourTime: randomBool(using: &rng),
        popoverTextSize: randomInt(in: 11...22, using: &rng),
        resetOffsetOnClose: randomBool(using: &rng),
        presentationMode: presentationMode
    )
}

// MARK: - arbitraryAppSettingsPreV14

/// Generates an `AppSettings` value with `schemaVersion ∈ {1..13}` and a
/// random subset of optional fields nilled. Used by Property 30 to drive
/// `PreferencesStore.migratedSettings(_:)`.
let arbitraryAppSettingsPreV14: AnyGenerator<AppSettings> = AnyGenerator { rng in
    var settings = AppSettings.defaults
    settings.schemaVersion = randomInt(in: 1...13, using: &rng)

    // Each optional field is independently retained or nilled with even
    // probability so the migration ladder sees a representative mix.
    if randomBool(using: &rng) { settings.menuViews = nil }
    if randomBool(using: &rng) { settings.showFileAndFolderIcons = nil }
    if randomBool(using: &rng) { settings.showFileSubmenus = nil }
    if randomBool(using: &rng) { settings.showFolderSubmenus = nil }
    if randomBool(using: &rng) { settings.shortcutOpenLocation = nil }
    if randomBool(using: &rng) { settings.showTopLevelFolderIcons = nil }
    if randomBool(using: &rng) { settings.topLevelFolderIconSize = nil }
    if randomBool(using: &rng) { settings.moreMenuBehavior = nil }
    if randomBool(using: &rng) { settings.enableVerboseDiagnostics = nil }
    if randomBool(using: &rng) { settings.appleScripts = nil }
    if randomBool(using: &rng) { settings.browserFlip = nil }
    if randomBool(using: &rng) { settings.clipboardShelf = nil }
    if randomBool(using: &rng) { settings.clockShelf = nil }
    if randomBool(using: &rng) { settings.showRootFolderManagementItems = nil }

    return settings
}

// MARK: - arbitraryClockOperation

/// A test-only operation algebra over a clock list. Property 8 sequences
/// these to verify that `add`, `remove`, `move`, and `update` keep
/// `sortOrder` contiguous and zero-based.
enum ClockOperation: Equatable {
    case add(timeZoneIdentifier: String)
    case remove(id: UUID)
    case move(fromOffsets: IndexSet, toOffset: Int)
    case update(ClockConfig)
}

/// Generates one of the four operations. `remove` and `update` use
/// freshly-minted UUIDs unless interpreted by the test against a
/// concrete pre-state; tests are responsible for mapping the
/// operation onto an actual list.
let arbitraryClockOperation: AnyGenerator<ClockOperation> = AnyGenerator { rng in
    switch randomInt(in: 0...3, using: &rng) {
    case 0:
        return .add(timeZoneIdentifier: arbitraryTimeZoneIdentifier(using: &rng))
    case 1:
        return .remove(id: UUID())
    case 2:
        let from = IndexSet(integer: randomInt(in: 0...8, using: &rng))
        let to = randomInt(in: 0...9, using: &rng)
        return .move(fromOffsets: from, toOffset: to)
    default:
        return .update(arbitraryClockConfig.generate(using: &rng))
    }
}

// MARK: - arbitraryOffset

/// Generates a `TimeInterval` in `[-2 * 86400, +2 * 86400]`. The range
/// is deliberately wider than the controller's allowed `[-86400,
/// +86400]` so Property 18 exercises the clamp path.
let arbitraryOffset: AnyGenerator<TimeInterval> = AnyGenerator { rng in
    let twoDays: TimeInterval = 2 * 86400
    return randomDouble(in: -twoDays...twoDays, using: &rng)
}
