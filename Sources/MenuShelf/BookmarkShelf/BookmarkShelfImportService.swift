//
//  BookmarkShelfImportService.swift
//  MenuShelf
//
//  Facade for importing bookmark trees into the Bookmark Shelf module.
//  Three entry points (drag-drop, Netscape HTML file, Safari/Chromium
//  browser file) plus a pure Netscape pretty-printer. Every facade
//  entry point runs on `@MainActor` and mutates the tree exclusively
//  through `BookmarkShelfStorage`'s public surface (Requirement 20.5).
//
//  Privacy: `DiagnosticsLogger.shared.log(_:)` lines never include
//  user-supplied node titles, URLs, or file paths — only error type
//  names and structural counts (Requirements 19.4, 19.5; Property
//  B10).
//

import AppKit
import Foundation

// MARK: - Public types

/// In-memory representation produced by every parser. The shared
/// `applyParsed(_:intoFolderID:storage:)` step takes this shape and
/// writes through `BookmarkShelfStorage`. Keeping the parsers pure
/// (no storage writes) lets Property B8 round-trip
/// `exportHTML(nodes:) → NetscapeHTMLParser.parse` against an in-memory
/// tree without touching disk.
struct ParsedTree {
    enum Node {
        case folder(title: String, children: [Node])
        case bookmark(title: String, url: String, addedAt: Date?)
    }
    let roots: [Node]
}

@MainActor
final class BookmarkShelfImportService {

    // MARK: - Singleton

    static let shared = BookmarkShelfImportService()

    private init() {}

    // MARK: - ImportSummary

    /// Per-import counts surfaced to the user via a counts-only toast.
    /// Field names are part of the property contract (Property B7,
    /// Requirement 12.1) — do not rename without bumping the contract.
    struct ImportSummary: Equatable {
        var addedBookmarks: Int = 0
        var addedFolders: Int = 0
        var skippedDuplicates: Int = 0
        var flattenedFolders: Int = 0
    }

    // MARK: - Errors and detected formats

    enum ImportError: Error {
        case notUTF8
        case unrecognizedFormat
        case malformedFile
    }

    private enum DetectedFormat {
        case safariPlist
        case chromiumJSON
        case unknown
    }

    // MARK: - Drag-drop import (Requirement 12.2, 12.3)

    /// Drag-drop import: one new `.bookmark` per dropped URL, deduplicated
    /// against existing siblings under `intoFolderID` by exact `url`
    /// match. Exact byte-for-byte equality — no scheme normalization,
    /// no trailing-slash collapsing (Property B7).
    func importDroppedURLs(
        _ urls: [URL],
        intoFolderID: UUID?
    ) -> ImportSummary {
        guard let storage = BookmarkShelfController.shared.storageHandle else {
            return ImportSummary()
        }
        var summary = ImportSummary()

        let existingURLs = Set(
            storage.nodes
                .filter { $0.parentID == intoFolderID && $0.kind == .bookmark }
                .compactMap { $0.url }
        )

        for url in urls {
            let raw = url.absoluteString
            if existingURLs.contains(raw) {
                summary.skippedDuplicates += 1
                continue
            }
            let title = url.host ?? raw
            if storage.addBookmark(
                parentID: intoFolderID,
                title: title,
                url: raw,
                isFavorite: false
            ) != nil {
                summary.addedBookmarks += 1
            }
        }
        return summary
    }

    // MARK: - Netscape HTML import (Requirement 12.4, 12.11, 12.12)

