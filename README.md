# MenuShelf

MenuShelf is a native macOS 26 menu bar utility for creating custom menu bar views that group folders, apps, files, and curated alias folders for fast access.

## Build

```bash
swift build
```

## Build App Bundle

```bash
Scripts/build_app.sh debug
open .build/MenuShelf.app
```

The generated app bundle is signed ad hoc with sandbox entitlements and uses `LSUIElement` so it runs as a menu bar app.

## Current Implementation

- AppKit status items for user-created Menu Views.
- SwiftUI settings window.
- Security-scoped bookmarks for reusable folder and app sources.
- Nested native folder menus.
- File, folder, and app opening through `NSWorkspace`.
- Per-view and per-source sorting/filtering basics.
- File action submenus with reveal, copy path, copy file, share, trash, and metadata.
- Alias and symlink resolution basics with loop protection.
- Quick Look thumbnail/text preview support for file submenus.
