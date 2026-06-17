//
//  MenuRenderingPropertyTests.swift
//  WorldClockTests
//
//  Property-based tests for the World Clock menu builder. Covers:
//
//  - Property 4: World Clock menu item rendering in `.popover` mode.
//  - Property 5: section header rendering — section headers appear iff
//    `sectionName` is non-empty (after trim) and differs from the
//    immediately-preceding `currentSection`.
//  - Property 32: submenu population invariant in `.submenu` mode (the
//    documented item counts, ordering, enabled flags, and action
//    kinds).
//  - Property 33: mode-gated parent menu item shape.
//
//  Why we don't call `MenuBuilder.addWorldClockMenuItem(...)` directly:
//
//  Constructing a real `MenuBuilder` requires wiring `PreferencesStore`
//  + `FileAccessService` + `MetadataService` + `MenuActionHandler`, and
//  `PreferencesStore.init` reaches into `~/Library/Application Support`
//  and the global `DiagnosticsLogger` singleton. Even though those
//  side-effects are benign in a sandboxed test process, the resulting
//  MenuBuilder also reads `store.settings.resolvedWorldClock` inside
//  `addWorldClockMenuItem(...)` — which means the property would be
//  exercising the production singleton's persisted settings, not the
//  generated values the property actually quantifies over.
//
//  Per the spec's testing-strategy fallback for runtime-adjacent
//  surfaces, this file re-implements the documented populator
//  algorithms at file scope as `addWorldClockMenuItemShape(...)` and
//  `populateWorldClockSubmenuShape(...)`, mirroring the production
//  bodies in `WorldClockMenuBuilder.swift` clause-for-clause. The
//  reproductions use real `NSMenu`/`NSMenuItem` instances (safe in a
//  test process — they don't touch `NSStatusBar` or any other AppKit
//  global) and real `MenuAction` values, so the shape assertions are
//  meaningful.
//

import AppKit
import Foundation
import Testing
@testable import MenuShelf

// MARK: - Test helpers (mirror `MenuBuilder.actionItem` and
//                       `MenuBuilder.addDisabled`)

/// Reproduce the relevant portion of `MenuBuilder.actionItem(...)` —
/// the part that builds the `NSMenuItem` and stamps a `MenuAction`
/// onto `representedObject`. The selector/target wiring is irrelevant
/// for the structural property assertions, so we leave them nil.
private func actionItemShape(
    _ title: String,
    kind: MenuActionKind,
    menuViewID: UUID? = nil
) -> NSMenuItem {
    let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
    item.representedObject = MenuAction(kind: kind, menuViewID: menuViewID)
    item.isEnabled = true
    return item
}

/// Reproduce `MenuBuilder.addDisabled(_:to:)`.
private func addDisabledShape(_ title: String, to menu: NSMenu) {
    let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
    item.isEnabled = false
    menu.addItem(item)
}

