# MenuShelf - AI Agent Development Guide


## Quick Reference

### Project Type
- **Language**: Swift 5
- **Platform**: macOS 26+
- **Build System**: Swift Package Manager
- **UI Frameworks**: AppKit (menus), SwiftUI (settings)
- **Architecture**: Dependency Injection via AppContainer

### Key Files to Know
- `AppContainer.swift` - Dependency injection container, start here
- `AppModels.swift` - All data models and enums (500+ lines)
- `PreferencesStore.swift` - State management and persistence
- `MenuBuilder.swift` - Menu construction logic
- `StatusItemManager.swift` - Menu bar item management
- `MenuActionHandler.swift` - User action execution

### Build & Run
```bash
# Build executable
swift build

# Build app bundle
Scripts/build_app.sh debug
open .build/MenuShelf.app
```

## Common Tasks

### 1. Adding a New Menu Action

**Steps:**
1. Add enum case to `MenuActionKind` in `MenuActionHandler.swift`
2. Add any required parameters to `MenuAction` class
3. Implement the action in `MenuActionHandler.execute(_:modifierFlags:)`
4. Create menu item in `MenuBuilder` using `actionItem(_:kind:...)`
5. Test with appropriate security-scoped access

**Example:**
```swift
// 1. Add to MenuActionKind enum
enum MenuActionKind {
    // ... existing cases
    case exportAsJSON
}

// 2. Add parameter to MenuAction if needed
init(
    kind: MenuActionKind,
    // ... existing parameters
    exportPath: URL? = nil
) {
    // ... initialization
    self.exportPath = exportPath
}

// 3. Implement in execute()
case .exportAsJSON:
    guard let url = action.url, let exportPath = action.exportPath else { return }
    withFolderAccess(action.folderID) {
        exportToJSON(url, to: exportPath)
    }

// 4. Create menu item in MenuBuilder
menu.addItem(actionItem("Export as JSON", kind: .exportAsJSON, url: fileURL, exportPath: destinationURL))
```

**Important:** Always use `withFolderAccess(_:perform:)` for file operations to ensure security-scoped access.

### 2. Adding a New Setting

**Steps:**
1. Add property to appropriate model (`AppSettings`, `MenuSettings`, `FolderConfig`, etc.)
2. Add default value in the model's `.defaults` static property
3. Add migration logic in `PreferencesStore.migratedSettings(_:)`
4. Increment `schemaVersion` if changing structure
5. Add UI control in appropriate SwiftUI settings view
6. Create `Binding` to connect UI to store

**Example:**
```swift
// 1. Add to AppSettings
struct AppSettings: Codable, Equatable {
    // ... existing properties
    var showItemCount: Bool?
    
    // 2. Add default
    static let defaults = AppSettings(
        // ... existing defaults
        showItemCount: true
    )
    
    // Add computed property for non-optional access
    var resolvedShowItemCount: Bool { showItemCount ?? true }
}

// 3. Add migration in PreferencesStore.migratedSettings(_:)
if settings.schemaVersion < 8 {
    settings.schemaVersion = 8
    settings.showItemCount = settings.showItemCount ?? true
}

// 4. Add UI in SettingsView
Toggle("Show item count", isOn: Binding(
    get: { store.settings.resolvedShowItemCount },
    set: { value in store.updateGlobalSettings { $0.showItemCount = value } }
))
```

**Important:** Always provide a computed `resolved*` property for optional settings to avoid force-unwrapping.

### 3. Adding a New Icon Type

**Steps:**
1. Add case to `FolderIconConfig` enum
2. Update `Equatable` conformance if needed
3. Implement icon loading in `MenuBuilder.icon(for:size:)`
4. Add UI picker in settings view
5. Handle color tinting in `StatusItemManager.shouldTemplateIcon(_:)`

**Example:**
```swift
// 1. Add to FolderIconConfig
enum FolderIconConfig: Codable, Equatable {
    // ... existing cases
    case gradient(colors: [String])
}

// 3. Implement in MenuBuilder
func icon(for config: FolderConfig, size: CGFloat) -> NSImage? {
    switch config.icon {
    // ... existing cases
    case .gradient(let hexColors):
        return createGradientIcon(colors: hexColors, size: size)
    }
}

// 4. Add UI in settings
Button("Use Gradient") {
    config.icon = .gradient(colors: ["#FF0000", "#0000FF"])
}
```

### 4. Adding a New Menu View Layout Mode

**Steps:**
1. Add case to `MenuViewLayout` enum
2. Add label in enum's `label` computed property
3. Implement layout logic in `MenuBuilder.makeMenuViewMenu(for:includeManagement:visitedMenuViewIDs:)`
4. Test with various content types (folders, shortcuts, linked views)

