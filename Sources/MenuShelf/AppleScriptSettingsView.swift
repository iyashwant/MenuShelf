import AppKit
import SwiftUI

// MARK: - Settings pane

struct AppleScriptSettingsView: View {
    @EnvironmentObject private var store: PreferencesStore
    @State private var compileBadge: CompileBadge?
    @State private var compileError: AppleScriptCompileError?
    @State private var nameDraft: String = ""
    @State private var sourceDraft: String = ""
    @State private var nameValidation: String?
    @State private var sourceValidation: String?
    @State private var lastLoadedID: UUID?

    private struct CompileBadge: Equatable {
        let success: Bool
        let timestamp: Date
    }

    var body: some View {
        HSplitView {
            sidebar
                .frame(minWidth: 200, idealWidth: 240, maxWidth: 320)

            detail
                .frame(minWidth: 480)
        }
        .onAppear { syncDrafts(force: true) }
        .onReceive(store.$selectedAppleScriptID) { _ in syncDrafts() }
        .onReceive(NotificationCenter.default.publisher(for: .menuShelfFocusAppleScripts)) { note in
            if let id = note.object as? UUID {
                store.selectedAppleScriptID = id
            }
        }
    }

    // MARK: Sidebar

    private var sidebar: some View {
        VStack(spacing: 0) {
            List(selection: Binding(
                get: { store.selectedAppleScriptID },
                set: { store.selectedAppleScriptID = $0 }
            )) {
                ForEach(sortedScripts) { script in
                    AppleScriptRow(script: script)
                        .tag(Optional(script.id))
                        .contextMenu {
                            Button("Duplicate") {
                                store.duplicateAppleScript(id: script.id)
                            }
                            Divider()
                            Button("Delete", role: .destructive) {
                                confirmDelete(script: script)
                            }
                        }
                }
            }

            Divider()

            HStack(spacing: 8) {
                Button {
                    let new = store.addAppleScript()
                    store.selectedAppleScriptID = new.id
                } label: {
                    Label("New", systemImage: "plus")
                }

                Button {
                    if let id = store.selectedAppleScriptID {
                        store.duplicateAppleScript(id: id)
                    }
                } label: {
                    Label("Duplicate", systemImage: "plus.square.on.square")
                }
                .disabled(store.selectedAppleScriptID == nil)

                Button {
                    if let id = store.selectedAppleScriptID,
                       let script = store.appleScript(id: id) {
                        confirmDelete(script: script)
                    }
                } label: {
                    Label("Delete", systemImage: "minus")
                }
                .disabled(store.selectedAppleScriptID == nil)

                Spacer()
            }
            .padding(10)
        }
    }

    // MARK: Detail