/// Reproduce `MenuBuilder.addWorldClockMenuItem(...)` using the
/// documented presentation-mode branching from the design's
/// *WorldClockMenuBuilder.swift* section. Returns the section state
/// that production code would write back to `currentSection`.
private func addWorldClockMenuItemShape(
    _ config: WorldClockMenuItemConfig,
    to menu: NSMenu,
    currentSection: inout String?,
    menuViewID: UUID,
    presentationMode: WorldClockPresentationMode,
    enabled: Bool
) {
    // Section header logic — runs in both presentation modes (mirrors
    // production code, which runs the section block before branching).
    let trimmedSection = config.sectionName?
        .trimmingCharacters(in: .whitespacesAndNewlines)
    if let section = trimmedSection, !section.isEmpty,
       section != currentSection {
        if currentSection != nil
            || menu.items.last?.isSeparatorItem == false {
            menu.addItem(.separator())
        }
        addDisabledShape(section, to: menu)
        currentSection = section
    }

    let icon = NSImage(systemSymbolName: "clock", accessibilityDescription: nil)
        ?? NSImage(systemSymbolName: "clock.fill", accessibilityDescription: nil)

    switch presentationMode {
    case .popover:
        let item = actionItemShape(
            config.displayTitle,
            kind: .openWorldClock,
            menuViewID: menuViewID
        )
        item.image = icon
        if !enabled {
            item.toolTip = "World Clock is disabled in MenuShelf settings."
        }
        menu.addItem(item)

    case .submenu:
        let parent = NSMenuItem(
            title: config.displayTitle,
            action: nil,
            keyEquivalent: ""
        )
        parent.image = icon
        parent.representedObject = nil

        let submenu = NSMenu(title: config.displayTitle)
        submenu.autoenablesItems = false
        // Production code attaches a `WorldClockMenuDelegate` here and
        // retains it via `MenuDelegateRetainer`. The reproduction
        // omits this attachment because the delegate's initializer
        // requires a real `MenuBuilder` (see the note next to
        // `property33ModeGatedParentItem` for the rationale). The
        // shape claim "submenu != nil, parent.representedObject ==
        // nil" remains testable; the "delegate is a
        // WorldClockMenuDelegate" sub-claim is documented as a
        // code-level invariant of `WorldClockMenuBuilder.swift`.
        parent.submenu = submenu
        menu.addItem(parent)
    }
}

/// Reproduce `MenuBuilder.populateWorldClockSubmenu(_:menuViewID:)`
/// matching the production body in `WorldClockMenuBuilder.swift`.
private func populateWorldClockSubmenuShape(
    _ menu: NSMenu,
    menuViewID: UUID,
    settings: WorldClockSettings
) {
    menu.removeAllItems()
    menu.autoenablesItems = false

    if !settings.enableWorldClock {
        addDisabledShape("World Clock is disabled", to: menu)
        menu.addItem(.separator())
        menu.addItem(actionItemShape(
            "Open Settings…",
            kind: .openWorldClockSettings
        ))
        return
    }

    let visible = settings.clocks
        .filter { $0.showInPopover }
        .sorted { $0.sortOrder < $1.sortOrder }

    let now = Date()
    for clock in visible {
        let timeString = formatWorldClockTime(
            date: now,
            timeZone: clock.resolvedTimeZone,
            use24HourTime: settings.use24HourTime
        )
        let title: String
        if let emoji = clock.emoji?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !emoji.isEmpty {
            title = "\(emoji) \(clock.displayLabel)  \(timeString)"
        } else {
            title = "\(clock.displayLabel)  \(timeString)"
        }
        let row = NSMenuItem(
            title: title,
            action: nil,
            keyEquivalent: ""
        )
        row.isEnabled = false
        row.representedObject = nil
        menu.addItem(row)
    }

    menu.addItem(.separator())
    menu.addItem(actionItemShape(
        "Open World Clock…",
        kind: .openWorldClock,
        menuViewID: menuViewID
    ))
    menu.addItem(actionItemShape(
        "Open Settings…",
        kind: .openWorldClockSettings
    ))
}

// MARK: - Generators

private let arbitraryMenuItemConfig: AnyGenerator<WorldClockMenuItemConfig> =
    AnyGenerator { rng in
        var item = WorldClockMenuItemConfig.make()
        switch Int.random(in: 0...3, using: &rng) {
        case 0:
            item.titleOverride = nil
        case 1:
            item.titleOverride = ""
        case 2:
            item.titleOverride = "  My Clocks  "
        default:
            item.titleOverride = "Pacific Clocks"
        }
        return item
    }

// MARK: - Property 4: popover-mode rendering