    /// Netscape HTML import. Atomic: parse failure rolls back to the
    /// pre-import snapshot via the storage's transaction triple. Surfaces
    /// only the error type in diagnostics (Property B10).
    func importHTML(
        from fileURL: URL,
        intoFolderID: UUID?
    ) async -> ImportSummary {
        guard let storage = BookmarkShelfController.shared.storageHandle else {
            return ImportSummary()
        }
        storage.beginTransaction()
        do {
            let data = try Data(contentsOf: fileURL)
            guard let text = String(data: data, encoding: .utf8) else {
                throw ImportError.notUTF8
            }
            let parsed = try NetscapeHTMLParser.parse(text)
            let summary = applyParsed(
                parsed,
                intoFolderID: intoFolderID,
                storage: storage
            )
            storage.commit()
            return summary
        } catch {
            storage.rollback()
            AppContainer.shared.store.showError(
                "Could not import bookmarks from the selected file."
            )
            DiagnosticsLogger.shared.log(
                "BookmarkShelf importHTML failed: \(type(of: error))"
            )
            return ImportSummary()
        }
    }

    // MARK: - Safari / Chromium file import (Requirement 12.7–12.12)

    /// Auto-detect Safari plist vs Chromium JSON. Atomic on parse
    /// failure; commit-on-success.
    func importBrowserBookmarkFile(
        from fileURL: URL,
        intoFolderID: UUID?
    ) async -> ImportSummary {
        guard let storage = BookmarkShelfController.shared.storageHandle else {
            return ImportSummary()
        }
        storage.beginTransaction()
        do {
            let data = try Data(contentsOf: fileURL)
            let parsed: ParsedTree
            switch detectFormat(fileURL: fileURL, data: data) {
            case .safariPlist:
                parsed = try SafariPlistParser.parse(data)
            case .chromiumJSON:
                parsed = try ChromiumJSONParser.parse(data)
            case .unknown:
                throw ImportError.unrecognizedFormat
            }
            let summary = applyParsed(
                parsed,
                intoFolderID: intoFolderID,
                storage: storage
            )
            storage.commit()
            return summary
        } catch ImportError.unrecognizedFormat {
            storage.rollback()
            AppContainer.shared.store.showError(
                "This file does not look like a Safari or Chromium bookmark file."
            )
            return ImportSummary()
        } catch {
            storage.rollback()
            AppContainer.shared.store.showError(
                "Could not import bookmarks from the selected file."
            )
            DiagnosticsLogger.shared.log(
                "BookmarkShelf importBrowserBookmarkFile failed: \(type(of: error))"
            )
            return ImportSummary()
        }
    }

    // MARK: - Format detection (Requirement 12.8)

    /// Extension-first heuristic with magic-byte fallback.
    private func detectFormat(fileURL: URL, data: Data) -> DetectedFormat {
        let ext = fileURL.pathExtension.lowercased()

        if ext == "plist" {
            if let plist = try? PropertyListSerialization.propertyList(
                from: data, options: [], format: nil
            ) as? [String: Any],
               plist["Children"] != nil,
               plist["WebBookmarkType"] != nil {
                return .safariPlist
            }
        }

        if ext == "json" || ext.isEmpty {
            if let json = try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any],
               let roots = json["roots"] as? [String: Any],
               (roots["bookmark_bar"] != nil
                || roots["other"] != nil
                || roots["synced"] != nil) {
                return .chromiumJSON
            }
        }

