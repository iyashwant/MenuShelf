import AppKit
import SwiftUI

// MARK: - Layout primitives

/// A scroll-based pane that hosts one or more `SettingsCard`s. Replaces the
/// older single-card `FormContainer` by letting each pane group its controls
/// into multiple cards that read like System Settings sections.
struct SettingsPane<Content: View>: View {
    let title: String
    let subtitle: String?
    let symbolName: String?
    @ViewBuilder let content: Content

    init(
        _ title: String,
        subtitle: String? = nil,
        symbolName: String? = nil,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.subtitle = subtitle
        self.symbolName = symbolName
        self.content = content()
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                SettingsHeader(title: title, subtitle: subtitle, symbolName: symbolName)
                content
            }
            .padding(28)
            .frame(maxWidth: 760, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

struct SettingsHeader: View {
    let title: String
    let subtitle: String?
    let symbolName: String?

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            if let symbolName {
                Image(systemName: symbolName)
                    .font(.system(size: 30, weight: .semibold))
                    .symbolRenderingMode(.hierarchical)
                    .frame(width: 40, height: 40)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.title.bold())
                    .lineLimit(2)
                if let subtitle {
                    Text(subtitle)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(.bottom, 4)
    }
}

/// A grouped card with an optional header. Rows inside use `SettingsRow` so
/// labels and controls align like a `Form`.
struct SettingsCard<Content: View>: View {
    let title: String?
    let footer: String?
    @ViewBuilder let content: Content

    init(_ title: String? = nil, footer: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.footer = footer
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let title {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                    .padding(.leading, 4)
            }

            VStack(alignment: .leading, spacing: 0) {
                content
            }
            .padding(.vertical, 2)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Color(nsColor: .separatorColor).opacity(0.35))
            }

            if let footer {
                Text(footer)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 4)
            }
        }
    }
}

/// A single labeled row inside a `SettingsCard`. The label is leading, the
/// control trails. An optional helper line drops underneath.
struct SettingsRow<Control: View>: View {
    let label: String
    let helper: String?
    @ViewBuilder let control: Control

    init(_ label: String, helper: String? = nil, @ViewBuilder control: () -> Control) {
        self.label = label
        self.helper = helper
        self.control = control()
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                if let helper {
                    Text(helper)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Spacer(minLength: 16)

            control
                .controlSize(.small)
                .frame(maxWidth: 240, alignment: .trailing)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .overlay(alignment: .bottom) {
            Divider()
                .padding(.leading, 14)
        }
    }
}

/// A row that hosts a free-form control without a leading label, for things
/// like full-width toggles with their own descriptive text or buttons.
struct SettingsBlockRow<Content: View>: View {
    @ViewBuilder let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .overlay(alignment: .bottom) {
            Divider()
                .padding(.leading, 14)
        }
    }
}

/// A toggle row that renders its title on the leading side and the toggle
/// switch on the trailing side, with optional helper text underneath.
struct SettingsToggle: View {
    let label: String
    let helper: String?
    @Binding var isOn: Bool

    init(_ label: String, helper: String? = nil, isOn: Binding<Bool>) {
        self.label = label
        self.helper = helper
        self._isOn = isOn
    }

    var body: some View {
        SettingsRow(label, helper: helper) {
            Toggle("", isOn: $isOn)
                .labelsHidden()
                .toggleStyle(.switch)
        }
    }
}

// MARK: - Icon picker

private enum IconKind: String, CaseIterable, Identifiable {
    case folder, symbol, emoji, image, monogram

    var id: String { rawValue }

    var label: String {
        switch self {
        case .folder: "Folder"
        case .symbol: "Symbol"
        case .emoji: "Emoji"
        case .image: "Image"
        case .monogram: "Letter"
        }
    }

    var symbolName: String {
        switch self {
        case .folder: "folder.fill"
        case .symbol: "star.circle"
        case .emoji: "face.smiling"
        case .image: "photo"
        case .monogram: "character.square"
        }
    }
}

