import AjoissaCore
import XCTest

final class LaunchdJobDefinitionTests: XCTestCase {
    func testSingleCalendarIntervalAndLogPaths() throws {
        let definition = try definition([
            "Label": "com.example.job",
            "ProgramArguments": ["/usr/bin/true"],
            "StartCalendarInterval": ["Hour": 2, "Minute": 0],
            "StandardOutPath": "/tmp/job.log",
            "StandardErrorPath": "/tmp/job.err"
        ])

        XCTAssertEqual(definition, LaunchdJobDefinition(
            label: "com.example.job",
            calendarIntervals: [LaunchdCalendarInterval(minute: 0, hour: 2)],
            standardOutPath: "/tmp/job.log",
            standardErrorPath: "/tmp/job.err"
        ))
        XCTAssertTrue(definition.hasSchedule)
    }

    func testListOfCalendarIntervals() throws {
        let definition = try definition([
            "Label": "com.example.job",
            "StartCalendarInterval": [
                ["Month": 1, "Day": 31, "Hour": 23, "Minute": 59],
                ["Weekday": 7],
                [String: Int]()
            ]
        ])

        XCTAssertEqual(definition.calendarIntervals, [
            LaunchdCalendarInterval(minute: 59, hour: 23, day: 31, month: 1),
            LaunchdCalendarInterval(weekday: 7),
            LaunchdCalendarInterval()
        ])
    }

    func testStartIntervalAlongsideCalendarIntervals() throws {
        let definition = try definition([
            "Label": "com.example.job",
            "StartInterval": 900,
            "StartCalendarInterval": ["Minute": 30]
        ])

        XCTAssertEqual(definition.startInterval, 900)
        XCTAssertEqual(definition.calendarIntervals, [LaunchdCalendarInterval(minute: 30)])
    }

    func testJobWithoutATimetable() throws {
        let definition = try definition(["Label": "com.example.job", "RunAtLoad": true, "KeepAlive": true])

        XCTAssertFalse(definition.hasSchedule)
        XCTAssertNil(definition.scheduleDescription)
        XCTAssertNil(definition.standardOutPath)
    }

    func testBinaryPlistIsRead() throws {
        let data = try PropertyListSerialization.data(
            fromPropertyList: ["Label": "com.example.job", "StartInterval": 60],
            format: .binary,
            options: 0
        )

        XCTAssertEqual(try LaunchdJobDefinition(plist: data).startInterval, 60)
    }

    func testNotAPropertyList() {
        XCTAssertEqual(error(for: Data("not a plist".utf8)), .notAPropertyList)
        XCTAssertEqual(error(for: Data()), .notAPropertyList)
        XCTAssertEqual(error(for: plist(["an", "array"])), .notAPropertyList)
    }

    func testLabelIsRequired() {
        XCTAssertEqual(error(for: plist(["StartInterval": 60])), .missingLabel)
        XCTAssertEqual(error(for: plist(["Label": ""])), .missingLabel)
        XCTAssertEqual(error(for: plist(["Label": 5])), .missingLabel)
    }

    func testStartIntervalMustBeAPositiveWholeNumber() {
        for value: Any in [0, -5, "60", 1.5, true] {
            XCTAssertEqual(
                error(for: plist(["Label": "com.example.job", "StartInterval": value])),
                .invalid(key: "StartInterval"),
                "\(value)"
            )
        }
    }

    func testCalendarFieldsMustBeInRange() {
        let invalid: [[String: Any]] = [
            ["Minute": 60], ["Minute": -1], ["Hour": 24], ["Day": 0], ["Day": 32],
            ["Weekday": 8], ["Month": 0], ["Month": 13], ["Hour": "2"], ["Hour": true], ["Hour": 2.5]
        ]

        for fields in invalid {
            XCTAssertEqual(
                error(for: plist(["Label": "com.example.job", "StartCalendarInterval": fields])),
                .invalid(key: "StartCalendarInterval"),
                "\(fields)"
            )
        }
    }

    func testCalendarIntervalMustBeADictionaryOrAListOfThem() {
        XCTAssertEqual(
            error(for: plist(["Label": "com.example.job", "StartCalendarInterval": "02:00"])),
            .invalid(key: "StartCalendarInterval")
        )
        XCTAssertEqual(
            error(for: plist(["Label": "com.example.job", "StartCalendarInterval": [["Hour": 2], 3]])),
            .invalid(key: "StartCalendarInterval")
        )
    }

    // MARK: - Descriptions

    func testScheduleDescriptions() {
        let cases: [(LaunchdCalendarInterval, String)] = [
            (LaunchdCalendarInterval(minute: 0, hour: 2), "daily at 02:00"),
            (LaunchdCalendarInterval(minute: 5, hour: 14, weekday: 1), "Mon at 14:05"),
            (LaunchdCalendarInterval(minute: 0, hour: 6, weekday: 0), "Sun at 06:00"),
            (LaunchdCalendarInterval(minute: 0, hour: 6, weekday: 7), "Sun at 06:00"),
            (LaunchdCalendarInterval(minute: 30, hour: 3, day: 1, month: 1), "month 1 day 1 at 03:30"),
            (LaunchdCalendarInterval(hour: 2), "daily, every minute from 02:00 to 02:59"),
            (LaunchdCalendarInterval(minute: 15), "every hour at :15"),
            (LaunchdCalendarInterval(minute: 15, weekday: 6), "Sat, every hour at :15"),
            (LaunchdCalendarInterval(), "every minute"),
            (LaunchdCalendarInterval(day: 15), "day 15, every minute")
        ]

        for (interval, expected) in cases {
            XCTAssertEqual(interval.description, expected)
        }
    }

    func testDefinitionDescriptionJoinsEveryPart() {
        let definition = LaunchdJobDefinition(
            label: "com.example.job",
            calendarIntervals: [LaunchdCalendarInterval(minute: 0, hour: 2), LaunchdCalendarInterval(minute: 0, hour: 14)],
            startInterval: 5400
        )

        XCTAssertEqual(definition.scheduleDescription, "daily at 02:00; daily at 14:00; every 90m")
    }

    func testIntervalsUseTheLargestUnitThatFits() {
        let cases: [(TimeInterval, String)] = [(86400, "every 1d"), (7200, "every 2h"), (900, "every 15m"), (90, "every 90s"), (1, "every 1s")]

        for (seconds, expected) in cases {
            XCTAssertEqual(LaunchdJobDefinition(label: "x", startInterval: seconds).scheduleDescription, expected)
        }
    }

    // MARK: - Helpers

    private func plist(_ value: Any) -> Data {
        (try? PropertyListSerialization.data(fromPropertyList: value, format: .xml, options: 0)) ?? Data()
    }

    private func definition(_ value: [String: Any]) throws -> LaunchdJobDefinition {
        try LaunchdJobDefinition(plist: plist(value))
    }

    private func error(for data: Data) -> LaunchdPlistError? {
        do {
            _ = try LaunchdJobDefinition(plist: data)
            return nil
        } catch {
            return error
        }
    }
}