    private var detail: some View {
        Group {
            if let id = store.selectedAppleScriptID, let script = store.appleScript(id: id) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        SettingsHeader(
                            title: script.name,
                            subtitle: "AppleScript · last modified \(formatted(script.updatedAt))",
                            symbolName: "applescript"
                        )

                        SettingsCard("Name") {
                            SettingsBlockRow {
                                TextField("Name", text: $nameDraft)
                                    .textFieldStyle(.roundedBorder)
                                    .onChange(of: nameDraft) { _, value in
                                        validateAndCommitName(value, scriptID: id)
                                    }

                                if let nameValidation {
                                    Text(nameValidation)
                                        .font(.footnote)
                                        .foregroundStyle(.red)
                                }
                            }
                        }

                        SettingsCard("Source") {
                            SettingsBlockRow {
                                AppleScriptCodeEditor(
                                    text: $sourceDraft,
                                    highlightedLineRange: Binding(
                                        get: { compileError?.range },
                                        set: { _ in }
                                    )
                                )
                                .frame(minHeight: 280)
                                .onChange(of: sourceDraft) { _, value in
                                    validateAndCommitSource(value, scriptID: id)
                                }

                                if let sourceValidation {
                                    Text(sourceValidation)
                                        .font(.footnote)
                                        .foregroundStyle(.red)
                                }

                                HStack(spacing: 10) {
                                    if script.isFileReference {
                                        // File reference mode - show file info
                                        if let bookmark = script.sourceFileBookmark,
                                           let resolved = FileAccessService.resolveAppleScriptBookmark(bookmark) {
                                            HStack {
                                                Image(systemName: "doc.badge.ellipsis")
                                                    .foregroundStyle(.secondary)
                                                Text(resolved.url.lastPathComponent)
                                                    .foregroundStyle(.secondary)
                                                if resolved.isStale {
                                                    Image(systemName: "exclamationmark.triangle.fill")
                                                        .foregroundStyle(.orange)
                                                        .help("File has been moved or deleted. Re-import to update.")
                                                }
                                            }
                                            .font(.callout)

                                            Button("Re-import") {
                                                importFile(for: id)
                                            }
                                        } else {
                                            Text("File reference broken")
                                                .foregroundStyle(.red)
                                        }

                                        Button("Clear Reference") {
                                            store.setAppleScriptFileBookmark(id: id, bookmark: nil)
                                        }
                                        .foregroundStyle(.red)

                                        Spacer()
                                    } else {
                                        // Inline source mode - show editor
                                        Button {
                                            compile(scriptID: id, source: sourceDraft, name: nameDraft)
                                        } label: {
                                            Label("Compile", systemImage: "checkmark.seal")
                                        }
                                        .keyboardShortcut("k", modifiers: [.command])

                                        if let badge = compileBadge {
                                            HStack(spacing: 4) {
                                                Image(systemName: badge.success ? "checkmark.circle.fill" : "xmark.octagon.fill")
                                                    .foregroundStyle(badge.success ? .green : .red)
                                                Text(badge.success ? "Compiled" : "Failed")
                                                    .font(.callout)
                                                    .foregroundStyle(.secondary)
                                            }
                                            .transition(.opacity)
                                        }

                                        Spacer()
                                    }

                                    Button {
                                        importFile(for: id)
                                    } label: {
                                        Label("Import File...", systemImage: "doc.badge.plus")
                                    }
                                }

                                if let compileError, !compileError.message.isEmpty {
                                    Text(compileBannerText(error: compileError))
                                        .font(.footnote)
                                        .foregroundStyle(.red)
                                        .padding(8)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .background(Color.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
                                } else if let storedError = script.compileError, !storedError.isEmpty {
                                    Text(storedError)
                                        .font(.footnote)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }

                        SettingsCard("Icon") {
                            SettingsBlockRow {
                                IconPicker(
                                    icon: Binding(
                                        get: { script.icon ?? .systemSymbol(name: "applescript", tint: nil) },
                                        set: { newValue in store.setAppleScriptIcon(id: id, icon: newValue, colorHex: script.iconColorHex) }
                                    ),
                                    colorHex: Binding(
                                        get: { script.iconColorHex },
                                        set: { newValue in store.setAppleScriptIcon(id: id, icon: script.icon, colorHex: newValue) }
                                    ),
                                    displayName: script.name,
                                    onPickCustomImage: { /* not supported for scripts in v1 */ }
                                )
                            }
                        }

                        LastRunPanel(record: store.lastAppleScriptRuns[id])
                    }
                    .padding(28)
                    .frame(maxWidth: 760, alignment: .leading)
                }
            } else {
                ContentUnavailableView(
                    "No AppleScript Selected",
                    systemImage: "applescript",
                    description: Text("Create a new AppleScript or select one from the list.")
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.regularMaterial)
    }

    // MARK: Compile

    private func compile(scriptID: UUID, source: String, name: String) {
        let service = AppContainer.shared.appleScriptService
        Task {
            let outcome = await service.compile(source: source)
            await MainActor.run {
                switch outcome {
                case .success:
                    compileError = nil
                    compileBadge = CompileBadge(success: true, timestamp: Date())
                    store.setAppleScriptCompileState(id: scriptID, compiledAt: Date(), compileError: nil)
                    DiagnosticsLogger.shared.log("AppleScript compile ok id=\(scriptID.uuidString) name=\(String(name.prefix(256)))")
                case .failure(let error):
                    compileError = error
                    compileBadge = CompileBadge(success: false, timestamp: Date())
                    store.setAppleScriptCompileState(id: scriptID, compiledAt: Date(), compileError: error.message)
                    DiagnosticsLogger.shared.log("AppleScript compile failed id=\(scriptID.uuidString) error=\(error.message)")
                }
            }
            // Auto-dismiss success badge after ~3s.
            try? await Task.sleep(for: .seconds(3))
            await MainActor.run {
                if let badge = compileBadge, badge.success, Date().timeIntervalSince(badge.timestamp) >= 2.5 {
                    compileBadge = nil
                }
            }
        }
    }

    private func compileBannerText(error: AppleScriptCompileError) -> String {
        if error.isTimeout { return "Compilation timed out." }
        if error.isOversized { return "Source is too large to compile." }
        if error.isEmpty { return "Source is empty." }
        if let line = error.line { return "Line \(line): \(error.message)" }
        return error.message
    }

    // MARK: File Import

    private func importFile(for scriptID: UUID) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = [
            .init(filenameExtension: "scpt")!,
            .init(filenameExtension: "applescript")!,
            .init(filenameExtension: "scptd")!
        ]
        panel.message = "Select an AppleScript file to import"
        panel.prompt = "Import"

        if panel.runModal() == .OK, let url = panel.url {
            store.importAppleScriptFile(url: url, for: scriptID)
        }
    }

    // MARK: Validation

    private func validateAndCommitName(_ value: String, scriptID: UUID) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            nameValidation = "Name cannot be empty."
            return
        }
        if trimmed.count > 100 {
            nameValidation = "Name cannot exceed 100 characters."
            return
        }
        nameValidation = nil
        // Commit through the store, which handles persistence + timestamp.
        if store.appleScript(id: scriptID)?.name != trimmed {
            store.renameAppleScript(id: scriptID, to: trimmed)
        }
    }

    private func validateAndCommitSource(_ value: String, scriptID: UUID) {
        if value.count > 1_000_000 {
            sourceValidation = "Source cannot exceed 1,000,000 characters."
            return
        }
        sourceValidation = nil
        if store.appleScript(id: scriptID)?.source != value {
            store.updateAppleScriptSource(id: scriptID, source: value)
            // Editing invalidates compile state in the inline editor too.
            compileError = nil
        }
    }

    // MARK: Helpers

    private var sortedScripts: [AppleScriptConfig] {
        store.settings.resolvedAppleScripts.sorted { $0.updatedAt > $1.updatedAt }
    }

    private func syncDrafts(force: Bool = false) {
        let id = store.selectedAppleScriptID
        guard force || id != lastLoadedID else { return }
        lastLoadedID = id
        compileError = nil
        compileBadge = nil
        nameValidation = nil
        sourceValidation = nil
        if let id, let script = store.appleScript(id: id) {
            nameDraft = script.name
            sourceDraft = script.source
        } else {
            nameDraft = ""
            sourceDraft = ""
        }
    }

    private func formatted(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    private func confirmDelete(script: AppleScriptConfig) {
        let alert = NSAlert()
        alert.messageText = "Delete \(script.name)?"
        alert.informativeText = "This removes the AppleScript and any menu items that referenced it."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")

        guard alert.runModal() == .alertFirstButtonReturn else { return }
        store.deleteAppleScript(id: script.id)
    }
}