/// A consolidated icon picker that prevents conflicting state by tying the
/// editable input to the active icon kind.
struct IconPicker: View {
    @Binding var icon: FolderIconConfig
    @Binding var colorHex: String?
    let displayName: String
    let onPickCustomImage: () -> Void

    @State private var browseSymbols = false
    @State private var symbolDraft: String = "folder"
    @State private var emojiDraft: String = ""
    @State private var monogramDraft: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 14) {
                IconPreview(icon: icon, colorHex: colorHex, displayName: displayName)

                VStack(alignment: .leading, spacing: 8) {
                    Picker("", selection: kindBinding) {
                        ForEach(IconKind.allCases) { kind in
                            Text(kind.label).tag(kind)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)

                    inputField
                }
            }

            HStack(spacing: 12) {
                ColorPicker("Tint", selection: Binding(
                    get: { Color(hexString: colorHex) },
                    set: { colorHex = $0.hexString }
                ))
                .labelsHidden()

                Text("Tint")
                    .font(.callout)

                Spacer()

                Button("Auto Tint") {
                    colorHex = nil
                }
                .controlSize(.small)
                .disabled(colorHex == nil)
            }
        }
        .sheet(isPresented: $browseSymbols) {
            SFSymbolPickerView(selectedSymbol: Binding(
                get: { symbolDraft },
                set: { value in
                    symbolDraft = value
                    icon = .systemSymbol(name: value, tint: nil)
                }
            ))
        }
        .onAppear { syncDrafts(from: icon) }
        .onChange(of: icon) { _, newValue in syncDrafts(from: newValue) }
    }

    private var kindBinding: Binding<IconKind> {
        Binding(
            get: { kind(of: icon) },
            set: { newKind in apply(kind: newKind) }
        )
    }

    private func kind(of icon: FolderIconConfig) -> IconKind {
        switch icon {
        case .folderIcon: .folder
        case .systemSymbol: .symbol
        case .emoji: .emoji
        case .customImage: .image
        case .monogram: .monogram
        }
    }

    private func apply(kind newKind: IconKind) {
        switch newKind {
        case .folder:
            icon = .folderIcon
        case .symbol:
            let name = symbolDraft.isEmpty ? "folder" : symbolDraft
            icon = .systemSymbol(name: name, tint: nil)
        case .emoji:
            let value = emojiDraft.isEmpty ? "📁" : emojiDraft
            icon = .emoji(value)
        case .image:
            onPickCustomImage()
        case .monogram:
            let letter = monogramDraft.isEmpty ? String(displayName.prefix(1)) : monogramDraft
            icon = .monogram(String(letter.prefix(2)))
        }
    }

    @ViewBuilder
    private var inputField: some View {
        switch kind(of: icon) {
        case .folder:
            Text("Uses the folder's own Finder icon.")
                .font(.footnote)
                .foregroundStyle(.secondary)

        case .symbol:
            HStack(spacing: 8) {
                TextField("SF Symbol name", text: Binding(
                    get: { symbolDraft },
                    set: { value in
                        symbolDraft = value
                        icon = .systemSymbol(name: value, tint: nil)
                    }
                ))
                .textFieldStyle(.roundedBorder)

                Image(systemName: symbolValid ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(symbolValid ? .green : .orange)
                    .help(symbolValid ? "Symbol available" : "Symbol not found")

                Button("Browse") { browseSymbols = true }
                    .controlSize(.small)
            }

        case .emoji:
            TextField("Emoji", text: Binding(
                get: { emojiDraft },
                set: { value in
                    emojiDraft = value
                    if !value.isEmpty { icon = .emoji(value) }
                }
            ))
            .textFieldStyle(.roundedBorder)
            .frame(maxWidth: 120)

        case .image:
            HStack(spacing: 8) {
                Text(customImageStatus)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Choose Image") { onPickCustomImage() }
                    .controlSize(.small)
            }

        case .monogram:
            TextField("Letter", text: Binding(
                get: { monogramDraft },
                set: { value in
                    monogramDraft = String(value.prefix(2))
                    icon = .monogram(monogramDraft.isEmpty ? String(displayName.prefix(1)) : monogramDraft)
                }
            ))
            .textFieldStyle(.roundedBorder)
            .frame(maxWidth: 80)
        }
    }

    private var symbolValid: Bool {
        guard case .systemSymbol(let name, _) = icon else { return false }
        return NSImage(systemSymbolName: name, accessibilityDescription: nil) != nil
    }

    private var customImageStatus: String {
        if case .customImage = icon { return "Custom image set." }
        return "Pick a PNG or JPEG to use as the icon."
    }

    private func syncDrafts(from icon: FolderIconConfig) {
        switch icon {
        case .systemSymbol(let name, _):
            symbolDraft = name
        case .emoji(let value):
            emojiDraft = value
        case .monogram(let letter):
            monogramDraft = letter
        case .folderIcon, .customImage:
            break
        }
    }
}

