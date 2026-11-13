import AjoissaCore
import XCTest

final class TimetableTests: XCTestCase {
    private let utc = TestClock.calendar(timeZone: "UTC")

    // MARK: - Building

    func testFromConfigSchedules() throws {
        let time = try XCTUnwrap(TimeOfDay(hour: 2, minute: 5))

        XCTAssertEqual(Timetable(schedule: .daily(at: time)), Timetable(calendarRules: [.init(minute: 5, hour: 2)]))
        XCTAssertEqual(Timetable(schedule: .weekly(on: .sun, at: time)), Timetable(calendarRules: [.init(minute: 5, hour: 2, weekday: 0)]))
        XCTAssertEqual(Timetable(schedule: .weekly(on: .sat, at: time)), Timetable(calendarRules: [.init(minute: 5, hour: 2, weekday: 6)]))
        XCTAssertEqual(Timetable(schedule: .every(900)), Timetable(interval: 900))
    }

    func testFromLaunchdDefinition() {
        let definition = LaunchdJobDefinition(
            label: "com.example.job",
            calendarIntervals: [LaunchdCalendarInterval(minute: 0, hour: 2), LaunchdCalendarInterval(weekday: 7)],
            startInterval: 3600
        )

        XCTAssertEqual(Timetable(definition: definition), Timetable(
            calendarRules: [.init(minute: 0, hour: 2), .init(weekday: 7)],
            interval: 3600
        ))
        XCTAssertTrue(Timetable(definition: LaunchdJobDefinition(label: "x")).isEmpty)
    }

    // MARK: - Occurrences

    func testDailyOccurrences() {
        let daily = Timetable(calendarRules: [.init(minute: 0, hour: 2)])

        XCTAssertEqual(last(daily, "2026-11-14 01:59"), "2026-11-13 02:00")
        XCTAssertEqual(last(daily, "2026-11-14 02:00"), "2026-11-14 02:00")
        XCTAssertEqual(last(daily, "2026-11-14 02:01"), "2026-11-14 02:00")
        XCTAssertEqual(next(daily, "2026-11-14 01:59"), "2026-11-14 02:00")
        XCTAssertEqual(next(daily, "2026-11-14 02:00"), "2026-11-15 02:00")
    }

    func testWeeklyOccurrencesAndBothNumbersForSunday() {
        // 2026-11-15 is a Sunday.
        for sunday in [0, 7] {
            let weekly = Timetable(calendarRules: [.init(minute: 30, hour: 6, weekday: sunday)])

            XCTAssertEqual(last(weekly, "2026-11-14 12:00"), "2026-11-08 06:30")
            XCTAssertEqual(next(weekly, "2026-11-14 12:00"), "2026-11-15 06:30")
        }
        let monday = Timetable(calendarRules: [.init(minute: 0, hour: 9, weekday: 1)])
        XCTAssertEqual(next(monday, "2026-11-14 12:00"), "2026-11-16 09:00")
    }

    func testMissingFieldsMatchEveryValue() {
        let everyMinuteOfHourTwo = Timetable(calendarRules: [.init(hour: 2)])
        XCTAssertEqual(last(everyMinuteOfHourTwo, "2026-11-14 02:17"), "2026-11-14 02:17")
        XCTAssertEqual(last(everyMinuteOfHourTwo, "2026-11-14 05:00"), "2026-11-14 02:59")

        let hourly = Timetable(calendarRules: [.init(minute: 15)])
        XCTAssertEqual(last(hourly, "2026-11-14 05:00"), "2026-11-14 04:15")
        XCTAssertEqual(next(hourly, "2026-11-14 05:00"), "2026-11-14 05:15")

        let monthly = Timetable(calendarRules: [.init(minute: 0, hour: 3, day: 1)])
        XCTAssertEqual(last(monthly, "2026-11-14 05:00"), "2026-11-01 03:00")
        XCTAssertEqual(next(monthly, "2026-11-14 05:00"), "2026-12-01 03:00")

        let everyHourOnThe15th = Timetable(calendarRules: [.init(minute: 15, day: 15)])
        XCTAssertEqual(last(everyHourOnThe15th, "2026-11-20 05:00"), "2026-11-15 23:15")
        XCTAssertEqual(next(everyHourOnThe15th, "2026-11-15 05:20"), "2026-11-15 06:15")

        let everyMinute = Timetable(calendarRules: [.init()])
        XCTAssertEqual(last(everyMinute, "2026-11-14 05:00:30"), "2026-11-14 05:00")
        XCTAssertEqual(next(everyMinute, "2026-11-14 05:00:30"), "2026-11-14 05:01")
    }

