# MenuShelf - AI Agent Development Guide

This file is the operational guide for AI agents working on MenuShelf. It explains
**how to make changes**: where to start, which patterns to follow, and how to
verify your work.

For architecture and component responsibilities, see [`CLAUDE.md`](./CLAUDE.md).
This file is the source of truth for recipes; CLAUDE.md is the source of truth
for design.

## Orientation

### Project at a glance
- **Language**: Swift, Swift 5 language mode, Swift 6.2 toolchain (see `Package.swift`)
- **Platform**: macOS 26+
- **Build system**: Swift Package Manager
- **UI**: AppKit for menu bar, SwiftUI for settings
- **Architecture**: Dependency injection via `AppContainer`
- **Tests**: No test target today. Verification is `swift build` plus a manual smoke check.

### Where to start by task type

| If the task is… | Start in… |
|---|---|
| New menu item or action | `MenuBuilder.swift`, `MenuActionHandler.swift` |
| New setting | `AppModels.swift`, `PreferencesStore.swift`, `SettingsView.swift` |
| New file operation | `MenuActionHandler.swift`, `FileAccessService.swift` |
| New sort key or filter mode | `AppModels.swift`, `FileAccessService.swift`, `SettingsView.swift` |
| Shortcuts feature | `ShortcutsService.swift`, `PreferencesStore.swift`, `SettingsView.swift` |
| Menu bar appearance | `StatusItemManager.swift` |
| Global hotkey | `GlobalHotkeyService.swift`, `MenuPresentationCoordinator.swift` |
| Settings persistence or migration | `PreferencesStore.swift` (`migratedSettings`) |

### Build, run, verify
```bash
# Compile the executable target. Run this before reporting a task complete.
swift build

# Build a runnable .app bundle (debug).
Scripts/build_app.sh debug
open .build/MenuShelf.app
```

If a change touches settings persistence, also delete or back up
`~/Library/Application Support/MenuShelf/settings.json` before launching, so you
can verify migration from defaults.

## Common Tasks

Each recipe below is a checklist. Complete every step or note explicitly why a
step does not apply.

### 1. Adding a new menu action

1. Add a case to `MenuActionKind` in `MenuActionHandler.swift`.
2. If the action needs new data, add it to `MenuAction` **with a default value**
   so existing call sites in `MenuBuilder` keep compiling.
3. Implement the case in `MenuActionHandler.execute(_:modifierFlags:)`.
   - For any file or folder operation, wrap the work in
     `withFolderAccess(_:perform:)` (this helper is private to `MenuActionHandler`).
4. Create the menu item in `MenuBuilder` via `actionItem(_:kind:url:folderID:...)`.
5. Manually verify with a folder you control, both with and without the option modifier.

Sketch:
```swift
// 1. MenuActionKind
enum MenuActionKind {
    // ...existing cases
    case exportAsJSON
}

// 2. MenuAction
init(
    kind: MenuActionKind,
    // ...existing parameters
    exportPath: URL? = nil // new, defaulted
) { /* ... */ }

// 3. MenuActionHandler.execute
case .exportAsJSON:
    guard let url = action.url, let exportPath = action.exportPath else { return }
    withFolderAccess(action.folderID) {
        exportToJSON(url, to: exportPath)
    }

// 4. MenuBuilder
menu.addItem(actionItem(
    "Export as JSON",
    kind: .exportAsJSON,
    url: fileURL,
    folderID: config.id
))
```

### 2. Adding a new setting

1. Add the property to the appropriate model in `AppModels.swift`
   (`AppSettings`, `MenuSettings`, `FolderConfig`, etc.).
2. Use `Optional` for new fields so older JSON decodes cleanly. Provide a
   `resolved*` computed property for the non-optional default.
3. Add the default in the model's `.defaults` static value.
4. Add migration in `PreferencesStore.migratedSettings(_:)`. Bump
   `schemaVersion` to `currentVersion + 1` and update the default in
   `AppSettings.defaults`. Check the existing `if settings.schemaVersion < N`
   ladder for the next number to use.
5. Add a SwiftUI control in `SettingsView.swift` (or the relevant detail view).
6. Bind it through the store, never by direct mutation. See
   *SwiftUI Binding Patterns* below.