private struct IconPreview: View {
    let icon: FolderIconConfig
    let colorHex: String?
    let displayName: String

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(.background.tertiary)
                .frame(width: 64, height: 64)
                .overlay {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(Color(nsColor: .separatorColor).opacity(0.35))
                }

            content
        }
    }

    @ViewBuilder
    private var content: some View {
        let tint = Color(hexString: colorHex)
        switch icon {
        case .folderIcon:
            Image(systemName: "folder.fill")
                .font(.system(size: 32))
                .foregroundStyle(colorHex == nil ? Color.accentColor : tint)
        case .systemSymbol(let name, _):
            if let _ = NSImage(systemSymbolName: name, accessibilityDescription: nil) {
                Image(systemName: name)
                    .font(.system(size: 30))
                    .foregroundStyle(colorHex == nil ? Color.accentColor : tint)
            } else {
                Image(systemName: "questionmark.square.dashed")
                    .font(.system(size: 30))
                    .foregroundStyle(.secondary)
            }
        case .emoji(let value):
            Text(value.isEmpty ? "🙂" : value)
                .font(.system(size: 36))
        case .customImage:
            Image(systemName: "photo")
                .font(.system(size: 28))
                .foregroundStyle(.secondary)
        case .monogram(let letter):
            Text(letter.isEmpty ? String(displayName.prefix(1)) : letter)
                .font(.system(size: 28, weight: .semibold, design: .rounded))
                .foregroundStyle(colorHex == nil ? Color.accentColor : tint)
        }
    }
}

// MARK: - Menu preview

/// Lightweight visual preview of how a menu view will render. It does not
/// drive a real `NSMenu`; it shows the menu bar style on top and a faux
/// list of rows below using the active `MenuSettings`.
struct MenuPreviewCard: View {
    let title: String
    let icon: FolderIconConfig
    let colorHex: String?
    let menuBarStyle: MenuBarStyle
    let settings: MenuSettings

    var body: some View {
        SettingsCard("Preview") {
            VStack(alignment: .leading, spacing: 14) {
                MenuBarStrip(title: title, icon: icon, colorHex: colorHex, menuBarStyle: menuBarStyle)

                FauxMenu(title: title, settings: settings)
            }
            .padding(14)
        }
    }
}

private struct MenuBarStrip: View {
    let title: String
    let icon: FolderIconConfig
    let colorHex: String?
    let menuBarStyle: MenuBarStyle

    var body: some View {
        HStack(spacing: 10) {
            HStack(spacing: 6) {
                if menuBarStyle != .titleOnly {
                    iconView
                }
                if menuBarStyle != .iconOnly {
                    Text(title)
                        .font(.callout)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 6, style: .continuous))

            Spacer()

            HStack(spacing: 10) {
                Image(systemName: "wifi")
                Image(systemName: "battery.75percent")
                Text("9:41")
                    .font(.callout.monospacedDigit())
            }
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.background.tertiary, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color(nsColor: .separatorColor).opacity(0.35))
        }
    }

    @ViewBuilder
    private var iconView: some View {
        let tint: Color = colorHex == nil ? .primary : Color(hexString: colorHex)
        switch icon {
        case .folderIcon:
            Image(systemName: "folder.fill").foregroundStyle(tint)
        case .systemSymbol(let name, _):
            Image(systemName: NSImage(systemSymbolName: name, accessibilityDescription: nil) != nil ? name : "questionmark")
                .foregroundStyle(tint)
        case .emoji(let value):
            Text(value.isEmpty ? "🙂" : value)
        case .customImage:
            Image(systemName: "photo").foregroundStyle(.secondary)
        case .monogram(let letter):
            Text(letter.isEmpty ? String(letter.prefix(1)) : letter)
                .font(.callout.weight(.semibold))
                .foregroundStyle(tint)
        }
    }
}

