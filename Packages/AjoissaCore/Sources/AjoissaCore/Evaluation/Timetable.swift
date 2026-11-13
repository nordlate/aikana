import Foundation

/// When a job is expected to run, whatever scheduler it comes from.
///
/// A timetable has calendar rules ("daily at 02:00"), an interval ("every 15 minutes"), or both.
public struct Timetable: Sendable, Equatable, Codable {
    /// A point in the calendar that repeats. A field that is `nil` matches every value, as in launchd:
    /// `hour: 2` alone means every minute from 02:00 to 02:59.
    public struct CalendarRule: Sendable, Equatable, Codable {
        public var minute: Int?
        public var hour: Int?
        /// Day of the month, 1–31.
        public var day: Int?
        /// 0 and 7 are Sunday, 1 is Monday.
        public var weekday: Int?
        public var month: Int?

        public init(minute: Int? = nil, hour: Int? = nil, day: Int? = nil, weekday: Int? = nil, month: Int? = nil) {
            self.minute = minute
            self.hour = hour
            self.day = day
            self.weekday = weekday
            self.month = month
        }

        /// How far back or ahead to look for a matching day. Covers a rule that matches only on 29 February.
        private static let searchDays = 366 * 8

        /// The latest moment at or before `date` that the rule matches.
        func lastOccurrence(onOrBefore date: Date, calendar: Calendar) -> Date? {
            var day = calendar.startOfDay(for: date)
            for _ in 0..<Self.searchDays {
                if matches(day: day, calendar: calendar) {
                    for moment in moments(on: day, calendar: calendar).reversed() where moment <= date {
                        return moment
                    }
                }
                guard let previous = calendar.date(byAdding: .day, value: -1, to: day) else { return nil }
                day = previous
            }
            return nil
        }

        /// The first moment after `date` that the rule matches.
        func nextOccurrence(after date: Date, calendar: Calendar) -> Date? {
            var day = calendar.startOfDay(for: date)
            for _ in 0..<Self.searchDays {
                if matches(day: day, calendar: calendar) {
                    for moment in moments(on: day, calendar: calendar) where moment > date {
                        return moment
                    }
                }
                guard let following = calendar.date(byAdding: .day, value: 1, to: day) else { return nil }
                day = following
            }
            return nil
        }

        private func matches(day: Date, calendar: Calendar) -> Bool {
            let parts = calendar.dateComponents([.month, .day, .weekday], from: day)
            // `Calendar` counts weekdays from Sunday as 1; the rule counts from Sunday as 0, or 7.
            return (month == nil || month == parts.month)
                && (self.day == nil || self.day == parts.day)
                && (weekday == nil || weekday.map { $0 % 7 + 1 } == parts.weekday)
        }

        /// Every moment of one day that the rule's hour and minute match, in order.
        private func moments(on day: Date, calendar: Calendar) -> [Date] {
            let date = calendar.dateComponents([.year, .month, .day], from: day)
            let hours = hour.map { [$0] } ?? Array(0...23)
            let minutes = minute.map { [$0] } ?? Array(0...59)
            var moments: [Date] = []
            for hour in hours {
                for minute in minutes {
                    let parts = DateComponents(year: date.year, month: date.month, day: date.day, hour: hour, minute: minute)
                    // A time the clocks skip that day comes back moved forward; one that left the day is dropped.
                    if let moment = calendar.date(from: parts), calendar.isDate(moment, inSameDayAs: day) {
                        moments.append(moment)
                    }
                }
            }
            return moments.sorted()
        }
    }

    public var calendarRules: [CalendarRule]
    /// Seconds between runs, for a job that repeats without regard to the clock.
    public var interval: TimeInterval?

    public init(calendarRules: [CalendarRule] = [], interval: TimeInterval? = nil) {
        self.calendarRules = calendarRules
        self.interval = interval
    }

    /// Whether the timetable says nothing at all.
    public var isEmpty: Bool {
        calendarRules.isEmpty && interval == nil
    }

    // MARK: - From the config and from launchd

    public init(schedule: Schedule) {
        switch schedule {
        case let .daily(time):
            self.init(calendarRules: [CalendarRule(minute: time.minute, hour: time.hour)])
        case let .weekly(day, time):
            self.init(calendarRules: [CalendarRule(minute: time.minute, hour: time.hour, weekday: day.number)])
        case let .every(interval):
            self.init(interval: interval)
        }
    }

    public init(definition: LaunchdJobDefinition) {
        self.init(
            calendarRules: definition.calendarIntervals.map {
                CalendarRule(minute: $0.minute, hour: $0.hour, day: $0.day, weekday: $0.weekday, month: $0.month)
            },
            interval: definition.startInterval
        )
    }

    // MARK: - Calendar occurrences

    /// The most recent moment a calendar rule matched, at or before `date`. `nil` when there are no calendar
    /// rules, or none of them ever matches.
    public func lastCalendarOccurrence(onOrBefore date: Date, calendar: Calendar) -> Date? {
        calendarRules.compactMap { $0.lastOccurrence(onOrBefore: date, calendar: calendar) }.max()
    }

    /// The first moment after `date` that a calendar rule matches.
    public func nextCalendarOccurrence(after date: Date, calendar: Calendar) -> Date? {
        calendarRules.compactMap { $0.nextOccurrence(after: date, calendar: calendar) }.min()
    }

    /// How many times the calendar rules match after `start` and up to `end`, counting no further than `limit`.
    public func calendarOccurrenceCount(after start: Date, through end: Date, calendar: Calendar, limit: Int = 1000) -> Int {
        var count = 0
        var cursor = start
        while count < limit, let next = nextCalendarOccurrence(after: cursor, calendar: calendar), next <= end {
            count += 1
            cursor = next
        }
        return count
    }
}

private extension Weekday {
    /// The weekday as launchd and cron number it: Sunday is 0.
    var number: Int {
        switch self {
        case .sun: 0
        case .mon: 1
        case .tue: 2
        case .wed: 3
        case .thu: 4
        case .fri: 5
        case .sat: 6
        }
    }
}
