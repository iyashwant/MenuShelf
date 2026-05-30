# MenuShelf - Developer Documentation

## Overview

MenuShelf is a native macOS 26 menu bar utility built with Swift and AppKit that allows users to create custom menu bar views for organizing and accessing folders, apps, files, and Apple Shortcuts. It provides a powerful, flexible system for creating multiple menu bar items with customizable icons, layouts, and behaviors.

## Architecture

### Core Design Pattern

MenuShelf follows a **dependency injection** pattern with a central `AppContainer` that manages all services and coordinates the application lifecycle. The app uses:

- **AppKit** for native menu bar integration and UI
- **SwiftUI** for the settings window
- **Combine** for reactive state management
- **Security-scoped bookmarks** for sandboxed file access
- **Carbon Events API** for global hotkey registration

### Application Structure

```
AppDelegate (Entry Point)
    └── AppContainer (Dependency Container)
        ├── PreferencesStore (State Management)
        ├── StatusItemManager (Menu Bar Items)
        ├── MenuBuilder (Menu Construction)
        ├── MenuActionHandler (User Actions)
        ├── FileAccessService (Sandboxed File Access)
        ├── ShortcutsService (Apple Shortcuts Integration)
        ├── GlobalHotkeyService (Keyboard Shortcuts)
        ├── MenuPresentationCoordinator (Menu Display)
        └── SettingsWindowController (Settings UI)
```

## Key Components

### 1. AppDelegate & AppContainer

**AppDelegate.swift**
- Sets activation policy to `.accessory` (menu bar only, no dock icon)
- Installs a temporary "rescue" status item during startup
- Opens settings if no menu views are configured
- Handles URL scheme for `menushelf://` shortcuts

**AppContainer.swift**
- Singleton dependency injection container
- Initializes all services in correct order
- Provides shared access to services throughout the app

### 2. Data Models (AppModels.swift)

**Core Models:**
- `AppSettings`: Root settings object with schema versioning
- `MenuViewConfig`: Represents a menu bar item with its contents
- `FolderConfig`: Represents a folder or app source
- `MenuViewItem`: Links a source to a menu view with overrides
- `ShortcutMenuItemConfig`: Apple Shortcuts integration
- `LinkedShortcutsFolderConfig`: Links entire Shortcuts folders
- `LinkedMenuViewConfig`: Allows menu views to contain other menu views
- `MenuSettings`: Sorting, filtering, and display options
- `FileMenuItem`: Represents a file/folder in a menu
- `KeyboardShortcutConfig`: Global hotkey configuration

**Key Enumerations:**
- `MenuViewLayout`: automatic, sourceList, firstFolderContents
- `MenuBarStyle`: iconOnly, titleOnly, iconAndTitle
- `ShelfItemKind`: folder, app
- `FilterMode`: all, appsOnly, foldersOnly, documentsOnly, imagesOnly
- `SortKey`: name, dateCreated, dateModified, dateLastOpened, dateAdded, kind, size
- `OpenBehavior`: browseFoldersAsSubmenus, openFoldersInFinder
- `FolderIconConfig`: systemSymbol, emoji, customImage, folderIcon, monogram

### 3. PreferencesStore

**Responsibilities:**
- Manages all app settings and state
- Persists to `~/Library/Application Support/MenuShelf/settings.json`
- Provides `@Published` properties for reactive UI updates
- Handles schema migrations for backward compatibility
- Manages security-scoped bookmarks for file access
- Integrates with ShortcutsService for Shortcuts catalog

**Key Features:**
- JSON encoding/decoding with ISO8601 dates
- Schema versioning (current: v16)
- Automatic migration of old settings
- Security-scoped bookmark management
- Shortcuts catalog caching

### 4. StatusItemManager

**Responsibilities:**
- Creates and manages NSStatusItem instances in the menu bar
- Rebuilds status items when settings change
- Handles click events (left-click opens menu, right-click/option opens settings)
- Registers global hotkeys for menu views
- Configures status item appearance (icon, title, style)

**Key Features:**
- Dynamic status item creation based on visible menu views
- Fallback "empty" status item when no views are visible
- Template image rendering for system appearance
- Custom icon support (SF Symbols, emoji, custom images)
- Click handling with modifier key support

### 5. MenuBuilder

**Responsibilities:**
- Constructs NSMenu hierarchies from configuration
- Handles lazy loading of folder contents via delegates
- Creates file submenus with actions and previews
- Manages nested folder navigation
- Prevents symlink loops with visited path tracking

**Key Features:**
- **Lazy menu population**: Uses `NSMenuDelegate` to populate folder contents on-demand
- **Three layout modes**:
  - `automatic`: Smart layout based on content
  - `sourceList`: Shows all sources as top-level items
  - `firstFolderContents`: Direct display of first folder's contents
- **File submenus**: Preview, metadata, actions (open, reveal, copy, share, trash)
- **Folder submenus**: Recursive folder browsing with loop detection
- **Shortcuts integration**: Inline shortcuts and folders
- **Linked menu views**: Menu views can contain other menu views
- **Management menu**: Settings, visibility toggles, view management