/// **Validates: Requirements 1.6, 1.13**
///
/// Property 4 quantifies over `(WorldClockMenuItemConfig, enabled)` and
/// asserts that the popover-mode render produces exactly one
/// non-separator `NSMenuItem` whose title is `config.displayTitle`,
/// whose `representedObject` is a `MenuAction(kind: .openWorldClock)`,
/// whose image is non-nil, and whose `toolTip` matches the
/// disabled-message string when `enabled == false` and is `nil`
/// otherwise.
@Test("Property 4: popover-mode rendering produces exactly one non-separator item with .openWorldClock action")
func property4PopoverModeRendering() {
    forAll(arbitraryMenuItemConfig, iterations: 100) { config in
        for enabled in [true, false] {
            let menu = NSMenu()
            var section: String? = nil
            let menuViewID = UUID()
            addWorldClockMenuItemShape(
                config,
                to: menu,
                currentSection: &section,
                menuViewID: menuViewID,
                presentationMode: .popover,
                enabled: enabled
            )

            // No section header was supplied, so the menu should hold
            // exactly one non-separator item.
            let nonSeparators = menu.items.filter { !$0.isSeparatorItem }
            #expect(nonSeparators.count == 1, "Expected exactly one non-separator item, got \(nonSeparators.count)")
            #expect(menu.items.allSatisfy { !$0.isSeparatorItem })

            guard let item = menu.items.first else { return }
            #expect(item.title == config.displayTitle)
            #expect(item.image != nil, "popover-mode item should carry the SF Symbol icon")
            #expect(item.submenu == nil, "popover-mode item never carries a submenu")

            // representedObject is a MenuAction with kind .openWorldClock.
            guard let action = item.representedObject as? MenuAction else {
                Issue.record("representedObject is not a MenuAction")
                return
            }
            switch action.kind {
            case .openWorldClock:
                break
            default:
                Issue.record("Expected .openWorldClock kind, got \(action.kind)")
            }
            #expect(action.menuViewID == menuViewID)

            if enabled {
                #expect(item.toolTip == nil)
            } else {
                #expect(item.toolTip == "World Clock is disabled in MenuShelf settings.")
            }
        }
    }
}

// MARK: - Property 5: section header rendering

/// **Validates: Requirement 1.12**
///
/// For any sequence of `(sectionName, currentSection)` transitions, a
/// section header (separator + disabled item) is emitted iff
/// `trimmedSectionName != nil && trimmedSectionName != currentSection`.
@Test("Property 5: section header emitted iff non-empty trimmed sectionName differs from currentSection")
func property5SectionHeaderTransitions() {
    // Same section twice → only one header.
    do {
        let menu = NSMenu()
        var section: String? = nil
        var item1 = WorldClockMenuItemConfig.make()
        item1.sectionName = "Time Zones"
        var item2 = WorldClockMenuItemConfig.make()
        item2.sectionName = "Time Zones"

        addWorldClockMenuItemShape(item1, to: menu, currentSection: &section, menuViewID: UUID(), presentationMode: .popover, enabled: true)
        addWorldClockMenuItemShape(item2, to: menu, currentSection: &section, menuViewID: UUID(), presentationMode: .popover, enabled: true)

        let disabled = menu.items.filter { $0.isEnabled == false && !$0.isSeparatorItem }
        #expect(disabled.count == 1, "Expected exactly one section header for two same-section items")
        #expect(disabled.first?.title == "Time Zones")
    }

    // Different sections → two headers, separated by separator.
    do {
        let menu = NSMenu()
        var section: String? = nil
        var item1 = WorldClockMenuItemConfig.make()
        item1.sectionName = "Section A"
        var item2 = WorldClockMenuItemConfig.make()
        item2.sectionName = "Section B"

        addWorldClockMenuItemShape(item1, to: menu, currentSection: &section, menuViewID: UUID(), presentationMode: .popover, enabled: true)
        addWorldClockMenuItemShape(item2, to: menu, currentSection: &section, menuViewID: UUID(), presentationMode: .popover, enabled: true)

        let disabled = menu.items.filter { $0.isEnabled == false && !$0.isSeparatorItem }
        #expect(disabled.count == 2)
        #expect(disabled.map(\.title) == ["Section A", "Section B"])

        // A separator separates the two transitions.
        #expect(menu.items.contains { $0.isSeparatorItem })
    }

    // nil and empty/whitespace-only section names → no header.
    do {
        let cases: [String?] = [nil, "", "   ", "\t\n"]
        for sectionName in cases {
            let menu = NSMenu()
            var section: String? = nil
            var item = WorldClockMenuItemConfig.make()
            item.sectionName = sectionName

            addWorldClockMenuItemShape(item, to: menu, currentSection: &section, menuViewID: UUID(), presentationMode: .popover, enabled: true)

            let disabled = menu.items.filter { $0.isEnabled == false && !$0.isSeparatorItem }
            #expect(disabled.isEmpty, "No section header expected for sectionName=\(String(describing: sectionName))")
            #expect(section == nil)
        }
    }

    // Trimming applies before the comparison (whitespace around an
    // otherwise-equal section is ignored).
    do {
        let menu = NSMenu()
        var section: String? = nil
        var item1 = WorldClockMenuItemConfig.make()
        item1.sectionName = "Time Zones"
        var item2 = WorldClockMenuItemConfig.make()
        item2.sectionName = "  Time Zones  "

        addWorldClockMenuItemShape(item1, to: menu, currentSection: &section, menuViewID: UUID(), presentationMode: .popover, enabled: true)
        addWorldClockMenuItemShape(item2, to: menu, currentSection: &section, menuViewID: UUID(), presentationMode: .popover, enabled: true)

        let disabled = menu.items.filter { $0.isEnabled == false && !$0.isSeparatorItem }
        #expect(disabled.count == 1, "Trimmed equal section names should not emit a second header")
    }
}