        // Magic-byte fallback: a Safari binary plist starts with
        // `bplist`; an XML plist starts with `<`; a Chromium file
        // starts with `{`.
        if data.starts(with: Data([0x62, 0x70, 0x6C, 0x69, 0x73, 0x74])) {
            return .safariPlist
        }
        if let firstByte = data.first {
            if firstByte == 0x7B { return .chromiumJSON }      // '{'
            if firstByte == 0x3C { return .safariPlist }       // '<'
        }
        return .unknown
    }

    // MARK: - applyParsed: depth-cap flatten + dedup (Requirement 6.4, 12.3, 12.6, 12.9)

    /// Apply a parsed in-memory tree under `intoFolderID`. Performs the
    /// depth-cap flatten algorithm (every `.folder` node whose target
    /// depth would exceed 5 is dropped, with its descendants lifted to
    /// the depth-5 ancestor) and within each sibling group dedups
    /// `.bookmark` entries by exact `url` match against the live
    /// `storage.nodes`. Folders are written before their children so
    /// `parentID` references resolve at write time.
    private func applyParsed(
        _ tree: ParsedTree,
        intoFolderID: UUID?,
        storage: BookmarkShelfStorage
    ) -> ImportSummary {
        var summary = ImportSummary()

        // The storage layer enforces `depth(of: parentID) + 1 <= 5`
        // for `addFolder`, which means a folder may be created when
        // the parent's depth is 0...4 (folder ends at depth 1...5).
        // The flatten algorithm therefore tracks the parent depth and
        // refuses to add a new folder once parent depth == 5.
        let baseDepth = storage.depth(of: intoFolderID)

        applyNodes(
            tree.roots,
            currentParentID: intoFolderID,
            currentParentDepth: baseDepth,
            storage: storage,
            summary: &summary
        )

        return summary
    }

    /// Recursive helper. `currentParentDepth` is the depth of the parent
    /// folder we're inserting into; root insertion starts at -1 (the
    /// "above-root" depth, so root-level entries become depth 0). A
    /// `.folder` would land at `currentParentDepth + 1`. Once the parent
    /// is already at depth 5, every `.folder` encountered is flattened
    /// (its bookmark descendants bubble up to the depth-5 parent).
    private func applyNodes(
        _ nodes: [ParsedTree.Node],
        currentParentID: UUID?,
        currentParentDepth: Int,
        storage: BookmarkShelfStorage,
        summary: inout ImportSummary
    ) {
        // Snapshot existing dedup set for this sibling group up front.
        // Newly added bookmarks are tracked in `addedURLs` so two
        // identical `.bookmark` entries in the same import payload
        // also collapse into one.
        var existingURLs = Set(
            storage.nodes
                .filter { $0.parentID == currentParentID && $0.kind == .bookmark }
                .compactMap { $0.url }
        )

        for node in nodes {
            switch node {
            case .bookmark(let title, let url, _):
                let trimmedURL = url.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmedURL.isEmpty else { continue }
                if existingURLs.contains(trimmedURL) {
                    summary.skippedDuplicates += 1
                    continue
                }
                let cleanedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
                let displayTitle: String
                if !cleanedTitle.isEmpty {
                    displayTitle = cleanedTitle
                } else {
                    displayTitle = URL(string: trimmedURL)?.host ?? trimmedURL
                }
                if storage.addBookmark(
                    parentID: currentParentID,
                    title: displayTitle,
                    url: trimmedURL,
                    isFavorite: false
                ) != nil {
                    summary.addedBookmarks += 1
                    existingURLs.insert(trimmedURL)
                }

            case .folder(let title, let children):
                if currentParentDepth + 1 > 5 {
                    // Flatten: drop this folder, lift every bookmark
                    // descendant into the current parent. Deeper
                    // folders are recursed into with the SAME parent
                    // so their bookmarks bubble up too.
                    summary.flattenedFolders += 1
                    applyNodes(
                        children,
                        currentParentID: currentParentID,
                        currentParentDepth: currentParentDepth,
                        storage: storage,
                        summary: &summary
                    )
                    continue
                }

                let cleanedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
                let folderTitle = cleanedTitle.isEmpty ? "Untitled" : cleanedTitle

                guard let folder = storage.addFolder(
                    parentID: currentParentID,
                    title: folderTitle
                ) else {
                    // Storage rejected — defensive (parser is untrusted
                    // input). Treat as flattened so any descendant
                    // bookmarks still land somewhere reasonable.
                    summary.flattenedFolders += 1
                    applyNodes(
                        children,
                        currentParentID: currentParentID,
                        currentParentDepth: currentParentDepth,
                        storage: storage,
                        summary: &summary
                    )
                    continue
                }
                summary.addedFolders += 1
                applyNodes(
                    children,
                    currentParentID: folder.id,
                    currentParentDepth: currentParentDepth + 1,
                    storage: storage,
                    summary: &summary
                )
            }
        }
    }

    // MARK: - Netscape pretty-printer (Requirement 12.13)

    /// Emit a well-formed Netscape Bookmark File Format string. Pure
    /// (no I/O); does not read or mutate `BookmarkShelfStorage`.
    /// Trees encoded by `exportHTML` round-trip through
    /// `NetscapeHTMLParser.parse(_:)` to an equivalent `ParsedTree`
    /// (Property B8).
    func exportHTML(nodes: [BookmarkNode]) -> String {
        var out = ""
        out += "<!DOCTYPE NETSCAPE-Bookmark-file-1>\n"
        out += "<!-- This is an automatically generated file.\n"
        out += "     It will be read and overwritten.\n"
        out += "     DO NOT EDIT! -->\n"
        out += "<META HTTP-EQUIV=\"Content-Type\" CONTENT=\"text/html; charset=UTF-8\">\n"
        out += "<TITLE>Bookmarks</TITLE>\n"
        out += "<H1>Bookmarks</H1>\n"

        // Build a parent->children index over the input array. The
        // pretty-printer treats `nodes` as a self-contained snapshot;
        // any node whose `parentID` references an id outside the
        // array is silently re-rooted (matches `BookmarkShelfStorage`'s
        // decode-time normalization).
        let allIDs = Set(nodes.map(\.id))
        let childrenByParent: [UUID?: [BookmarkNode]] = nodes.reduce(into: [:]) { dict, node in
            let key: UUID?
            if let pid = node.parentID, allIDs.contains(pid) {
                key = pid
            } else {
                key = nil
            }
            dict[key, default: []].append(node)
        }

        out += "<DL><p>\n"
        appendChildren(
            of: nil,
            indent: 1,
            childrenByParent: childrenByParent,
            into: &out
        )
        out += "</DL><p>\n"
        return out
    }

    private func appendChildren(
        of parentID: UUID?,
        indent: Int,
        childrenByParent: [UUID?: [BookmarkNode]],
        into out: inout String
    ) {
        let pad = String(repeating: "    ", count: indent)
        let children = (childrenByParent[parentID] ?? []).sorted { $0.sortOrder < $1.sortOrder }
        for child in children {
            switch child.kind {
            case .folder:
                out += "\(pad)<DT><H3>\(escapeHTML(child.title))</H3>\n"
                out += "\(pad)<DL><p>\n"
                appendChildren(
                    of: child.id,
                    indent: indent + 1,
                    childrenByParent: childrenByParent,
                    into: &out
                )
                out += "\(pad)</DL><p>\n"
            case .bookmark:
                guard let url = child.url, !url.isEmpty else { continue }
                out += "\(pad)<DT><A HREF=\"\(escapeHTMLAttribute(url))\">\(escapeHTML(child.title))</A>\n"
            }
        }
    }

    private func escapeHTML(_ raw: String) -> String {
        var out = ""
        out.reserveCapacity(raw.count)
        for ch in raw {
            switch ch {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            default: out.append(ch)
            }
        }
        return out
    }

    private func escapeHTMLAttribute(_ raw: String) -> String {
        // Same escaping as element text — quoted attributes also need
        // `"` and `&` replaced. The Netscape parser tolerates either.
        return escapeHTML(raw)
    }
}

