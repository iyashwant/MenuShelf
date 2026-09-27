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
        // Active modules show the filled variant of their SF Symbol. Icons
        // with no filled form (emoji, images, monograms, title-only) fall
        // back to an accent tint so the active state stays visible.
        let isActive = activeStandaloneModuleKinds.contains(module.kind)
        let filledModule = isActive && module.menuBarStyle != .titleOnly
            ? filledVariant(of: module)
            : nil
        var image = statusImage(for: filledModule ?? module, size: 18)
        if let filledModule, case .systemSymbol(let name, _) = filledModule.icon,
           Self.symbolsWithOpenTop.contains(name) {
            image = image.fillingLargestEnclosedHole()
        }
        image.isTemplate = shouldTemplateIcon(module)
        button.contentTintColor = isActive && filledModule == nil
            ? NSColor.controlAccentColor
            : nil

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

    /// Filled symbols that SF Symbols still draws with a cut-out opening at
    /// the top. The active icon closes it so the whole cup reads as filled.
    private static let symbolsWithOpenTop: Set<String> = ["cup.and.saucer.fill", "mug.fill"]

    /// `module` with its SF Symbol swapped for the `.fill` variant, or `nil`
    /// when the icon isn't a symbol or has no filled form.
    func filledVariant(of module: StandaloneModuleConfig) -> StandaloneModuleConfig? {
        guard case .systemSymbol(let name, let tint) = module.icon,
              !name.hasSuffix(".fill") else { return nil }
        let filledName = name + ".fill"
        guard NSImage(systemSymbolName: filledName, accessibilityDescription: nil) != nil else {
            return nil
        }
        var filled = module
        filled.icon = .systemSymbol(name: filledName, tint: tint)
        return filled
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

// MARK: - Hole filling

extension NSImage {
    /// A copy with its largest fully enclosed transparent region painted in
    /// the image's own colour, rendered at 1x and 2x. Returns `self` when
    /// there is no enclosed region.
    func fillingLargestEnclosedHole() -> NSImage {
        let reps = [1, 2].compactMap { holeFilledRep(scale: CGFloat($0)) }
        guard !reps.isEmpty else { return self }
        let result = NSImage(size: size)
        reps.forEach(result.addRepresentation)
        return result
    }

    private func holeFilledRep(scale: CGFloat) -> NSBitmapImageRep? {
        let width = Int((size.width * scale).rounded())
        let height = Int((size.height * scale).rounded())
        guard width > 2, height > 2,
              let rep = NSBitmapImageRep(
                  bitmapDataPlanes: nil,
                  pixelsWide: width,
                  pixelsHigh: height,
                  bitsPerSample: 8,
                  samplesPerPixel: 4,
                  hasAlpha: true,
                  isPlanar: false,
                  colorSpaceName: .deviceRGB,
                  bytesPerRow: width * 4,
                  bitsPerPixel: 32
              ) else { return nil }
        rep.size = size
        guard let context = NSGraphicsContext(bitmapImageRep: rep),
              let pixels = rep.bitmapData else { return nil }

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        draw(in: NSRect(origin: .zero, size: size))
        NSGraphicsContext.restoreGraphicsState()

        let count = width * height
        func alpha(_ index: Int) -> UInt8 { pixels[index * 4 + 3] }

        // Mark every clear pixel reachable from the border as outside; the
        // clear pixels left over are holes enclosed by the glyph.
        var isOutside = [Bool](repeating: false, count: count)
        var stack: [Int] = []
        for x in 0..<width { stack.append(x); stack.append((height - 1) * width + x) }
        for y in 0..<height { stack.append(y * width); stack.append(y * width + width - 1) }
        while let index = stack.popLast() {
            guard !isOutside[index], alpha(index) < 128 else { continue }
            isOutside[index] = true
            let x = index % width, y = index / width
            if x > 0 { stack.append(index - 1) }
            if x < width - 1 { stack.append(index + 1) }
            if y > 0 { stack.append(index - width) }
            if y < height - 1 { stack.append(index + width) }
        }

        var visited = isOutside
        var largestHole: [Int] = []
        for start in 0..<count where !visited[start] && alpha(start) < 128 {
            var hole: [Int] = []
            stack = [start]
            while let index = stack.popLast() {
                guard !visited[index], alpha(index) < 128 else { continue }
                visited[index] = true
                hole.append(index)
                let x = index % width, y = index / width
                if x > 0 { stack.append(index - 1) }
                if x < width - 1 { stack.append(index + 1) }
                if y > 0 { stack.append(index - width) }
                if y < height - 1 { stack.append(index + width) }
            }
            if hole.count > largestHole.count { largestHole = hole }
        }
        guard !largestHole.isEmpty,
              let opaque = (0..<count).max(by: { alpha($0) < alpha($1) }),
              alpha(opaque) > 0 else { return nil }

        // Paint the hole plus a one-pixel ring, so the anti-aliased edge
        // where it meets the glyph doesn't leave a faint outline.
        for index in largestHole {
            let x = index % width, y = index / width
            for dy in -1...1 {
                for dx in -1...1 {
                    let nx = x + dx, ny = y + dy
                    guard nx >= 0, nx < width, ny >= 0, ny < height else { continue }
                    let target = (ny * width + nx) * 4
                    for channel in 0..<4 {
                        pixels[target + channel] = pixels[opaque * 4 + channel]
                    }
                }
            }
        }
        return rep
    }
}