private struct FauxMenu: View {
    let title: String
    let settings: MenuSettings

    private struct Row: Identifiable {
        let id = UUID()
        let icon: String
        let name: String
        let kind: String
    }

    private var rows: [Row] {
        var base: [Row] = [
            Row(icon: "folder.fill", name: "Documents", kind: "Folder"),
            Row(icon: "folder.fill", name: "Projects", kind: "Folder"),
            Row(icon: "app.dashed", name: "Xcode", kind: "App"),
            Row(icon: "doc.text", name: "Notes.txt", kind: "Document"),
            Row(icon: "photo", name: "Snapshot.png", kind: "Image"),
            Row(icon: "doc.fill", name: "Report.pdf", kind: "Document")
        ]

        switch settings.filterMode {
        case .all: break
        case .appsOnly: base = base.filter { $0.kind == "App" }
        case .foldersOnly: base = base.filter { $0.kind == "Folder" }
        case .documentsOnly: base = base.filter { $0.kind == "Document" }
        case .imagesOnly: base = base.filter { $0.kind == "Image" }
        }

        let sorted: [Row]
        switch settings.sortKey {
        case .name:
            sorted = base.sorted { $0.name.lowercased() < $1.name.lowercased() }
        case .kind:
            sorted = base.sorted { $0.kind < $1.kind }
        default:
            sorted = base
        }

        var ordered: [Row] = settings.sortDirection == .descending ? Array(sorted.reversed()) : sorted
        if settings.keepFoldersOnTop {
            let folders = ordered.filter { $0.kind == "Folder" }
            let rest = ordered.filter { $0.kind != "Folder" }
            ordered = folders + rest
        }
        if settings.keepAppsOnTop {
            let apps = ordered.filter { $0.kind == "App" }
            let rest = ordered.filter { $0.kind != "App" }
            ordered = apps + rest
        }
        return ordered
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if settings.resolvedShowFolderTitle {
                HStack {
                    Text(title)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(.horizontal, 10)
                .padding(.top, 8)
                .padding(.bottom, 4)
            }

            ForEach(rows.prefix(6)) { row in
                HStack(spacing: 8) {
                    Image(systemName: row.icon)
                        .frame(width: previewIconSize, height: previewIconSize)
                        .foregroundStyle(.secondary)
                    Text(displayName(for: row))
                        .font(.callout)
                    Spacer()
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
            }

            if let max = settings.maxItems, rows.count > max {
                HStack {
                    Image(systemName: "ellipsis")
                        .foregroundStyle(.secondary)
                    Text("More…")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
            }

            Divider()
                .padding(.vertical, 4)

            HStack {
                Image(systemName: "gearshape")
                    .foregroundStyle(.secondary)
                Text("Settings…")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.horizontal, 10)
            .padding(.bottom, 8)
        }
        .padding(.vertical, 4)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color(nsColor: .separatorColor).opacity(0.35))
        }
    }

    private var previewIconSize: CGFloat {
        switch settings.resolvedFileIconSize {
        case .small: 14
        case .medium: 18
        case .large: 22
        }
    }

    private func displayName(for row: FauxMenu.Row) -> String {
        if row.kind == "Document" || row.kind == "Image" {
            return settings.showFileExtensions ? row.name : (row.name as NSString).deletingPathExtension
        }
        return row.name
    }
}