// MARK: - NetscapeHTMLParser (Requirement 12.5)

/// Token-driven state machine over the Netscape Bookmark File Format.
/// Recognized constructs:
/// - `<DT><A HREF="…" ADD_DATE="…">Title</A>` → `.bookmark`
/// - `<DT><H3 …>Folder Name</H3>` → push a new folder
/// - `<DL>` → no-op (children block opens implicitly after a folder push)
/// - `</DL>` → pop the current folder
///
/// The parser is pure: it builds a `ParsedTree` carrying each node at
/// its source depth without applying the depth-cap flatten. The flatten
/// happens later in `applyParsed` so Property B8 round-trips without
/// the parser silently rewriting the tree.
private enum NetscapeHTMLParser {

    /// Mutable folder frame held on the parse stack. The root frame's
    /// `title` is unused (we return `frame.children` as `ParsedTree.roots`).
    private final class Frame {
        var title: String
        var children: [ParsedTree.Node] = []
        init(title: String) { self.title = title }
    }

    static func parse(_ text: String) throws -> ParsedTree {
        let root = Frame(title: "")
        var stack: [Frame] = [root]

        let scalars = Array(text.unicodeScalars)
        var i = 0
        let n = scalars.count

        while i < n {
            // Skip non-tag characters quickly.
            while i < n, scalars[i] != "<" {
                i += 1
            }
            guard i < n else { break }

            // Recognize tag prefixes case-insensitively.
            if matchesTag(scalars, at: i, "</DL") {
                if stack.count > 1 {
                    let popped = stack.removeLast()
                    let folderNode: ParsedTree.Node = .folder(
                        title: popped.title,
                        children: popped.children
                    )
                    stack.last?.children.append(folderNode)
                }
                i = advanceToTagEnd(scalars, from: i)
                continue
            }

            if matchesTag(scalars, at: i, "<DL") {
                // Children block opens implicitly via the preceding
                // `<DT><H3>` push. The `<DL>` token itself carries no
                // depth-stack effect.
                i = advanceToTagEnd(scalars, from: i)
                continue
            }

            if matchesTag(scalars, at: i, "<H3") {
                // Skip to '>' for the H3 tag, then read the title up
                // to '</H3>'. Folder push happens here so that any
                // subsequent `<DL>` is interpreted as the new folder's
                // children block.
                let tagEnd = advanceToTagEnd(scalars, from: i)
                let titleStart = tagEnd
                guard let closeStart = findCaseInsensitive(
                    scalars,
                    pattern: "</h3>",
                    from: titleStart
                ) else {
                    // Malformed — treat the rest of the file as a
                    // plain text and bail out.
                    break
                }
                let rawTitle = String(String.UnicodeScalarView(scalars[titleStart..<closeStart]))
                let frame = Frame(title: decodeHTMLEntities(rawTitle))
                stack.append(frame)
                i = closeStart + "</h3>".count
                continue
            }

            if matchesTag(scalars, at: i, "<A") {
                // Read attributes through the tag end, then the link
                // text up to `</A>`.
                let tagEnd = advanceToTagEnd(scalars, from: i)
                let attrSlice = scalars[i..<tagEnd]
                let attrs = parseAttributes(attrSlice)

                let textStart = tagEnd
                guard let closeStart = findCaseInsensitive(
                    scalars,
                    pattern: "</a>",
                    from: textStart
                ) else {
                    break
                }
                let rawTitle = String(String.UnicodeScalarView(scalars[textStart..<closeStart]))
                let title = decodeHTMLEntities(rawTitle)

                if let href = attrs["HREF"], !href.isEmpty {
                    let addedAt: Date?
                    if let raw = attrs["ADD_DATE"], let seconds = Double(raw) {
                        addedAt = Date(timeIntervalSince1970: seconds)
                    } else {
                        addedAt = nil
                    }
                    // Ignore `ICON` attributes per Requirement 19.3 —
                    // no favicon network fetch and no inline favicon
                    // decoding in v1. We simply do not surface the
                    // value.
                    let bookmark: ParsedTree.Node = .bookmark(
                        title: title,
                        url: href,
                        addedAt: addedAt
                    )
                    stack.last?.children.append(bookmark)
                }

                i = closeStart + "</a>".count
                continue
            }

            // Unknown tag — advance past it and continue.
            i = advanceToTagEnd(scalars, from: i)
        }

        // Any unclosed folders on the stack get unwound into their
        // parents so a malformed file (missing `</DL>`) still produces
        // a usable tree.
        while stack.count > 1 {
            let popped = stack.removeLast()
            stack.last?.children.append(.folder(title: popped.title, children: popped.children))
        }

        return ParsedTree(roots: root.children)
    }