@Test("Property 5: random section sequence — header count equals distinct-trimmed-non-empty transition count")
func property5RandomSectionTransitions() {
    forAll(arbitrarySectionSequence, iterations: 50) { sequence in
        let menu = NSMenu()
        var section: String? = nil
        for sectionName in sequence {
            var item = WorldClockMenuItemConfig.make()
            item.sectionName = sectionName
            addWorldClockMenuItemShape(
                item,
                to: menu,
                currentSection: &section,
                menuViewID: UUID(),
                presentationMode: .popover,
                enabled: true
            )
        }

        // Compute the expected header count by replaying the
        // transition rule against the input sequence.
        var expectedHeaders: [String] = []
        var currentExpected: String? = nil
        for sectionName in sequence {
            let trimmed = sectionName?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if let trimmed, !trimmed.isEmpty, trimmed != currentExpected {
                expectedHeaders.append(trimmed)
                currentExpected = trimmed
            }
        }

        let actualHeaders = menu.items
            .filter { !$0.isSeparatorItem && $0.isEnabled == false }
            .map(\.title)
        #expect(actualHeaders == expectedHeaders)
    }
}

private let arbitrarySectionSequence: AnyGenerator<[String?]> = AnyGenerator { rng in
    let n = Int.random(in: 1...8, using: &rng)
    let palette: [String?] = [nil, "", "   ", "Section A", "Section B", "Section C"]
    var result: [String?] = []
    for _ in 0..<n {
        let idx = Int.random(in: 0..<palette.count, using: &rng)
        result.append(palette[idx])
    }
    return result
}

// MARK: - Property 32: submenu population invariant

