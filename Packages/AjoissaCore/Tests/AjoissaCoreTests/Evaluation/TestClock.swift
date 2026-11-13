import Foundation

/// Dates written as "2026-11-14 02:00", so tests read like a timeline.
enum TestClock {
    static func calendar(timeZone identifier: String) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        // A missing time zone is a broken test, not something to handle.
        calendar.timeZone = TimeZone(identifier: identifier) ?? .gmt
        return calendar
    }

    static let utc = calendar(timeZone: "UTC")

    /// "yyyy-MM-dd HH:mm", optionally followed by ":ss".
    static func date(_ text: String, calendar: Calendar = utc) -> Date {
        let numbers = text.split(whereSeparator: { "- :".contains($0) }).compactMap { Int($0) }
        guard numbers.count >= 5 else { return .distantPast }
        let components = DateComponents(
            year: numbers[0], month: numbers[1], day: numbers[2],
            hour: numbers[3], minute: numbers[4], second: numbers.count > 5 ? numbers[5] : 0
        )
        return calendar.date(from: components) ?? .distantPast
    }

    static func stamp(_ date: Date, calendar: Calendar = utc) -> String {
        let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        return String(
            format: "%04d-%02d-%02d %02d:%02d",
            parts.year ?? 0, parts.month ?? 0, parts.day ?? 0, parts.hour ?? 0, parts.minute ?? 0
        )
    }
}