Sketch:
```swift
// 1-3. AppSettings
struct AppSettings: Codable, Equatable {
    // ...
    var showItemCount: Bool?

    var resolvedShowItemCount: Bool { showItemCount ?? true }

    static let defaults = AppSettings(
        // ...
        showItemCount: true
    )
}

// 4. PreferencesStore.migratedSettings
if settings.schemaVersion < <next> {
    settings.schemaVersion = <next>
    settings.showItemCount = settings.showItemCount ?? true
}

// 5-6. SettingsView
Toggle("Show item count", isOn: Binding(
    get: { store.settings.resolvedShowItemCount },
    set: { value in store.updateGlobalSettings { $0.showItemCount = value } }
))
```

### 3. Adding a new icon type

1. Add a case to `FolderIconConfig` in `AppModels.swift`.
2. Update any `Equatable`/`Codable` machinery that needs the new case.
3. Implement rendering in `MenuBuilder.icon(for:size:)` and any other icon
   resolvers (search the codebase for `FolderIconConfig` usages).
4. Add a picker UI in the relevant settings view.
5. Decide template behavior in `StatusItemManager.shouldTemplateIcon(_:)` so the
   icon respects light/dark mode if appropriate.

### 4. Adding a new menu view layout mode

1. Add a case to `MenuViewLayout` in `AppModels.swift` and update its `label`.
2. Implement the layout in
   `MenuBuilder.makeMenuViewMenu(for:includeManagement:visitedMenuViewIDs:)`.
3. Surface the option in the menu view detail settings.
4. Verify with folders, shortcuts, and linked menu views as content.

### 5. Adding a new sort key

1. Add a case to `SortKey` in `AppModels.swift`.
2. Implement comparison in `FileAccessService` directory listing.
3. Add the picker entry in the menu settings editor in `SettingsView.swift`.
4. If the new key needs metadata not already loaded, extend `MetadataService`.

### 6. Adding a new filter mode

1. Add a case to `FilterMode` in `AppModels.swift`.
2. Add filter logic in `FileAccessService` so the listing respects it.
3. Add the picker entry in the menu settings editor.
4. Verify against folders containing mixed content (apps, files, hidden, symlinks).

### 7. Adding Shortcuts integration features

1. Read `/usr/bin/shortcuts --help` if you need a new subcommand.
2. Add an `async throws` method on `ShortcutsService`.
3. Call it from `PreferencesStore` (or the relevant view model) inside a `Task`.
   Hop to `MainActor` before touching UI state. Capture `[shortcutsService]`,
   not `self`, to avoid retaining the store from a long-lived task.
4. Surface results in `ShortcutsSettingsView` or the menu builder.
5. Handle the case where the shortcut was deleted between list and run.

### 8. Adding a global hotkey-driven feature

1. Extend `KeyboardShortcutConfig` in `AppModels.swift` if new fields are needed.
2. Register and unregister via `GlobalHotkeyService`. Always pair these.
3. Dispatch the hotkey callback to `MainActor` before mutating state or
   showing menus.
4. Use `MenuPresentationCoordinator` to display a menu. Do not present
   `NSMenu` directly from the hotkey callback.

## Critical Patterns & Gotchas

### 1. Security-scoped bookmarks

Inside `MenuActionHandler`, prefer the local helper:
```swift
withFolderAccess(action.folderID) {
    NSWorkspace.shared.open(url)
}
```

Outside `MenuActionHandler` (for example in `MenuBuilder` or settings code),
use `FileAccessService` directly with RAII:
```swift
do {
    let access = try fileAccessService.accessItem(config)
    withExtendedLifetime(access) {
        // file operations on access.url
    }
} catch {
    store.showError(error.localizedDescription)
}
```

`SecurityScopedURL` calls `startAccessingSecurityScopedResource` on init and
the matching stop on deinit. `withExtendedLifetime` guarantees the resource
stays live for the full closure even under optimization.

**Don't:** access files by raw path or by stored URL string. Always resolve
through `FileAccessService`.

### 2. Lazy menu loading

Use `NSMenuDelegate` so menus populate when opened:
```swift
let menu = NSMenu(title: "Folder")
menu.autoenablesItems = false
let delegate = FolderMenuDelegate(builder: self, configID: config.id, /* ... */)
menu.delegate = delegate
MenuDelegateRetainer.shared.retain(delegate)
```