    // MARK: Tokenizer helpers

    /// Returns true when `scalars[at...]` starts with `prefix`
    /// (case-insensitive ASCII compare) AND the next scalar after the
    /// prefix is not an alphanumeric (so `<H3` does not match `<H30>`,
    /// and `<A` matches `<A `, `<A>`, `<A\n`).
    private static func matchesTag(
        _ scalars: [Unicode.Scalar],
        at i: Int,
        _ prefix: String
    ) -> Bool {
        let prefixScalars = Array(prefix.unicodeScalars)
        guard i + prefixScalars.count <= scalars.count else { return false }
        for k in 0..<prefixScalars.count {
            let a = lowercaseASCII(scalars[i + k])
            let b = lowercaseASCII(prefixScalars[k])
            if a != b { return false }
        }
        // The character after the prefix must not be an ASCII letter
        // or digit — otherwise `<H3` would falsely match `<H30>` and
        // `<A` would match `<ARTICLE>`.
        let after = i + prefixScalars.count
        if after < scalars.count {
            let ch = scalars[after]
            if isASCIIAlphanumeric(ch) { return false }
        }
        return true
    }

    private static func lowercaseASCII(_ s: Unicode.Scalar) -> Unicode.Scalar {
        let v = s.value
        if v >= 0x41 && v <= 0x5A { return Unicode.Scalar(v + 0x20)! }
        return s
    }