### 6. FileAccessService

**Responsibilities:**
- Manages security-scoped bookmark resolution
- Provides sandboxed file access
- Generates directory listings with sorting/filtering
- Handles alias and symlink resolution
- Extracts file metadata

**Key Features:**
- Security-scoped resource management with RAII pattern
- Alias and symlink resolution with loop detection
- Configurable sorting (name, date, kind, size)
- Filtering (all, apps, folders, documents, images)
- Hidden file handling
- File extension display control

### 7. MenuActionHandler

**Responsibilities:**
- Executes user actions from menu items
- Manages file operations (open, reveal, copy, trash)
- Handles app launching and folder opening
- Integrates with NSWorkspace for system operations
- Manages sharing picker and "Open With" dialogs

**Key Actions:**
- File operations: open, reveal, copy path, copy file, copy contents, trash
- App operations: launch, reveal, open with
- Folder operations: open in Finder, browse as submenu
- Shortcuts: run, edit, open in Shortcuts app
- Menu view management: add, remove, duplicate, toggle visibility
- Settings: open settings window, configure sources

### 8. ShortcutsService

**Responsibilities:**
- Interfaces with `/usr/bin/shortcuts` command-line tool
- Lists available shortcuts and folders
- Runs shortcuts with optional text input
- Opens shortcuts for editing

**Key Features:**
- Async/await API using Swift concurrency
- Parses shortcut identifiers and names
- Handles shortcut execution with input
- Error handling for failed executions
- Silent execution (no Shortcuts app UI)

### 9. GlobalHotkeyService

**Responsibilities:**
- Registers global keyboard shortcuts using Carbon Events API
- Maps hotkeys to menu view IDs
- Handles hotkey press events
- Manages hotkey lifecycle (register/unregister)

**Implementation:**
- Uses Carbon `RegisterEventHotKey` API
- Converts NSEvent modifier flags to Carbon modifiers
- Maintains hotkey ID to menu view ID mapping
- Automatic cleanup on service deallocation

### 10. MenuPresentationCoordinator

**Responsibilities:**
- Coordinates menu display at different locations
- Manages menu positioning (menu bar item vs cursor)
- Tracks status items for menu anchoring
- Handles menu view visibility

**Features:**
- Two presentation modes: at menu bar item, at cursor
- Cursor-based presentation for keyboard shortcuts
- Status item tracking for proper menu anchoring

### 11. ShortcutURLRouter

**Responsibilities:**
- Handles `menushelf://` URL scheme
- Parses URL parameters for shortcut execution
- Routes to ShortcutsService for execution

**URL Format:**
```
menushelf://run-shortcut?name=My%20Shortcut
menushelf://run-shortcut?id=UUID
menushelf://run-shortcut?name=My%20Shortcut&input=text&text=Hello
```

## File Access & Sandboxing

MenuShelf is fully sandboxed with these entitlements:
- `com.apple.security.app-sandbox`: App Sandbox enabled
- `com.apple.security.files.user-selected.read-write`: User-selected file access
- `com.apple.security.files.bookmarks.app-scope`: Security-scoped bookmarks

**Security-Scoped Bookmarks:**
1. User selects folder/app via NSOpenPanel
2. App creates security-scoped bookmark data
3. Bookmark stored in settings JSON
4. On access: resolve bookmark → start accessing → perform operation → stop accessing
5. `SecurityScopedURL` class uses RAII pattern for automatic cleanup

## Settings Persistence

**Location:** `~/Library/Application Support/MenuShelf/settings.json`

**Schema Versioning:**
- Current version: 16
- Automatic migration on load
- Preserves backward compatibility
- Adds default values for new fields

**Migration Strategy:**
- Check `schemaVersion` field
- Apply incremental migrations
- Update schema version
- Save migrated settings

## Menu Construction Flow

1. **Status Item Creation** (StatusItemManager)
   - Create NSStatusItem for each visible menu view
   - Configure button appearance (icon, title, style)
   - Attach menu to status item

2. **Menu Building** (MenuBuilder)
   - Create NSMenu with title
   - Attach FolderMenuDelegate for lazy loading
   - Add management menu items if configured

3. **Lazy Population** (FolderMenuDelegate)
   - Triggered when menu is about to display
   - Resolve security-scoped bookmark
   - Get directory listing from FileAccessService
   - Create menu items for each file/folder
   - Attach submenus for folders
   - Add file action submenus

4. **User Interaction** (MenuActionHandler)
   - User clicks menu item
   - Action dispatched to MenuActionHandler
   - Execute action with security-scoped access
   - Update UI or show errors

## Shortcuts Integration

**Catalog Management:**
- Lists all shortcuts on startup
- Lists all shortcut folders
- Caches shortcuts by folder name
- Refresh on demand or via settings

**Execution:**
- Run via menu item click
- Run via URL scheme
- Option-click to edit instead of run
- Silent execution (no Shortcuts app UI)
- Optional text input parameter

