import Foundation

extension LaunchdJobDefinition {
    /// The job's timetable in a few words, such as "daily at 02:00" or "every 15m". `nil` when it has none.
    public var scheduleDescription: String? {
        var parts = calendarIntervals.map(\.description)
        if let startInterval {
            parts.append("every \(Self.compact(seconds: Int(startInterval)))")
        }
        return parts.isEmpty ? nil : parts.joined(separator: "; ")
    }

    /// 86400 → "1d", 5400 → "90m", 90 → "90s": the largest unit that divides the number evenly.
    static func compact(seconds: Int) -> String {
        for (unit, size) in [("d", 86400), ("h", 3600), ("m", 60)] where seconds % size == 0 {
            return "\(seconds / size)\(unit)"
        }
        return "\(seconds)s"
    }
}

extension LaunchdCalendarInterval: CustomStringConvertible {
    private static let weekdayNames = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"]

    public var description: String {
        let dates = [
            month.map { "month \($0)" },
            day.map { "day \($0)" },
            weekday.map { Self.weekdayNames[$0 % 8] }
        ].compactMap { $0 }
        let dateText = dates.isEmpty ? nil : dates.joined(separator: " ")

        switch (hour, minute) {
        case let (hour?, minute?):
            return "\(dateText ?? "daily") at \(Self.twoDigits(hour)):\(Self.twoDigits(minute))"
        case let (hour?, nil):
            return "\(dateText ?? "daily"), every minute from \(Self.twoDigits(hour)):00 to \(Self.twoDigits(hour)):59"
        case let (nil, minute?):
            return "\(dateText.map { "\($0), " } ?? "")every hour at :\(Self.twoDigits(minute))"
        case (nil, nil):
            return "\(dateText.map { "\($0), " } ?? "")every minute"
        }
    }

    private static func twoDigits(_ number: Int) -> String {
        number < 10 ? "0\(number)" : "\(number)"
    }
}