    private static func isASCIIAlphanumeric(_ s: Unicode.Scalar) -> Bool {
        let v = s.value
        return (v >= 0x30 && v <= 0x39) // 0-9
            || (v >= 0x41 && v <= 0x5A) // A-Z
            || (v >= 0x61 && v <= 0x7A) // a-z
    }

    /// Advance past the `>` that closes the current tag. If no `>` is
    /// found, advance to end-of-input (so the outer loop terminates).
    private static func advanceToTagEnd(
        _ scalars: [Unicode.Scalar],
        from i: Int
    ) -> Int {
        var j = i
        let n = scalars.count
        while j < n {
            if scalars[j] == ">" { return j + 1 }
            j += 1
        }
        return n
    }

    /// Case-insensitive search for `pattern` starting at `start`.
    /// Returns the index of the first match, or nil.
    private static func findCaseInsensitive(
        _ scalars: [Unicode.Scalar],
        pattern: String,
        from start: Int
    ) -> Int? {
        let pat = Array(pattern.unicodeScalars).map(lowercaseASCII)
        if pat.isEmpty { return start }
        var i = start
        let n = scalars.count
        while i + pat.count <= n {
            var match = true
            for k in 0..<pat.count {
                if lowercaseASCII(scalars[i + k]) != pat[k] {
                    match = false
                    break
                }
            }
            if match { return i }
            i += 1
        }
        return nil
    }