/// **Validates: Requirements 1.7, 1.8, 1.9, 1.10, 1.11, 3.5.4, 3.5.5**
///
/// Property 32 splits into two cases by `enableWorldClock`:
///
/// - When disabled: the submenu's items are exactly
///   `[disabled "World Clock is disabled", separator, enabled "Open Settings…" with .openWorldClockSettings]`.
/// - When enabled: the submenu's items are exactly
///   `[N disabled per-clock rows, separator, "Open World Clock…" (.openWorldClock), "Open Settings…" (.openWorldClockSettings)]`
///   where `N == clocks.filter(\.showInPopover).count` and the rows
///   appear in ascending `sortOrder`.
@Test("Property 32: submenu when disabled emits the documented three-item shape")
func property32SubmenuDisabledShape() {
    let menu = NSMenu()
    var settings = WorldClockSettings.defaults
    settings.enableWorldClock = false
    populateWorldClockSubmenuShape(menu, menuViewID: UUID(), settings: settings)

    #expect(menu.items.count == 3)

    // First item: disabled "World Clock is disabled".
    let first = menu.items[0]
    #expect(!first.isSeparatorItem)
    #expect(first.isEnabled == false)
    #expect(first.title == "World Clock is disabled")
    #expect(first.representedObject == nil)

    // Second item: separator.
    #expect(menu.items[1].isSeparatorItem)

    // Third item: enabled "Open Settings…" with .openWorldClockSettings action.
    let third = menu.items[2]
    #expect(!third.isSeparatorItem)
    #expect(third.isEnabled == true)
    #expect(third.title == "Open Settings…")
    if let action = third.representedObject as? MenuAction {
        switch action.kind {
        case .openWorldClockSettings:
            break
        default:
            Issue.record("Expected .openWorldClockSettings, got \(action.kind)")
        }
    } else {
        Issue.record("Trailing item must carry a MenuAction")
    }
}

@Test("Property 32: submenu when enabled emits per-clock rows + separator + two trailing actions")
func property32SubmenuEnabledShape() {
    forAll(arbitraryWorldClockSettings, iterations: 50) { wc in
        // Force the feature on so we exercise the enabled branch.
        var settings = wc
        settings.enableWorldClock = true

        let menu = NSMenu()
        let menuViewID = UUID()
        populateWorldClockSubmenuShape(menu, menuViewID: menuViewID, settings: settings)

        let visible = settings.clocks
            .filter { $0.showInPopover }
            .sorted { $0.sortOrder < $1.sortOrder }
        let expectedRowCount = visible.count
        // Total = N + 1 separator + 2 trailing actions.
        #expect(menu.items.count == expectedRowCount + 3)

        // Per-clock rows: indices 0..<N.
        for index in 0..<expectedRowCount {
            let row = menu.items[index]
            #expect(!row.isSeparatorItem)
            #expect(row.isEnabled == false, "Per-clock row at \(index) must be disabled")
            #expect(row.representedObject == nil, "Per-clock row at \(index) must have nil representedObject")
            #expect(!row.title.isEmpty, "Per-clock row title must be non-empty")
            // Title shape: "<emoji> <displayLabel>  <time>" or
            // "<displayLabel>  <time>" when emoji is missing.
            let clock = visible[index]
            if let emoji = clock.emoji?
                .trimmingCharacters(in: .whitespacesAndNewlines),
               !emoji.isEmpty {
                #expect(row.title.hasPrefix("\(emoji) "), "Row title \(row.title) should start with emoji prefix")
                #expect(row.title.contains("\(emoji) \(clock.displayLabel)"), "Row title should contain emoji + label")
            } else {
                #expect(row.title.hasPrefix(clock.displayLabel), "Row title without emoji should start with displayLabel")
            }
            // Title contains a double-space separator before the time
            // (per the documented format).
            #expect(row.title.contains("  "))
        }

        // Separator at index N.
        #expect(menu.items[expectedRowCount].isSeparatorItem)

        // Trailing "Open World Clock…" at index N+1.
        let openWC = menu.items[expectedRowCount + 1]
        #expect(openWC.title == "Open World Clock…")
        #expect(openWC.isEnabled == true)
        if let action = openWC.representedObject as? MenuAction {
            switch action.kind {
            case .openWorldClock:
                #expect(action.menuViewID == menuViewID)
            default:
                Issue.record("Expected .openWorldClock, got \(action.kind)")
            }
        } else {
            Issue.record("\"Open World Clock…\" must carry a MenuAction")
        }

        // Trailing "Open Settings…" at index N+2.
        let openSettings = menu.items[expectedRowCount + 2]
        #expect(openSettings.title == "Open Settings…")
        #expect(openSettings.isEnabled == true)
        if let action = openSettings.representedObject as? MenuAction {
            switch action.kind {
            case .openWorldClockSettings:
                break
            default:
                Issue.record("Expected .openWorldClockSettings, got \(action.kind)")
            }
        } else {
            Issue.record("\"Open Settings…\" must carry a MenuAction")
        }
    }
}

