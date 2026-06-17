//
//  ExampleTests.swift
//  WorldClockTests
//
//  Example-based tests for the EXAMPLE-classified acceptance criteria
//  from the World Clock spec. Each `@Test` covers one criterion that can
//  be exercised directly from the `MenuShelf` module without spinning up
//  AppKit, NSStatusBar, KeyboardShortcuts, or any UI-bearing
//  infrastructure. Criteria that require running views (overflow menu
//  ordering, the slider's accessibility label, the Cmd+`+` binding, the
//  50ms `handleMenuAction(_:)` deferral) are tracked separately and
//  exercised via the runtime-bearing test files in tasks 12.4–12.10.
//

import Foundation
import Testing
@testable import MenuShelf

// MARK: - MenuViewConfig.make

@Test("MenuViewConfig.make().worldClockItem == nil")
func freshMenuViewHasNoWorldClockItem() {
    let view = MenuViewConfig.make()
    #expect(view.worldClockItem == nil)
}

// MARK: - WorldClockMenuItemConfig fallback

@Test("WorldClockMenuItemConfig.displayTitle falls back to \"World Clock\"")
func menuItemDisplayTitleFallback() {
    let item = WorldClockMenuItemConfig.make()
    #expect(item.titleOverride == nil)
    #expect(item.displayTitle == "World Clock")
}

@Test("WorldClockMenuItemConfig.displayTitle falls back when whitespace-only override")
func menuItemDisplayTitleFallbackWhitespace() {
    var item = WorldClockMenuItemConfig.make()
    item.titleOverride = "   "
    #expect(item.displayTitle == "World Clock")
}

@Test("WorldClockMenuItemConfig.displayTitle returns trimmed override when set")
func menuItemDisplayTitleTrimmed() {
    var item = WorldClockMenuItemConfig.make()
    item.titleOverride = "  My Clocks  "
    #expect(item.displayTitle == "My Clocks")
}

// MARK: - WorldClockSettings.defaults

@Test("WorldClockSettings.defaults exact field values")
func worldClockDefaultsFieldValues() {
    let defaults = WorldClockSettings.defaults
    #expect(defaults.enableWorldClock == false)
    #expect(defaults.clocks.isEmpty)
    #expect(defaults.use24HourTime == false)
    #expect(defaults.popoverTextSize == 13)
    #expect(defaults.resetOffsetOnClose == true)
    #expect(defaults.presentationMode == .popover)
    #expect(defaults.resolvedPresentationMode == .popover)
    #expect(defaults.resolvedPopoverTextSize == 13)
}

// MARK: - AppSettings.defaults schema version

@Test("AppSettings.defaults.schemaVersion == 14")
func appSettingsDefaultsSchemaVersion() {
    #expect(AppSettings.defaults.schemaVersion == 14)
}

@Test("AppSettings.defaults.worldClock matches WorldClockSettings.defaults")
func appSettingsDefaultsWorldClock() {
    #expect(AppSettings.defaults.worldClock == WorldClockSettings.defaults)
    #expect(AppSettings.defaults.resolvedWorldClock == WorldClockSettings.defaults)
}

// MARK: - WorldClockPresentationMode

@Test("WorldClockPresentationMode.allCases.count == 2")
func presentationModeCaseCount() {
    #expect(WorldClockPresentationMode.allCases.count == 2)
    #expect(WorldClockPresentationMode.allCases.contains(.popover))
    #expect(WorldClockPresentationMode.allCases.contains(.submenu))
}

@Test("WorldClockPresentationMode rendered labels")
func presentationModeLabels() {
    #expect(WorldClockPresentationMode.popover.label == "Popover")
    #expect(WorldClockPresentationMode.submenu.label == "Submenu")
}

// MARK: - timeTravelReadout

@Test("timeTravelReadout(0) == \"Now\"")
func readoutZero() {
    #expect(timeTravelReadout(0) == "Now")
}

@Test("timeTravelReadout(900) == \"+0:15\"")
func readoutPositive15Minutes() {
    #expect(timeTravelReadout(900) == "+0:15")
}

@Test("timeTravelReadout(-3600) == \"-1:00\"")
func readoutNegativeOneHour() {
    #expect(timeTravelReadout(-3600) == "-1:00")
}

@Test("timeTravelReadout(3600) == \"+1:00\"")
func readoutPositiveOneHour() {
    #expect(timeTravelReadout(3600) == "+1:00")
}

@Test("timeTravelReadout(-86400) == \"-24:00\"")
func readoutMinimumBound() {
    #expect(timeTravelReadout(-86_400) == "-24:00")
}

@Test("timeTravelReadout(86400) == \"+24:00\"")
func readoutMaximumBound() {
    #expect(timeTravelReadout(86_400) == "+24:00")
}

@Test("timeTravelReadout zero-pads minutes")
func readoutZeroPadding() {
    // 5 hours, 5 minutes = 18300 seconds, expect "+5:05" not "+5:5"
    #expect(timeTravelReadout(18_300) == "+5:05")
    // -2 hours, 0 minutes = -7200 seconds
    #expect(timeTravelReadout(-7_200) == "-2:00")
    // -45 minutes = -2700 seconds
    #expect(timeTravelReadout(-2_700) == "-0:45")
}