    /// Parse attributes from a tag slice (`<A HREF="..." ADD_DATE="...">`).
    /// Attribute names are upper-cased so callers can look them up by
    /// canonical key (`HREF`, `ADD_DATE`, `ICON`, etc.). Values are
    /// HTML-entity-decoded.
    private static func parseAttributes(
        _ slice: ArraySlice<Unicode.Scalar>
    ) -> [String: String] {
        var attrs: [String: String] = [:]
        let s = Array(slice)
        var i = 0
        let n = s.count

        // Skip the leading `<TAGNAME` portion.
        while i < n, s[i] != " " && s[i] != "\t" && s[i] != "\n" && s[i] != "\r" && s[i] != ">" {
            i += 1
        }

        while i < n {
            // Skip whitespace.
            while i < n, isWhitespace(s[i]) { i += 1 }
            if i >= n || s[i] == ">" { break }

            // Read attribute name up to `=` or whitespace or `>`.
            let nameStart = i
            while i < n, s[i] != "=", !isWhitespace(s[i]), s[i] != ">" {
                i += 1
            }
            let nameEnd = i
            let nameRaw = String(String.UnicodeScalarView(s[nameStart..<nameEnd]))
            let name = nameRaw.uppercased()

            // Skip whitespace after the name.
            while i < n, isWhitespace(s[i]) { i += 1 }

            var value = ""
            if i < n, s[i] == "=" {
                i += 1
                // Skip whitespace after `=`.
                while i < n, isWhitespace(s[i]) { i += 1 }
                if i < n, s[i] == "\"" || s[i] == "'" {
                    let quote = s[i]
                    i += 1
                    let valueStart = i
                    while i < n, s[i] != quote { i += 1 }
                    let valueEnd = i
                    value = String(String.UnicodeScalarView(s[valueStart..<valueEnd]))
                    if i < n { i += 1 } // skip closing quote
                } else {
                    let valueStart = i
                    while i < n, !isWhitespace(s[i]), s[i] != ">" {
                        i += 1
                    }
                    let valueEnd = i
                    value = String(String.UnicodeScalarView(s[valueStart..<valueEnd]))
                }
            }

            if !name.isEmpty {
                attrs[name] = decodeHTMLEntities(value)
            }
        }

        return attrs
    }

    private static func isWhitespace(_ s: Unicode.Scalar) -> Bool {
        return s == " " || s == "\t" || s == "\n" || s == "\r"
    }

    /// Decode the small set of HTML entities that real-world Netscape
    /// exporters emit: `&amp;`, `&lt;`, `&gt;`, `&quot;`, `&#39;`,
    /// `&apos;`, plus numeric `&#NN;` and `&#xNN;` forms. Anything
    /// else is passed through unchanged.
    private static func decodeHTMLEntities(_ input: String) -> String {
        guard input.contains("&") else { return input }
        var out = ""
        out.reserveCapacity(input.count)
        let chars = Array(input)
        var i = 0
        let n = chars.count
        while i < n {
            if chars[i] != "&" {
                out.append(chars[i])
                i += 1
                continue
            }
            // Read up to ';' (max 8 chars) to bound malformed input.
            var j = i + 1
            let limit = min(n, i + 10)
            while j < limit, chars[j] != ";" { j += 1 }
            if j >= limit || j >= n || chars[j] != ";" {
                out.append(chars[i])
                i += 1
                continue
            }
            let entity = String(chars[(i + 1)..<j])
            if let replacement = entityReplacement(entity) {
                out.append(replacement)
            } else {
                out.append("&")
                out.append(entity)
                out.append(";")
            }
            i = j + 1
        }
        return out
    }

    private static func entityReplacement(_ entity: String) -> String? {
        switch entity {
        case "amp": return "&"
        case "lt": return "<"
        case "gt": return ">"
        case "quot": return "\""
        case "apos", "#39": return "'"
        default:
            if entity.hasPrefix("#x") || entity.hasPrefix("#X") {
                let hex = entity.dropFirst(2)
                if let value = UInt32(hex, radix: 16),
                   let scalar = Unicode.Scalar(value) {
                    return String(Character(scalar))
                }
            } else if entity.hasPrefix("#") {
                let dec = entity.dropFirst()
                if let value = UInt32(dec),
                   let scalar = Unicode.Scalar(value) {
                    return String(Character(scalar))
                }
            }
            return nil
        }
    }
}

// MARK: - SafariPlistParser (Requirement 12.8, 19.8)

/// Parser for Safari `Bookmarks.plist`. Decodes via
/// `PropertyListSerialization` only — `NSKeyedUnarchiver` is refused
/// to avoid arbitrary-class deserialization (Requirement 19.8).
private enum SafariPlistParser {

    static func parse(_ data: Data) throws -> ParsedTree {
        let object = try PropertyListSerialization.propertyList(
            from: data, options: [], format: nil
        )
        guard let dict = object as? [String: Any] else {
            throw BookmarkShelfImportService.ImportError.malformedFile
        }
        let children = (dict["Children"] as? [Any]) ?? []
        let nodes = children.compactMap { entry -> ParsedTree.Node? in
            guard let entryDict = entry as? [String: Any] else { return nil }
            return parseEntry(entryDict)
        }
        return ParsedTree(roots: nodes)
    }