**Example:**
```swift
// 1. Add to MenuViewLayout
enum MenuViewLayout: String, Codable, CaseIterable, Identifiable {
    // ... existing cases
    case grid
    
    var label: String {
        switch self {
        // ... existing cases
        case .grid: "Grid Layout"
        }
    }
}

// 3. Implement in MenuBuilder
private func makeMenuViewMenu(for view: MenuViewConfig, includeManagement: Bool, visitedMenuViewIDs: Set<UUID>) -> NSMenu {
    if view.resolvedLayout == .grid {
        return makeGridLayoutMenu(for: view)
    }
    // ... existing logic
}
```

### 5. Adding Shortcuts Integration Features

**Steps:**
1. Understand `/usr/bin/shortcuts` command-line interface
2. Add method to `ShortcutsService` using async/await
3. Update `PreferencesStore` to call service
4. Add UI in `ShortcutsSettingsView` or menu builder
5. Handle errors gracefully (shortcuts may be deleted)

**Example:**
```swift
// 2. Add to ShortcutsService
func getShortcutDetails(identifierOrName: String) async throws -> ShortcutDetails {
    let output = try await run(["view", identifierOrName, "--output-format", "json"])
    return try JSONDecoder().decode(ShortcutDetails.self, from: output.data(using: .utf8)!)
}

// 3. Add to PreferencesStore
func loadShortcutDetails(for shortcut: ShortcutInfo) {
    Task { [shortcutsService] in
        do {
            let details = try await shortcutsService.getShortcutDetails(identifierOrName: shortcut.identifier ?? shortcut.name)
            await MainActor.run {
                // Update UI with details
            }
        } catch {
            await MainActor.run {
                self.showError("Could not load shortcut details: \(error.localizedDescription)")
            }
        }
    }
}
```

## Critical Patterns & Gotchas

### 1. Security-Scoped Bookmarks

**Always use this pattern for file access:**
```swift
do {
    let access = try fileAccessService.accessItem(config)
    withExtendedLifetime(access) {
        // Perform file operations here
        NSWorkspace.shared.open(access.url)
    }
} catch {
    store.showError(error.localizedDescription)
}
```

**Why:** The `SecurityScopedURL` class manages `startAccessingSecurityScopedResource()` and `stopAccessingSecurityScopedResource()`. The RAII pattern ensures cleanup even if exceptions occur.

**Don't:** Never access files directly without resolving bookmarks first.

### 2. Lazy Menu Loading

**Use NSMenuDelegate for dynamic content:**
```swift
let menu = NSMenu(title: "Folder")
menu.autoenablesItems = false
let delegate = FolderMenuDelegate(builder: self, configID: config.id, ...)
menu.delegate = delegate
MenuDelegateRetainer.shared.retain(delegate)
```

**Why:** 
- Menus populate only when opened (performance)
- Content stays fresh (files added/removed)
- Prevents loading thousands of items upfront

**Don't:** Never populate menus synchronously in the main thread for large folders.

### 3. Settings Updates

**Always use this pattern:**
```swift
// For AppSettings
store.updateGlobalSettings { settings in
    settings.someProperty = newValue
}

// For FolderConfig
guard var config = store.folder(id: id) else { return }
config.someProperty = newValue
store.updateFolder(config)

// For MenuViewConfig
guard var view = store.menuView(id: id) else { return }
view.someProperty = newValue
store.updateMenuView(view)
```

**Why:** These methods handle `updatedAt` timestamps and trigger save/rebuild automatically.

**Don't:** Never mutate `store.settings` directly in SwiftUI views.

### 4. Menu Action Dispatch

**Always defer action execution:**
```swift
@objc func handleMenuAction(_ sender: Any?) {
    guard let action = sender.representedObject as? MenuAction else { return }
    
    // Defer until after menu tracking completes
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
        self?.execute(action, modifierFlags: modifierFlags)
    }
}
```

**Why:** AppKit menu tracking blocks the main thread. Immediate execution can cause UI issues or swallowed events.

**Don't:** Never execute actions synchronously in the action handler.

### 5. Circular Reference Prevention

**For linked menu views:**
```swift
func canLinkMenuView(_ linkedMenuViewID: UUID, toMenuViewID targetID: UUID) -> Bool {
    guard linkedMenuViewID != targetID else { return false }
    return !menuView(linkedMenuViewID, contains: targetID, in: views, visited: [])
}

private func menuView(_ currentID: UUID, contains searchID: UUID, in views: [MenuViewConfig], visited: Set<UUID>) -> Bool {
    if currentID == searchID { return true }
    guard !visited.contains(currentID) else { return false }
    
    var nextVisited = visited
    nextVisited.insert(currentID)
    
    for linkedView in view.resolvedLinkedMenuViews {
        if menuView(linkedView.menuViewID, contains: searchID, in: views, visited: nextVisited) {
            return true
        }
    }
    return false
}
```

