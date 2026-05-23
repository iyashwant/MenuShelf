import AppKit
import Foundation

// MARK: - StatusItemManager helpers for standalone modules

extension StatusItemManager {
    /// Allocates an `NSStatusItem` for the given standalone module, configures
    /// its button (icon/title/style), tracks it in `statusItems`, and wires
    /// click handling.
    ///
    /// Privacy rail (Requirement 11.4): only the module's `id` and
    /// `kind.rawValue` are logged — never `title`, `icon`, or
    /// `iconColorHex`.
    func makeStandaloneModuleStatusItem(_ module: StandaloneModuleConfig) {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        configure(button: item.button, module: module)
        statusItems.append(.standaloneModule(item, module))
        configureClickHandling(item: item, context: .standaloneModule(item, module))
        DiagnosticsLogger.shared.log(
            "Created status item for standalone module id=\(module.id.uuidString) kind=\(module.kind.rawValue)"
        )
    }

    func configure(button: NSStatusBarButton?, module: StandaloneModuleConfig) {
        guard let button else { return }

        button.toolTip = visibleTitle(for: module)
        button.isEnabled = true

        let title = visibleTitle(for: module)
        let image = statusImage(for: module, size: 18)
        image.isTemplate = shouldTemplateIcon(module)

        switch module.menuBarStyle {
        case .iconOnly:
            button.title = ""
            button.image = image
            button.imagePosition = .imageOnly
        case .titleOnly:
            button.title = title
            button.image = nil
            button.imagePosition = .noImage
        case .iconAndTitle:
            button.title = title
            button.image = image
            button.imagePosition = .imageLeading
        }
    }

    func visibleTitle(for module: StandaloneModuleConfig) -> String {
        let title = module.title.trimmingCharacters(in: .whitespacesAndNewlines)
        return title.isEmpty ? module.kind.defaultTitle : title
    }

    func shouldTemplateIcon(_ module: StandaloneModuleConfig) -> Bool {
        if module.iconColorHex != nil {
            return false
        }

        switch module.icon {
        case .emoji, .customImage:
            return false
        case .folderIcon, .systemSymbol, .monogram:
            return true
        }
    }

    func statusImage(for module: StandaloneModuleConfig, size: CGFloat) -> NSImage {
        if case .folderIcon = module.icon {
            return fallbackMenuViewImage(size: size)
        }

        if let image = menuBuilder.icon(for: module, size: size) {
            image.size = NSSize(width: size, height: size)
            return image
        }

        return fallbackMenuViewImage(size: size)
    }
}

// MARK: - MenuBuilder icon overload for standalone modules

extension MenuBuilder {
    /// Sibling of `icon(for view: MenuViewConfig, size:)` that resolves an
    /// icon for a `StandaloneModuleConfig` by constructing an equivalent
    /// pseudo `FolderConfig` and dispatching to the existing
    /// `icon(for config: FolderConfig, size:)` resolver.
    func icon(for module: StandaloneModuleConfig, size: CGFloat) -> NSImage? {
        let pseudoSource = FolderConfig(
            id: module.id,
            displayName: module.title,
            bookmarkData: Data(),
            originalPathHint: "",
            itemKind: .folder,
            isVisible: module.isVisible,
            displayModeOverride: nil,
            icon: module.icon,
            menuBarStyle: module.menuBarStyle,
            menuSettings: .defaults,
            shortcut: module.shortcut,
            openBehavior: .browseFoldersAsSubmenus,
            iconColorHex: module.iconColorHex,
            createdAt: module.createdAt,
            updatedAt: module.updatedAt
        )
        return icon(for: pseudoSource, size: size)
    }
}