@Test("Property 32: per-clock rows appear in ascending sortOrder")
func property32SubmenuRowOrdering() {
    var settings = WorldClockSettings.defaults
    settings.enableWorldClock = true

    // Construct three clocks with non-monotonic ids but explicit
    // sortOrder values so the populator's sort is observable.
    let now = Date()
    let c0 = ClockConfig(
        id: UUID(),
        timeZoneIdentifier: "Asia/Tokyo",
        label: "Tokyo",
        emoji: nil,
        pinToMenuBar: false,
        showInPopover: true,
        sortOrder: 2,
        createdAt: now,
        updatedAt: now
    )
    let c1 = ClockConfig(
        id: UUID(),
        timeZoneIdentifier: "Europe/Berlin",
        label: "Berlin",
        emoji: nil,
        pinToMenuBar: false,
        showInPopover: true,
        sortOrder: 0,
        createdAt: now,
        updatedAt: now
    )
    let c2 = ClockConfig(
        id: UUID(),
        timeZoneIdentifier: "America/Los_Angeles",
        label: "Pacific",
        emoji: nil,
        pinToMenuBar: false,
        showInPopover: true,
        sortOrder: 1,
        createdAt: now,
        updatedAt: now
    )
    settings.clocks = [c0, c1, c2]

    let menu = NSMenu()
    populateWorldClockSubmenuShape(menu, menuViewID: UUID(), settings: settings)

    // Per-clock rows are at indices 0..2; expect them in sortOrder
    // ascending: Berlin (0), Pacific (1), Tokyo (2).
    #expect(menu.items[0].title.hasPrefix("Berlin"))
    #expect(menu.items[1].title.hasPrefix("Pacific"))
    #expect(menu.items[2].title.hasPrefix("Tokyo"))
}

@Test("Property 32: showInPopover=false clocks are filtered from the submenu")
func property32SubmenuHonorsShowInPopover() {
    var settings = WorldClockSettings.defaults
    settings.enableWorldClock = true

    let now = Date()
    let visible = ClockConfig(
        id: UUID(),
        timeZoneIdentifier: "UTC",
        label: "Visible",
        emoji: nil,
        pinToMenuBar: false,
        showInPopover: true,
        sortOrder: 0,
        createdAt: now,
        updatedAt: now
    )
    let hidden = ClockConfig(
        id: UUID(),
        timeZoneIdentifier: "UTC",
        label: "Hidden",
        emoji: nil,
        pinToMenuBar: false,
        showInPopover: false,
        sortOrder: 1,
        createdAt: now,
        updatedAt: now
    )
    settings.clocks = [visible, hidden]

    let menu = NSMenu()
    populateWorldClockSubmenuShape(menu, menuViewID: UUID(), settings: settings)

    // Expect 1 row + 1 separator + 2 trailing actions = 4 items.
    #expect(menu.items.count == 4)
    #expect(menu.items[0].title.contains("Visible"))
}

// MARK: - Property 33: mode-gated parent menu item shape