// MARK: - Sidebar row

private struct AppleScriptRow: View {
    let script: AppleScriptConfig

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: script.isFileReference ? "doc.badge.ellipsis" : appleScriptSymbol)
                .foregroundStyle(script.isFileReference ? .blue : .purple)

            VStack(alignment: .leading, spacing: 2) {
                Text(script.name)
                    .lineLimit(1)
                if script.isFileReference {
                    Text("File reference")
                        .font(.caption)
                        .foregroundStyle(.blue)
                } else {
                    Text(formatted(script.updatedAt))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            statusIndicator
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private var statusIndicator: some View {
        if script.isFileReference {
            Image(systemName: "doc.badge.link")
                .foregroundStyle(.blue)
                .help("References external file")
        } else if let error = script.compileError, !error.isEmpty {
            Image(systemName: "exclamationmark.circle.fill")
                .foregroundStyle(.red)
                .help(error)
        } else if script.compiledAt != nil {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .help("Compiled successfully")
        } else {
            EmptyView()
        }
    }

    private var appleScriptSymbol: String {
        if NSImage(systemSymbolName: "applescript", accessibilityDescription: nil) != nil { return "applescript" }
        if NSImage(systemSymbolName: "scroll", accessibilityDescription: nil) != nil { return "scroll" }
        return "doc.text"
    }

    private func formatted(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
}

// MARK: - Last Run panel

private struct LastRunPanel: View {
    let record: AppleScriptRunRecord?

    var body: some View {
        SettingsCard("Last Run") {
            SettingsBlockRow {
                if let record {
                    HStack(spacing: 8) {
                        Image(systemName: record.isSuccess ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                            .foregroundStyle(record.isSuccess ? .green : .orange)
                        Text(record.summary)
                            .font(.callout.weight(.semibold))
                        Spacer()
                        Text(formatted(record.startedAt))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    if !record.detail.isEmpty {
                        ScrollView {
                            Text(record.detail)
                                .font(.system(.footnote, design: .monospaced))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .textSelection(.enabled)
                        }
                        .frame(maxHeight: 120)
                        .padding(8)
                        .background(.background.tertiary, in: RoundedRectangle(cornerRadius: 6))
                    }
                } else {
                    Text("No runs in this session yet. Add this script to a menu view and click it, or trigger via menushelf://run-applescript.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func formatted(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .medium
        return formatter.string(from: date)
    }
}

// MARK: - Code editor

struct AppleScriptCodeEditor: NSViewRepresentable {
    @Binding var text: String
    @Binding var highlightedLineRange: NSRange?

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = false
        scrollView.borderType = .lineBorder

        guard let textView = scrollView.documentView as? NSTextView else {
            return scrollView
        }

        textView.delegate = context.coordinator
        textView.isEditable = true
        textView.isRichText = false
        textView.allowsUndo = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isAutomaticDataDetectionEnabled = false
        textView.isAutomaticLinkDetectionEnabled = false
        textView.smartInsertDeleteEnabled = false
        textView.font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        textView.textContainerInset = NSSize(width: 6, height: 8)
        textView.usesFindBar = true
        textView.string = text

        // Line number gutter.
        scrollView.hasHorizontalRuler = false
        scrollView.hasVerticalRuler = true
        scrollView.rulersVisible = true
        let ruler = AppleScriptLineNumberRulerView(scrollView: scrollView, orientation: .verticalRuler)
        ruler.clientView = textView
        scrollView.verticalRulerView = ruler
        context.coordinator.rulerView = ruler

        return scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        guard let textView = nsView.documentView as? NSTextView else { return }
        if textView.string != text {
            textView.string = text
        }
        applyHighlight(textView: textView, range: highlightedLineRange)
        context.coordinator.rulerView?.needsDisplay = true
    }

    private func applyHighlight(textView: NSTextView, range: NSRange?) {
        guard let storage = textView.textStorage else { return }
        let full = NSRange(location: 0, length: storage.length)
        storage.removeAttribute(.backgroundColor, range: full)
        guard let range,
              range.location >= 0,
              range.location + range.length <= storage.length else { return }
        storage.addAttribute(.backgroundColor, value: NSColor.systemRed.withAlphaComponent(0.18), range: range)
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: AppleScriptCodeEditor
        weak var rulerView: AppleScriptLineNumberRulerView?

        init(_ parent: AppleScriptCodeEditor) {
            self.parent = parent
        }

        func textView(_ textView: NSTextView, shouldChangeTextIn affectedCharRange: NSRange, replacementString: String?) -> Bool {
            guard let storage = textView.textStorage else { return true }
            let currentLength = storage.length
            let replacementLength = replacementString?.utf16.count ?? 0
            let removedLength = affectedCharRange.length
            let newLength = currentLength - removedLength + replacementLength
            return newLength <= 1_000_000
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            parent.text = textView.string
            parent.highlightedLineRange = nil
            rulerView?.needsDisplay = true
        }
    }
}

// MARK: - Line number ruler

final class AppleScriptLineNumberRulerView: NSRulerView {
    private static let gutterWidth: CGFloat = 36
    private let gutterFont = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)

    override init(scrollView: NSScrollView?, orientation: NSRulerView.Orientation) {
        super.init(scrollView: scrollView, orientation: orientation)
        ruleThickness = Self.gutterWidth
        clientView = scrollView?.documentView
    }

    required init(coder: NSCoder) {
        super.init(coder: coder)
    }

    override var requiredThickness: CGFloat { Self.gutterWidth }

    override func drawHashMarksAndLabels(in rect: NSRect) {
        guard let textView = clientView as? NSTextView,
              let layoutManager = textView.layoutManager,
              let textContainer = textView.textContainer else { return }

        let visibleRect = scrollView?.contentView.bounds ?? .zero
        let glyphRange = layoutManager.glyphRange(forBoundingRect: visibleRect, in: textContainer)
        let charRange = layoutManager.characterRange(forGlyphRange: glyphRange, actualGlyphRange: nil)
        let nsString = textView.string as NSString

        // Count the lines preceding the visible range so we know the starting line number.
        var startLine = 1
        var index = 0
        while index < charRange.location {
            let lineRange = nsString.lineRange(for: NSRange(location: index, length: 0))
            index = NSMaxRange(lineRange)
            if index <= charRange.location { startLine += 1 }
        }

        let attrs: [NSAttributedString.Key: Any] = [
            .font: gutterFont,
            .foregroundColor: NSColor.secondaryLabelColor
        ]

        var line = startLine
        var characterIndex = charRange.location
        while characterIndex < NSMaxRange(charRange) {
            let lineRange = nsString.lineRange(for: NSRange(location: characterIndex, length: 0))
            let glyphIndex = layoutManager.glyphIndexForCharacter(at: lineRange.location)
            let lineRect = layoutManager.lineFragmentRect(forGlyphAt: glyphIndex, effectiveRange: nil)
            let y = lineRect.origin.y - visibleRect.origin.y + textView.textContainerInset.height
            let label = "\(line)" as NSString
            let size = label.size(withAttributes: attrs)
            let drawPoint = NSPoint(x: Self.gutterWidth - size.width - 6, y: y + 1)
            label.draw(at: drawPoint, withAttributes: attrs)
            characterIndex = NSMaxRange(lineRange)
            line += 1
        }
    }
}
