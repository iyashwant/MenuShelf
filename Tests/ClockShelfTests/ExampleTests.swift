//
//  ExampleTests.swift
//  ClockShelfTests
//
//  Example-based tests for the EXAMPLE-classified acceptance criteria
//  from the Clock Shelf spec. Each `@Test` covers one criterion that can
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

@Test("MenuViewConfig.make().clockShelfItem == nil")
func freshMenuViewHasNoClockShelfItem() {
    let view = MenuViewConfig.make()
    #expect(view.clockShelfItem == nil)
}

// MARK: - ClockShelfMenuItemConfig fallback

@Test("ClockShelfMenuItemConfig.displayTitle falls back to \"Clock Shelf\"")
func menuItemDisplayTitleFallback() {
    let item = ClockShelfMenuItemConfig.make()
    #expect(item.titleOverride == nil)
    #expect(item.displayTitle == "Clock Shelf")
}

@Test("ClockShelfMenuItemConfig.displayTitle falls back when whitespace-only override")
func menuItemDisplayTitleFallbackWhitespace() {
    var item = ClockShelfMenuItemConfig.make()
    item.titleOverride = "   "
    #expect(item.displayTitle == "Clock Shelf")
}

@Test("ClockShelfMenuItemConfig.displayTitle returns trimmed override when set")
func menuItemDisplayTitleTrimmed() {
    var item = ClockShelfMenuItemConfig.make()
    item.titleOverride = "  My Clocks  "
    #expect(item.displayTitle == "My Clocks")
}

// MARK: - ClockShelfSettings.defaults

@Test("ClockShelfSettings.defaults exact field values")
func clockShelfDefaultsFieldValues() {
    let defaults = ClockShelfSettings.defaults
    #expect(defaults.enableClockShelf == false)
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

@Test("AppSettings.defaults.clockShelf matches ClockShelfSettings.defaults")
func appSettingsDefaultsClockShelf() {
    #expect(AppSettings.defaults.clockShelf == ClockShelfSettings.defaults)
    #expect(AppSettings.defaults.resolvedClockShelf == ClockShelfSettings.defaults)
}

// MARK: - ClockShelfPresentationMode

@Test("ClockShelfPresentationMode.allCases.count == 2")
func presentationModeCaseCount() {
    #expect(ClockShelfPresentationMode.allCases.count == 2)
    #expect(ClockShelfPresentationMode.allCases.contains(.popover))
    #expect(ClockShelfPresentationMode.allCases.contains(.submenu))
}

@Test("ClockShelfPresentationMode rendered labels")
func presentationModeLabels() {
    #expect(ClockShelfPresentationMode.popover.label == "Popover")
    #expect(ClockShelfPresentationMode.submenu.label == "Submenu")
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
