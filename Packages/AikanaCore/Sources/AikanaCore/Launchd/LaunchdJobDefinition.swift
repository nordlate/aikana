import Foundation

/// One entry of a launchd job's `StartCalendarInterval`. A field that is `nil` matches every value,
/// so `hour: 2` alone means every minute from 02:00 to 02:59.
public struct LaunchdCalendarInterval: Sendable, Equatable {
    public let minute: Int?
    public let hour: Int?
    /// Day of the month, 1–31.
    public let day: Int?
    /// 0 and 7 are Sunday, 1 is Monday.
    public let weekday: Int?
    public let month: Int?

    public init(minute: Int? = nil, hour: Int? = nil, day: Int? = nil, weekday: Int? = nil, month: Int? = nil) {
        self.minute = minute
        self.hour = hour
        self.day = day
        self.weekday = weekday
        self.month = month
    }
}

public enum LaunchdPlistError: Error, Sendable, Equatable {
    case notAPropertyList
    case missingLabel
    /// A setting Aikana relies on has a value it cannot use.
    case invalid(key: String)

    public var reason: String {
        switch self {
        case .notAPropertyList: "it is not a property list"
        case .missingLabel: "it has no Label"
        case let .invalid(key): "its \(key) is not something launchd accepts"
        }
    }
}

/// The parts of a launchd job definition (its plist) that say when it runs and where it logs.
public struct LaunchdJobDefinition: Sendable, Equatable {
    public let label: String
    public let calendarIntervals: [LaunchdCalendarInterval]
    /// Seconds between runs, from `StartInterval`.
    public let startInterval: TimeInterval?
    public let standardOutPath: String?
    public let standardErrorPath: String?

    /// Whether the job runs on a timetable at all. A job without one runs on demand, at load, or on some other event.
    public var hasSchedule: Bool {
        !calendarIntervals.isEmpty || startInterval != nil
    }

    public init(
        label: String,
        calendarIntervals: [LaunchdCalendarInterval] = [],
        startInterval: TimeInterval? = nil,
        standardOutPath: String? = nil,
        standardErrorPath: String? = nil
    ) {
        self.label = label
        self.calendarIntervals = calendarIntervals
        self.startInterval = startInterval
        self.standardOutPath = standardOutPath
        self.standardErrorPath = standardErrorPath
    }

    /// Reads a job definition from the contents of a plist file, in any plist format.
    public init(plist data: Data) throws(LaunchdPlistError) {
        guard let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            throw .notAPropertyList
        }
        guard let label = plist["Label"] as? String, !label.isEmpty else {
            throw .missingLabel
        }
        self.init(
            label: label,
            calendarIntervals: try Self.calendarIntervals(plist["StartCalendarInterval"]),
            startInterval: try Self.startInterval(plist["StartInterval"]),
            standardOutPath: plist["StandardOutPath"] as? String,
            standardErrorPath: plist["StandardErrorPath"] as? String
        )
    }

    private static func startInterval(_ value: Any?) throws(LaunchdPlistError) -> TimeInterval? {
        guard let value else { return nil }
        guard let seconds = integer(value), seconds > 0 else {
            throw .invalid(key: "StartInterval")
        }
        return TimeInterval(seconds)
    }

    /// `StartCalendarInterval` is one dictionary or a list of them.
    private static func calendarIntervals(_ value: Any?) throws(LaunchdPlistError) -> [LaunchdCalendarInterval] {
        guard let value else { return [] }
        let entries = (value as? [Any]) ?? [value]
        var intervals: [LaunchdCalendarInterval] = []
        for entry in entries {
            guard let fields = entry as? [String: Any] else {
                throw .invalid(key: "StartCalendarInterval")
            }
            intervals.append(LaunchdCalendarInterval(
                minute: try field("Minute", in: fields, range: 0...59),
                hour: try field("Hour", in: fields, range: 0...23),
                day: try field("Day", in: fields, range: 1...31),
                weekday: try field("Weekday", in: fields, range: 0...7),
                month: try field("Month", in: fields, range: 1...12)
            ))
        }
        return intervals
    }

    private static func field(_ key: String, in fields: [String: Any], range: ClosedRange<Int>) throws(LaunchdPlistError) -> Int? {
        guard let value = fields[key] else { return nil }
        guard let number = integer(value), range.contains(number) else {
            throw .invalid(key: "StartCalendarInterval")
        }
        return number
    }

    /// A whole number, but not a boolean: property lists hand both over as numbers.
    private static func integer(_ value: Any) -> Int? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        return Int(exactly: number.doubleValue)
    }
}