`MenuDelegateRetainer` keeps the delegate alive because `NSMenu.delegate` is a
weak reference. Forgetting it produces empty menus.

**Don't:** populate large folders synchronously up front.

### 3. Settings updates

Settings mutate only through the store, which timestamps `updatedAt`, persists
to disk, and rebuilds menus.
```swift
// Global
store.updateGlobalSettings { settings in
    settings.someProperty = newValue
}

// Folder
guard var config = store.folder(id: id) else { return }
config.someProperty = newValue
store.updateFolder(config)

// Menu view
guard var view = store.menuView(id: id) else { return }
view.someProperty = newValue
store.updateMenuView(view)
```

**Don't:** mutate `store.settings` from a SwiftUI view or call `store.save()`
yourself.

### 4. Menu action dispatch

Defer execution so AppKit finishes menu tracking before the action runs.
```swift
@objc func handleMenuAction(_ sender: Any?) {
    guard let item = sender as? NSMenuItem,
          let action = item.representedObject as? MenuAction else { return }

    let modifiers = NSApp.currentEvent?.modifierFlags ?? NSEvent.modifierFlags

    // ~50ms is enough for menu tracking to release the main thread.
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
        self?.execute(action, modifierFlags: modifiers)
    }
}
```

Note that `sender` is `Any?` per the AppKit selector contract, so it must be
cast to `NSMenuItem` before reading `representedObject`.

**Don't:** execute actions synchronously inside the selector. AppKit can drop
events or freeze the menu.

### 5. Circular reference prevention for linked menu views

Menu views can link to other menu views. Always check for cycles before
accepting a link:
```swift
func canLinkMenuView(_ linkedID: UUID, toMenuViewID targetID: UUID) -> Bool {
    guard linkedID != targetID else { return false }
    return !menuView(linkedID, contains: targetID, in: views, visited: [])
}

private func menuView(
    _ currentID: UUID,
    contains searchID: UUID,
    in views: [MenuViewConfig],
    visited: Set<UUID>
) -> Bool {
    if currentID == searchID { return true }
    guard !visited.contains(currentID),
          let view = views.first(where: { $0.id == currentID }) else { return false }

    var nextVisited = visited
    nextVisited.insert(currentID)

    for linked in view.resolvedLinkedMenuViews {
        if menuView(linked.menuViewID, contains: searchID, in: views, visited: nextVisited) {
            return true
        }
    }
    return false
}
```

### 6. Symlink loop prevention

Track visited paths during folder traversal:
```swift
func populateFolderMenu(
    _ menu: NSMenu,
    configID: UUID,
    folderURL: URL,
    visited: Set<String>
) {
    let currentPath = folderURL.standardizedFileURL.path
    if visited.contains(currentPath) {
        addDisabled("Symlink Loop Detected", to: menu)
        return
    }

    var nextVisited = visited
    nextVisited.insert(currentPath)

    // ...recurse with nextVisited
}
```

### 7. Schema migration

Read the current head of the migration ladder in
`PreferencesStore.migratedSettings(_:)` and append at the end. Bump
`AppSettings.defaults.schemaVersion` in the same change.
```swift
if settings.schemaVersion < <next> {
    settings.schemaVersion = <next>
    // Add or backfill new fields here.
}
```

**Don't:** rename or remove existing fields without keeping a decoder-compatible
shim. Older settings JSON in the wild must still load.

### 8. Async work from PreferencesStore

`PreferencesStore` runs on the main actor. Long-running calls into actor-bound
services like `ShortcutsService` should be wrapped in `Task` and only touch UI
state inside `MainActor.run`:
```swift
Task { [shortcutsService] in
    do {
        let shortcuts = try await shortcutsService.listShortcuts()
        await MainActor.run { self.availableShortcuts = shortcuts }
    } catch {
        await MainActor.run { self.showError(error.localizedDescription) }
    }
}
```

Capturing `[shortcutsService]` rather than `self` avoids retaining the store
from a task that may outlive a settings sheet.

## SwiftUI Binding Patterns