    private static func parseEntry(_ dict: [String: Any]) -> ParsedTree.Node? {
        let kind = (dict["WebBookmarkType"] as? String) ?? ""
        switch kind {
        case "WebBookmarkTypeList":
            let title = (dict["Title"] as? String) ?? ""
            let children = (dict["Children"] as? [Any]) ?? []
            let parsedChildren = children.compactMap { entry -> ParsedTree.Node? in
                guard let entryDict = entry as? [String: Any] else { return nil }
                return parseEntry(entryDict)
            }
            return .folder(title: title, children: parsedChildren)

        case "WebBookmarkTypeLeaf":
            let url = (dict["URLString"] as? String) ?? ""
            let title: String
            if let uri = dict["URIDictionary"] as? [String: Any],
               let leafTitle = uri["title"] as? String {
                title = leafTitle
            } else {
                title = ""
            }
            guard !url.isEmpty else { return nil }
            return .bookmark(title: title, url: url, addedAt: nil)

        case "WebBookmarkTypeProxy":
            // System pseudo-roots (e.g. "History"). Skipped per the
            // design's Safari plist section.
            return nil

        default:
            return nil
        }
    }
}

// MARK: - ChromiumJSONParser (Requirement 12.8, 19.8)

/// Parser for Chromium `Bookmarks` (no extension). Merges the three
/// well-known roots — `bookmark_bar`, `other`, `synced` — under named
/// import-container folders so the user can tell them apart in the
/// MenuShelf tree.
private enum ChromiumJSONParser {

    static func parse(_ data: Data) throws -> ParsedTree {
        let object = try JSONSerialization.jsonObject(with: data, options: [])
        guard let dict = object as? [String: Any],
              let roots = dict["roots"] as? [String: Any] else {
            throw BookmarkShelfImportService.ImportError.malformedFile
        }

        // The three well-known roots in their canonical display order.
        // Each maps to a named import-container folder. Roots that are
        // missing or empty are silently skipped.
        let rootSpecs: [(key: String, title: String)] = [
            ("bookmark_bar", "Bookmarks Bar"),
            ("other", "Other Bookmarks"),
            ("synced", "Synced Bookmarks"),
        ]

        var rootNodes: [ParsedTree.Node] = []
        for spec in rootSpecs {
            guard let rootDict = roots[spec.key] as? [String: Any] else { continue }
            let children = (rootDict["children"] as? [Any]) ?? []
            let parsedChildren = children.compactMap { entry -> ParsedTree.Node? in
                guard let entryDict = entry as? [String: Any] else { return nil }
                return parseEntry(entryDict)
            }
            // Only emit the import container when the root carries any
            // children — empty wrappers add noise.
            if !parsedChildren.isEmpty {
                rootNodes.append(.folder(title: spec.title, children: parsedChildren))
            }
        }

        return ParsedTree(roots: rootNodes)
    }

    private static func parseEntry(_ dict: [String: Any]) -> ParsedTree.Node? {
        let type = (dict["type"] as? String) ?? ""
        switch type {
        case "folder":
            let name = (dict["name"] as? String) ?? ""
            let children = (dict["children"] as? [Any]) ?? []
            let parsedChildren = children.compactMap { entry -> ParsedTree.Node? in
                guard let entryDict = entry as? [String: Any] else { return nil }
                return parseEntry(entryDict)
            }
            return .folder(title: name, children: parsedChildren)

        case "url":
            let name = (dict["name"] as? String) ?? ""
            let url = (dict["url"] as? String) ?? ""
            guard !url.isEmpty else { return nil }
            return .bookmark(title: name, url: url, addedAt: nil)

        default:
            return nil
        }
    }
}