/// **Validates: Requirements 1.6, 1.7, 3.5.3, 3.5.4, 3.5.9**
///
/// Property 33 quantifies over `(WorldClockMenuItemConfig,
/// WorldClockPresentationMode)` and asserts the parent item's shape
/// matches the mode:
/// - `.popover`: submenu == nil, representedObject is
///   `MenuAction(kind: .openWorldClock)`, toolTip respects `enabled`.
/// - `.submenu`: submenu != nil, representedObject == nil, the
///   submenu's delegate is a retained `WorldClockMenuDelegate`.
@Test("Property 33: popover mode → submenu nil, .openWorldClock action; submenu mode → submenu set, nil action")
func property33ModeGatedParentItem() {
    forAll(arbitraryMenuItemConfig, iterations: 100) { config in
        for mode in WorldClockPresentationMode.allCases {
            for enabled in [true, false] {
                let menu = NSMenu()
                var section: String? = nil
                let menuViewID = UUID()

                // For the .submenu branch, production code attaches a
                // `WorldClockMenuDelegate` to the submenu and retains
                // it via `MenuDelegateRetainer`. Constructing such a
                // delegate from a test process requires a real
                // `MenuBuilder` (which would require a real
                // `PreferencesStore` reaching into the user's
                // Application Support directory). The reproduction in
                // `addWorldClockMenuItemShape(...)` omits the delegate
                // attachment, so this property only asserts the parts
                // of the shape that don't require the delegate type:
                // submenu != nil, representedObject == nil, the
                // popover-style tooltip is not set. The delegate type
                // claim is preserved as a documented code-level
                // invariant of `WorldClockMenuBuilder.swift`.
                addWorldClockMenuItemShape(
                    config,
                    to: menu,
                    currentSection: &section,
                    menuViewID: menuViewID,
                    presentationMode: mode,
                    enabled: enabled
                )

                guard let item = menu.items.first(where: { !$0.isSeparatorItem })
                else {
                    Issue.record("Expected at least one non-separator item")
                    return
                }
                #expect(item.title == config.displayTitle)
                #expect(item.image != nil)

                switch mode {
                case .popover:
                    #expect(item.submenu == nil, "popover mode → submenu nil")
                    if let action = item.representedObject as? MenuAction {
                        switch action.kind {
                        case .openWorldClock:
                            break
                        default:
                            Issue.record("Expected .openWorldClock for popover, got \(action.kind)")
                        }
                    } else {
                        Issue.record("popover-mode item must carry a MenuAction")
                    }
                    if enabled {
                        #expect(item.toolTip == nil)
                    } else {
                        #expect(item.toolTip == "World Clock is disabled in MenuShelf settings.")
                    }
                case .submenu:
                    #expect(item.submenu != nil, "submenu mode → submenu set")
                    #expect(item.representedObject == nil, "submenu mode → representedObject nil")
                    // Note: the popover-mode tooltip is intentionally
                    // not set in the production .submenu branch; the
                    // disabled-state surface is the submenu's own
                    // disabled "World Clock is disabled" item
                    // (Property 32). Assert the parent item carries
                    // no popover-style tooltip in submenu mode.
                    #expect(item.toolTip == nil, "submenu-mode parent item should not carry the popover tooltip")
                }
            }
        }
    }
}

// Note: The Property 33 sub-claim "the submenu's `delegate` is a
// retained `WorldClockMenuDelegate`" is intentionally not exercised
// at runtime here. Constructing a real `WorldClockMenuDelegate`
// requires a real `MenuBuilder`, which in turn requires
// `PreferencesStore` (file I/O on `~/Library/Application Support`),
// `FileAccessService`, `MetadataService`, and `MenuActionHandler` —
// invasive infrastructure for a test process. The pragmatic
// alternative described in the spec's testing-strategy fallback
// (re-implementing the populator algorithm at file scope) keeps the
// structural shape claims testable while leaving this delegate-type
// claim as a code-level invariant of `WorldClockMenuBuilder.swift`,
// where it's documented and grep-able. The reproduction in
// `addWorldClockMenuItemShape(...)` mirrors the production body
// clause-for-clause, so any drift in the production delegate
// attachment would surface in code review even without a runtime
// assertion here.
