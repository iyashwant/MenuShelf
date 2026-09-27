import Foundation

/// How the Clipboard Shelf preview shows when an item was copied:
/// "Today, 12:58 AM", "Yesterday, 9:14 PM", or "27 Sep 2026, 4:52 AM".
enum ClipboardShelfCopyTime {
    static func string(
        for date: Date,
        now: Date = Date(),
        calendar: Calendar = .current,
        locale: Locale = .current
    ) -> String {
        let time = date.formatted(
            Date.FormatStyle(date: .omitted, time: .shortened, locale: locale, calendar: calendar, timeZone: calendar.timeZone)
        )

        if calendar.isDate(date, inSameDayAs: now) {
            return "Today, \(time)"
        }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
           calendar.isDate(date, inSameDayAs: yesterday) {
            return "Yesterday, \(time)"
        }

        let day = date.formatted(
            Date.FormatStyle(locale: locale, calendar: calendar, timeZone: calendar.timeZone)
                .day()
                .month(.abbreviated)
                .year()
        )
        return "\(day), \(time)"
    }
}