**Display:**
- Inline shortcuts in menu views
- Linked shortcuts folders (submenu or inline section)
- Custom icons and quick keys
- Section grouping

## Global Hotkeys

**Registration:**
1. User configures keyboard shortcut in settings
2. GlobalHotkeyService registers with Carbon Events API
3. Hotkey press triggers callback
4. Callback dispatches to main thread
5. MenuPresentationCoordinator displays menu

**Modifiers:**
- Command (⌘)
- Option (⌥)
- Control (⌃)
- Shift (⇧)

## UI Components

### Settings Window (SwiftUI)

**Sections:**
1. **General**: Global appearance and behavior settings
2. **Menu Views**: Create and configure menu bar items
3. **Sources**: Manage folder and app sources
4. **Menu Defaults**: Default sorting/filtering for new sources
5. **Shortcuts**: Browse and add Apple Shortcuts
6. **Advanced**: Debug and advanced options

**Key Views:**
- `SettingsView`: Main navigation split view
- `MenuViewDetailView`: Configure individual menu views
- `FolderDetailView`: Configure folder/app sources
- `MenuSettingsEditor`: Sorting, filtering, display options
- `ShortcutRecorderView`: Record keyboard shortcuts
- `SFSymbolPickerView`: Browse SF Symbols

### Menu Bar (AppKit)

**Components:**
- NSStatusItem: Menu bar icon/title
- NSMenu: Dropdown menu
- NSMenuItem: Individual menu items
- Custom NSView subclasses for previews

## Build System

**Package.swift:**
- Swift Package Manager
- macOS 26 minimum deployment
- Swift 6.2 toolchain
- Swift 5 language mode

**Build Script (Scripts/build_app.sh):**
- Builds executable with `swift build`
- Creates app bundle structure
- Copies executable and resources
- Signs with ad-hoc signature
- Applies entitlements
- Sets LSUIElement for menu bar mode

## Key Design Decisions

### 1. Lazy Menu Loading
Menus are populated on-demand using `NSMenuDelegate.menuNeedsUpdate(_:)`. This improves performance for large folders and allows dynamic content updates.

### 2. Security-Scoped Bookmarks
All file access uses security-scoped bookmarks to work within the App Sandbox. The `SecurityScopedURL` class ensures proper resource cleanup.

### 3. Menu View Architecture
Menu views are separate from sources. Multiple menu views can reference the same source with different configurations (title, icon, settings).

### 4. Linked Menu Views
Menu views can contain other menu views, enabling hierarchical organization. Circular reference detection prevents infinite loops.

### 5. Shortcuts Integration
Direct integration with `/usr/bin/shortcuts` provides native Shortcuts support without requiring Shortcuts.app to be open.

### 6. Global Hotkeys
Carbon Events API provides reliable global hotkey support that works even when the app is in the background.

### 7. Settings Schema Versioning
Explicit schema versioning with migration logic ensures backward compatibility as the app evolves.

## Common Patterns

Recipes for the common change types (new menu action, new setting, new icon
type, new sort key, new filter, new layout, Shortcuts feature, global hotkey)
live in [`AGENTS.md`](./AGENTS.md). Keep this file focused on architecture so
the two don't drift.

## Testing & Debugging

**DiagnosticsLogger:**
- Logs to console for debugging
- Tracks key operations (file access, menu building, actions)
- Useful for troubleshooting sandboxing issues

**Common Issues:**
- **Stale bookmarks**: User needs to reselect folder
- **Missing folders**: Folder moved or deleted
- **Permission errors**: Sandbox restrictions or bookmark issues
- **Shortcut failures**: Shortcuts app not installed or shortcut deleted

## Future Considerations

**Potential Enhancements:**
- iCloud sync for settings
- Custom keyboard shortcuts for individual items
- Drag-and-drop file operations
- Menu item search/filtering
- Themes and appearance customization
- AppleScript/JXA automation support
- Menu item badges and notifications

**Performance Optimizations:**
- Cache file icons
- Lazy load metadata
- Debounce settings saves
- Optimize large folder listings

## Resources

**Apple Documentation:**
- [App Sandbox](https://developer.apple.com/documentation/security/app_sandbox)
- [Security-Scoped Bookmarks](https://developer.apple.com/documentation/foundation/nsurl/1417051-bookmarkdata)
- [NSStatusItem](https://developer.apple.com/documentation/appkit/nsstatusitem)
- [NSMenu](https://developer.apple.com/documentation/appkit/nsmenu)
- [Carbon Events](https://developer.apple.com/documentation/carbon/carbon_event_manager)

**Swift Packages:**
- None (pure Swift/AppKit/SwiftUI implementation)

## Code Style

- Swift 5 language mode
- Explicit types for clarity
- `final` classes by default
- Private by default, expose only what's needed
- Descriptive variable names
- Minimal comments (code should be self-documenting)
- SwiftUI for settings, AppKit for menus
- Combine for reactive state management