**Why:** Menu views can contain other menu views. Without cycle detection, infinite loops crash the app.

**Don't:** Never allow linking without checking for cycles.

### 6. Symlink Loop Prevention

**For folder traversal:**
```swift
func populateFolderMenu(_ menu: NSMenu, configID: UUID, folderURL: URL?, visited: Set<String>) {
    let currentPath = currentURL.standardizedFileURL.path
    
    if visited.contains(currentPath) {
        addDisabled("Symlink Loop Detected", to: menu)
        return
    }
    
    var nextVisited = visited
    nextVisited.insert(currentPath)
    
    // Continue with nextVisited
}
```

**Why:** Symlinks can create infinite loops. Track visited paths to detect cycles.

**Don't:** Never traverse symlinks without loop detection.

### 7. Schema Migration

**Always increment version and migrate:**
```swift
private static func migratedSettings(_ decoded: AppSettings) -> AppSettings {
    var settings = decoded
    
    if settings.schemaVersion < 8 {
        settings.schemaVersion = 8
        // Add migration logic here
        settings.newProperty = settings.newProperty ?? defaultValue
    }
    
    return settings
}
```

**Why:** Users upgrade from old versions. Missing migrations cause data loss or crashes.

**Don't:** Never change model structure without adding migration logic.

### 8. Async/Await with ShortcutsService

**Always use Task and MainActor:**
```swift
Task { [shortcutsService] in
    do {
        let shortcuts = try await shortcutsService.listShortcuts()
        await MainActor.run {
            self.availableShortcuts = shortcuts
        }
    } catch {
        await MainActor.run {
            self.showError(error.localizedDescription)
        }
    }
}
```

**Why:** ShortcutsService is an actor. UI updates must happen on MainActor.

**Don't:** Never update UI properties directly from async context.

## SwiftUI Binding Patterns

### Binding to Store Properties

```swift
// Simple property
Toggle("Enabled", isOn: Binding(
    get: { store.settings.someProperty },
    set: { value in store.updateGlobalSettings { $0.someProperty = value } }
))

// Nested property with fallback
Picker("Size", selection: Binding(
    get: { config.menuSettings.fileIconSize ?? .medium },
    set: { value in 
        var updated = config
        updated.menuSettings.fileIconSize = value
        store.updateFolder(updated)
    }
))

// Optional property
TextField("Override", text: Binding(
    get: { item.titleOverride ?? "" },
    set: { value in
        var updated = item
        updated.titleOverride = value.isEmpty ? nil : value
        updateItem(updated)
    }
))
```

### Binding to Array Elements

```swift
private func itemBinding(for id: UUID) -> Binding<MenuViewItem>? {
    guard let index = view.items.firstIndex(where: { $0.id == id }) else { return nil }
    
    return Binding(
        get: { view.items[index] },
        set: { updated in
            var copy = updated
            copy.updatedAt = Date()
            view.items[index] = copy
        }
    )
}
```

## Testing Checklist

When making changes, test these scenarios:

### File Access
- [ ] Add folder from different locations (Desktop, Documents, external drive)
- [ ] Add app from /Applications
- [ ] Reselect folder after moving it
- [ ] Handle missing folders gracefully
- [ ] Handle stale bookmarks gracefully

### Menu Display
- [ ] Large folders (1000+ items)
- [ ] Empty folders
- [ ] Nested folders (5+ levels deep)
- [ ] Symlinks and aliases
- [ ] Hidden files (with toggle on/off)
- [ ] File extensions (with toggle on/off)

### Shortcuts
- [ ] List shortcuts successfully
- [ ] Run shortcut from menu
- [ ] Run shortcut via URL scheme
- [ ] Handle deleted shortcuts
- [ ] Option-click to edit
- [ ] Shortcuts with input parameters

### Menu Views
- [ ] Create multiple menu views
- [ ] Link menu views (no cycles)
- [ ] Hide/show menu views
- [ ] Duplicate menu views
- [ ] Delete menu views
- [ ] Keyboard shortcuts for menu views

### Settings
- [ ] Settings persist across restarts
- [ ] Migration from old schema versions
- [ ] Custom icons (SF Symbols, emoji, images)
- [ ] Sorting and filtering
- [ ] Menu bar styles (icon, title, both)

## Performance Considerations

### Do's
- ✅ Use lazy menu loading with delegates
- ✅ Limit directory listings with `maxItems`
- ✅ Cache security-scoped bookmark resolutions
- ✅ Use `@Published` sparingly (only for UI-bound state)
- ✅ Debounce rapid settings changes

### Don'ts
- ❌ Load all folder contents upfront
- ❌ Resolve bookmarks repeatedly for same folder
- ❌ Update settings on every keystroke
- ❌ Create new NSImage instances for every menu item
- ❌ Perform file I/O on main thread

## Debugging Tips

