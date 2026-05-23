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
- Apple Shortcuts integration through `/usr/bin/shortcuts` for listing, organizing, and running Shortcuts app shortcuts from MenuShelf.
- Linked Shortcuts folders, quick keys, Option-click editing, and the `menushelf://run-shortcut` URL scheme.

## Shortcuts URL Scheme

MenuShelf registers its own URL scheme to run Shortcuts app shortcuts silently without opening Shortcuts:

```text
menushelf://run-shortcut?name=My%20Shortcut
menushelf://run-shortcut?id=A1B2C3D4-0000-1111-2222-ABCDEFABCDEF
menushelf://run-shortcut?name=My%20Shortcut&input=text&text=Hello
```

Shortcuts that show alerts or request input may block when executed from the command line. Prefer shortcuts that can run unattended for menu bar and URL automation workflows.

## Acknowledgements

The Clipboard Shelf feature vendors clipboard manager code from [Maccy](https://github.com/p0deje/Maccy) (MIT License) by Alex Rodionov. The full Maccy LICENSE is preserved verbatim at [`Sources/MenuShelf/ClipboardShelf/Vendor/MACCY_LICENSE.txt`](Sources/MenuShelf/ClipboardShelf/Vendor/MACCY_LICENSE.txt).