```swift
// Simple property
Toggle("Enabled", isOn: Binding(
    get: { store.settings.someProperty },
    set: { value in store.updateGlobalSettings { $0.someProperty = value } }
))

// Optional with fallback
Picker("Size", selection: Binding(
    get: { config.menuSettings.fileIconSize ?? .medium },
    set: { value in
        var updated = config
        updated.menuSettings.fileIconSize = value
        store.updateFolder(updated)
    }
))

// Optional string treated as nil-when-empty
TextField("Override", text: Binding(
    get: { item.titleOverride ?? "" },
    set: { value in
        var updated = item
        updated.titleOverride = value.isEmpty ? nil : value
        updateItem(updated)
    }
))
```

For bindings into array elements, look up by stable `id: UUID`, not by index,
to survive reordering.

## Code Style

- `final` classes by default; `private` access by default.
- Use `guard` for early returns; avoid pyramids of `if let`.
- Use exhaustive `switch` over enums (no `default`). Single-expression cases
  may use Swift's switch-expression form (`case .x: "label"`).
- Never force-unwrap (`!`) without an inline justification. Prefer
  `Data(string.utf8)` over `string.data(using: .utf8)!`.
- Computed `resolved*` properties expose non-optional values for optional
  settings. Use them in UI code rather than unwrapping inline.
- Errors that affect the user go through `store.showError(_:)`. Technical
  detail goes through `DiagnosticsLogger.shared.log(_:)`.

## Don'ts (from real bugs)

- Don't compare `FolderConfig` by URL; identity is `id: UUID`.
- Don't construct fresh `NSImage` per menu item. Reuse
  `metadataService.icon(for:size:)`, which caches.
- Don't call `store.save()` directly. The `update*` methods handle persistence
  and rebuild.
- Don't read or write `store.settings` off the main actor.
- Don't traverse symlinks or linked menu views without cycle detection.
- Don't keep `NSMenu.delegate` alive only via the delegate's owner;
  `delegate` is weak. Use `MenuDelegateRetainer`.

## Testing Checklist

There is no automated test suite. After changes, exercise the relevant
scenarios:

**File access**
- Add folder from Desktop, Documents, an external drive
- Add app from `/Applications`
- Reselect folder after moving it
- Stale or missing bookmarks degrade gracefully

**Menu display**
- Folders with 1000+ items
- Empty folders, deeply nested folders, symlink chains
- Hidden files toggle, file extensions toggle

**Shortcuts**
- List, run, run with input, run via `menushelf://` URL
- Option-click to edit
- Deleted shortcut between list and run

**Menu views**
- Create, link without cycles, hide/show, duplicate, delete
- Global hotkey opens at the configured location

**Settings**
- Persist across restart
- Migration from a settings.json with a lower `schemaVersion`
- Custom icons (SF Symbol, emoji, custom image, monogram)

## Debugging

```swift
DiagnosticsLogger.shared.log("message")
```
Filter Console.app for `MenuShelf`. Verbose diagnostics is gated by
`enableVerboseDiagnostics` in settings.

Common symptoms:

- **Stale bookmark errors** — folder moved or renamed; call
  `store.reselectFolder(id:)`.
- **Menu items missing** — check `isVisible`, `FilterMode`, `maxItems`,
  and `ignoredNames`.
- **Shortcut won't run** — confirm `/usr/bin/shortcuts` exists, the shortcut
  still exists, and the identifier matches.
- **Global hotkey silent** — verify `keyCode` (not just `keyEquivalent`),
  modifier mapping, and that nothing else owns the combination.
- **Settings don't persist** — encoding error, file permission, or a migration
  that wipes the field. Check the diagnostics log on launch.

## Ideas (only when explicitly asked)

The following are pre-approved directions but should not be pursued
spontaneously. Wait for the user to ask.

- New file actions (duplicate, compress)
- New sort keys (file type, color label) and filter modes (videos, recent)
- Additional icon types (gradient, custom text)
- Per-item keyboard shortcuts
- Settings export/import, undo/redo
- iCloud sync
- Drag and drop into menu views

## References

- Apple: [`NSStatusItem`](https://developer.apple.com/documentation/appkit/nsstatusitem),
  [`NSMenu`](https://developer.apple.com/documentation/appkit/nsmenu),
  [security-scoped bookmarks](https://developer.apple.com/documentation/foundation/nsurl/1417051-bookmarkdata),
  [App Sandbox](https://developer.apple.com/documentation/security/app_sandbox)
- Project: [`CLAUDE.md`](./CLAUDE.md) for architecture, `AppModels.swift` for
  the full data model, `AppContainer.swift` for service wiring.