### Enable Diagnostics Logging
```swift
DiagnosticsLogger.shared.log("Your debug message here")
```
Logs appear in Console.app filtered by "MenuShelf".

### Common Issues

**"Stale bookmark" errors:**
- User moved/renamed folder
- Solution: Call `store.reselectFolder(id:)`

**Menu items not appearing:**
- Check `isVisible` property
- Check filter mode (appsOnly, foldersOnly, etc.)
- Check `maxItems` limit
- Check `ignoredNames` list

**Shortcuts not running:**
- Check `/usr/bin/shortcuts` exists
- Check shortcut still exists in Shortcuts.app
- Check shortcut identifier vs name
- Check for interactive prompts (alerts, inputs)

**Global hotkeys not working:**
- Check hotkey not already registered by system
- Check `keyCode` is set (not just `keyEquivalent`)
- Check modifier flags are correct
- Check Carbon Events API status codes

**Settings not persisting:**
- Check JSON encoding doesn't fail
- Check file permissions on settings file
- Check schema migration doesn't reset values
- Check `save()` is called after changes

## Code Style Guidelines

### Naming
- Use descriptive names: `resolvedFileIconSize` not `size`
- Prefix computed properties with `resolved` for optional fallbacks
- Use `make` for factory methods: `MenuViewConfig.make(...)`
- Use `handle` for event handlers: `handleMenuAction(_:)`

### Structure
- Keep files focused (one main class/struct per file)
- Group related functionality in extensions
- Use `// MARK: -` for section headers
- Order: properties, init, public methods, private methods

### Swift Features
- Use `final` for classes that shouldn't be subclassed
- Use `private` by default, expose only what's needed
- Use `guard` for early returns
- Use `if let` for optional unwrapping
- Use `switch` exhaustively (no `default` for enums)

### Error Handling
- Use `do-catch` for recoverable errors
- Show user-friendly error messages via `store.showError(_:)`
- Log technical details via `DiagnosticsLogger`
- Never force-unwrap (`!`) without clear justification

## Architecture Decisions

### Why AppKit for Menus?
SwiftUI doesn't support NSStatusItem or complex menu hierarchies. AppKit provides full control over menu bar integration.

### Why SwiftUI for Settings?
SwiftUI is ideal for forms and settings UIs. Declarative syntax reduces boilerplate for complex layouts.

### Why Combine?
`@Published` properties provide reactive updates without manual observation. SwiftUI bindings work seamlessly with Combine.

### Why Security-Scoped Bookmarks?
App Sandbox requires explicit user permission for file access. Bookmarks persist permissions across app launches.

### Why Lazy Menu Loading?
Large folders (1000+ files) would freeze the UI if loaded synchronously. Lazy loading keeps the app responsive.

### Why Schema Versioning?
Settings format evolves over time. Versioning enables backward-compatible migrations without data loss.

## Resources for Agents

### Apple Documentation
- [NSStatusItem](https://developer.apple.com/documentation/appkit/nsstatusitem)
- [NSMenu](https://developer.apple.com/documentation/appkit/nsmenu)
- [Security-Scoped Bookmarks](https://developer.apple.com/documentation/foundation/nsurl/1417051-bookmarkdata)
- [App Sandbox](https://developer.apple.com/documentation/security/app_sandbox)

### Swift Language
- [Swift Language Guide](https://docs.swift.org/swift-book/LanguageGuide/TheBasics.html)
- [Swift Concurrency](https://docs.swift.org/swift-book/LanguageGuide/Concurrency.html)
- [Combine Framework](https://developer.apple.com/documentation/combine)

### Project-Specific
- Read `CLAUDE.md` for architecture overview
- Read `AppModels.swift` for all data structures
- Read `AppContainer.swift` to understand dependencies
- Read `MenuBuilder.swift` for menu construction logic

## Quick Wins for Agents

Easy improvements that add value:

1. **Add new file actions** (e.g., "Duplicate File", "Compress")
2. **Add new sort keys** (e.g., "File Type", "Color Label")
3. **Add new filter modes** (e.g., "Videos Only", "Recent Files")
4. **Add new icon types** (e.g., "Color Gradient", "Custom Text")
5. **Add keyboard shortcuts** for common actions
6. **Improve error messages** with actionable suggestions
7. **Add tooltips** to settings UI
8. **Add validation** for user inputs
9. **Add undo/redo** for settings changes
10. **Add export/import** for settings

## Final Notes

- **Read before writing**: Understand existing patterns before adding new code
- **Test thoroughly**: MenuShelf deals with file system and sandboxing—bugs can cause data loss
- **Follow conventions**: Match existing code style and architecture
- **Ask questions**: If unsure about a pattern, check similar existing code
- **Document decisions**: Add comments for non-obvious logic

This codebase is well-structured and maintainable. Follow the established patterns and you'll be productive quickly. Good luck! 🚀
