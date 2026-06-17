//
//  CaffeineShelfModels.swift
//  MenuShelf
//
//  Standalone CaffeineShelf data models. CaffeineShelf keeps the Mac awake
//  using an IOKit power assertion (the same mechanism `/usr/bin/caffeinate`
//  uses internally), optionally for a fixed duration, with optional auto-off
//  on low battery or Low Power Mode. The hook into the broader settings tree
//  (`AppSettings.caffeineShelf`) stays inline in `AppModels.swift`.
//

import Foundation

// MARK: - CaffeineShelfSettings

/// Top-level CaffeineShelf settings persisted to MenuShelf's `settings.json`
/// under `AppSettings.caffeineShelf`.
struct CaffeineShelfSettings: Codable, Equatable {
    /// Master enable flag for the module. When `false` the controller releases
    /// any assertion and tears down its monitors.
    var enableCaffeineShelf: Bool

    /// When `true` the assertion only prevents *system* idle sleep and lets the
    /// display sleep (caffeinate `-i`). When `false` it also keeps the display
    /// awake (caffeinate `-di`).
    var allowDisplaySleep: Bool

    /// Duration applied when the user toggles "Keep Awake" on without picking a
    /// specific duration. `0` means indefinite (no auto-expiry).
    var defaultDurationSeconds: TimeInterval

    /// When `true`, an active session is automatically ended once the battery
    /// drops to or below `batteryThresholdPercent` while on battery power.
    var batteryAutoOffEnabled: Bool

    /// Battery percentage at or below which auto-off triggers. Clamped to
    /// `10...100` through `resolvedBatteryThresholdPercent`.
    var batteryThresholdPercent: Double

    /// When `true`, an active session is automatically ended when macOS Low
    /// Power Mode turns on.
    var lowPowerModeAutoOffEnabled: Bool

    /// When `true`, an active session also keeps the Mac awake with the lid
    /// closed (via the privileged `pmset disablesleep` flag). Optional so older
    /// persisted `caffeineShelf` objects still decode cleanly; read through
    /// `resolvedKeepAwakeWithLidClosed`.
    var keepAwakeWithLidClosed: Bool?

    static let defaults = CaffeineShelfSettings(
        enableCaffeineShelf: false,
        allowDisplaySleep: false,
        defaultDurationSeconds: 0,
        batteryAutoOffEnabled: false,
        batteryThresholdPercent: 20,
        lowPowerModeAutoOffEnabled: false,
        keepAwakeWithLidClosed: false
    )

    /// Battery threshold clamped to a sane `10...100` range so a stray slider
    /// value can never drive auto-off to fire constantly or never.
    var resolvedBatteryThresholdPercent: Double {
        min(max(batteryThresholdPercent, 10), 100)
    }

    /// Resolved lid-closed flag, defaulting to `false` for settings predating
    /// the feature.
    var resolvedKeepAwakeWithLidClosed: Bool {
        keepAwakeWithLidClosed ?? false
    }
}

// MARK: - CaffeineShelfDurationOption

/// One entry in the fixed duration list offered by the menu and the settings
/// default-duration picker. `seconds == 0` represents the indefinite option.
struct CaffeineShelfDurationOption: Identifiable, Equatable {
    /// Seconds the session should last; `0` means indefinite.
    let seconds: TimeInterval
    /// Short label used by the settings picker, e.g. "5 minutes" / "Indefinite".
    let shortLabel: String

    var id: Int { Int(seconds) }
    var isIndefinite: Bool { seconds == 0 }

    /// Label used for the menu row, e.g. "For 5 minutes" / "Indefinitely".
    var menuLabel: String {
        isIndefinite ? "Indefinitely" : "For \(shortLabel)"
    }

    /// The fixed set of durations, mirroring KeepingYouAwake's defaults.
    static let all: [CaffeineShelfDurationOption] = [
        CaffeineShelfDurationOption(seconds: 0, shortLabel: "Indefinite"),
        CaffeineShelfDurationOption(seconds: 5 * 60, shortLabel: "5 minutes"),
        CaffeineShelfDurationOption(seconds: 10 * 60, shortLabel: "10 minutes"),
        CaffeineShelfDurationOption(seconds: 15 * 60, shortLabel: "15 minutes"),
        CaffeineShelfDurationOption(seconds: 30 * 60, shortLabel: "30 minutes"),
        CaffeineShelfDurationOption(seconds: 60 * 60, shortLabel: "1 hour"),
        CaffeineShelfDurationOption(seconds: 2 * 60 * 60, shortLabel: "2 hours"),
        CaffeineShelfDurationOption(seconds: 5 * 60 * 60, shortLabel: "5 hours"),
    ]

    /// 5…55 minutes in 5-minute steps, for the Custom ▸ Minutes submenu.
    static let customMinutes: [CaffeineShelfDurationOption] =
        stride(from: 5, through: 55, by: 5).map { minutes in
            CaffeineShelfDurationOption(
                seconds: TimeInterval(minutes * 60),
                shortLabel: "\(minutes) minutes"
            )
        }

    /// 1…12 hours, for the Custom ▸ Hours submenu.
    static let customHours: [CaffeineShelfDurationOption] =
        (1...12).map { hours in
            CaffeineShelfDurationOption(
                seconds: TimeInterval(hours * 60 * 60),
                shortLabel: hours == 1 ? "1 hour" : "\(hours) hours"
            )
        }
}