    func testYearlyRuleAndRuleThatNeverMatches() {
        let yearly = Timetable(calendarRules: [.init(minute: 30, hour: 3, day: 1, month: 1)])
        XCTAssertEqual(last(yearly, "2026-11-14 05:00"), "2026-01-01 03:30")
        XCTAssertEqual(next(yearly, "2026-11-14 05:00"), "2027-01-01 03:30")

        let leapDay = Timetable(calendarRules: [.init(minute: 0, hour: 0, day: 29, month: 2)])
        XCTAssertEqual(last(leapDay, "2026-11-14 05:00"), "2024-02-29 00:00")
        XCTAssertEqual(next(leapDay, "2026-11-14 05:00"), "2028-02-29 00:00")

        let never = Timetable(calendarRules: [.init(minute: 0, hour: 0, day: 30, month: 2)])
        XCTAssertNil(last(never, "2026-11-14 05:00"))
        XCTAssertNil(next(never, "2026-11-14 05:00"))
    }

    func testSeveralRulesGiveTheNearestOccurrence() {
        let twiceADay = Timetable(calendarRules: [.init(minute: 0, hour: 2), .init(minute: 0, hour: 14)])

        XCTAssertEqual(last(twiceADay, "2026-11-14 12:00"), "2026-11-14 02:00")
        XCTAssertEqual(last(twiceADay, "2026-11-14 15:00"), "2026-11-14 14:00")
        XCTAssertEqual(next(twiceADay, "2026-11-14 15:00"), "2026-11-15 02:00")
    }

    func testOccurrenceCount() {
        let daily = Timetable(calendarRules: [.init(minute: 0, hour: 2)])
        let count = { (start: String, end: String) in
            daily.calendarOccurrenceCount(after: TestClock.date(start), through: TestClock.date(end), calendar: self.utc)
        }

        XCTAssertEqual(count("2026-11-14 02:00", "2026-11-14 23:00"), 0)
        XCTAssertEqual(count("2026-11-14 01:00", "2026-11-14 02:00"), 1)
        XCTAssertEqual(count("2026-11-10 12:00", "2026-11-14 12:00"), 4)
    }

    func testOccurrenceCountStopsAtItsLimit() {
        let everyMinute = Timetable(calendarRules: [.init()])

        XCTAssertEqual(everyMinute.calendarOccurrenceCount(
            after: TestClock.date("2026-11-01 00:00"),
            through: TestClock.date("2026-11-14 00:00"),
            calendar: utc,
            limit: 25
        ), 25)
    }

    func testNoCalendarRulesHaveNoOccurrences() {
        let interval = Timetable(interval: 900)

        XCTAssertNil(interval.lastCalendarOccurrence(onOrBefore: TestClock.date("2026-11-14 12:00"), calendar: utc))
        XCTAssertNil(interval.nextCalendarOccurrence(after: TestClock.date("2026-11-14 12:00"), calendar: utc))
        XCTAssertFalse(interval.isEmpty)
        XCTAssertTrue(Timetable().isEmpty)
    }

    /// In Helsinki the clocks go from 03:00 to 04:00 on 2026-03-29, so 03:30 does not exist that day.
    func testTimeThatDoesNotExistOnTheDayClocksGoForward() {
        let helsinki = TestClock.calendar(timeZone: "Europe/Helsinki")
        let daily = Timetable(calendarRules: [.init(minute: 30, hour: 3)])
        let noon = TestClock.date("2026-03-29 12:00", calendar: helsinki)

        let occurrence = daily.lastCalendarOccurrence(onOrBefore: noon, calendar: helsinki)

        XCTAssertEqual(occurrence.map { TestClock.stamp($0, calendar: helsinki) }, "2026-03-29 04:30")
    }

    // MARK: - Helpers

    private func last(_ timetable: Timetable, _ date: String) -> String? {
        timetable.lastCalendarOccurrence(onOrBefore: TestClock.date(date), calendar: utc).map { TestClock.stamp($0) }
    }

    private func next(_ timetable: Timetable, _ date: String) -> String? {
        timetable.nextCalendarOccurrence(after: TestClock.date(date), calendar: utc).map { TestClock.stamp($0) }
    }
}
