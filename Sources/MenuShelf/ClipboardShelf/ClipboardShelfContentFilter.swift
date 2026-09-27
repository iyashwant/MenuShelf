import Foundation

/// Which kinds of items the standalone Clipboard Shelf popup lists.
enum ClipboardContentFilter: CaseIterable {
    case all
    case text
    case images

    /// The filter the popup opens with, unless the user picked another one
    /// and reopens the popup within `rememberDuration` of closing it.
    static let defaultFilter: ClipboardContentFilter = .text
    static let rememberDuration: TimeInterval = 60

    var title: String {
        switch self {
        case .all: "All"
        case .text: "Text"
        case .images: "Images"
        }
    }

    var symbolName: String? {
        switch self {
        case .all: nil
        case .text: "text.alignleft"
        case .images: "photo"
        }
    }

    var helpText: String {
        switch self {
        case .all: "Show all items"
        case .text: "Show text only"
        case .images: "Show images only"
        }
    }

    func includes(isImage: @autoclosure () -> Bool) -> Bool {
        switch self {
        case .all: true
        case .text: !isImage()
        case .images: isImage()
        }
    }

    /// The next filter in `allCases`, wrapping around at either end.
    func cycled(backwards: Bool = false) -> ClipboardContentFilter {
        let filters = Self.allCases
        let index = filters.firstIndex(of: self) ?? 0
        let step = backwards ? filters.count - 1 : 1
        return filters[(index + step) % filters.count]
    }

    /// The filter to show when the popup opens: `current` survives only when
    /// the popup was closed less than `rememberDuration` ago.
    static func filterOnOpen(
        current: ClipboardContentFilter,
        closedAt: Date?,
        now: Date = Date()
    ) -> ClipboardContentFilter {
        guard let closedAt, now.timeIntervalSince(closedAt) < rememberDuration else {
            return defaultFilter
        }
        return current
    }
}
