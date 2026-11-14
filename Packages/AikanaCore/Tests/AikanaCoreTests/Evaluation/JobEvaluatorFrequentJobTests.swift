import AikanaCore
import XCTest

/// Jobs that run often, runs nobody scheduled, and clocks that change.
final class JobEvaluatorFrequentJobTests: XCTestCase {
    // MARK: - Jobs that run often

    func testStoppedHourlyJobIsMissedOnceAndStaysMissed() {
        let hourly = Timetable(calendarRules: [.init(minute: 0)])
        let job = Scenario()
        job.evaluate(at: "2026-11-14 09:30", Scenario.loaded(runs: 5, timetable: hourly))
        XCTAssertEqual(job.evaluate(at: "2026-11-14 10:01", Scenario.loaded(runs: 6, timetable: hourly)).state, .ok)

        // It stops. Every hour brings a new scheduled time, but the verdict is about the oldest open one.
        XCTAssertEqual(job.evaluate(at: "2026-11-14 11:10", Scenario.loaded(runs: 6, timetable: hourly)).state, .waiting)
        let missed = job.evaluate(at: "2026-11-14 11:31", Scenario.loaded(runs: 6, timetable: hourly))
        XCTAssertEqual(missed.state, .missed)
        XCTAssertEqual(missed.reason, "there is no sign of the run that was due at 2026-11-14 11:00")

        for moment in ["2026-11-14 12:01", "2026-11-14 12:31", "2026-11-14 13:10", "2026-11-15 09:00"] {
            let later = job.evaluate(at: moment, Scenario.loaded(runs: 6, timetable: hourly))
            XCTAssertEqual(later.state, .missed, moment)
            XCTAssertFalse(later.changed, moment)
            XCTAssertEqual(later.expectedRun, TestClock.date("2026-11-14 11:00"), moment)
        }
        XCTAssertEqual(job.evaluate(at: "2026-11-15 09:05", Scenario.loaded(runs: 7, timetable: hourly)).state, .ok)
    }

    func testStoppedJobThatRunsMoreOftenThanItsGraceIsMissed() {
        let everyMinute = Timetable(calendarRules: [.init()])
        let job = Scenario()
        job.evaluate(at: "2026-11-14 09:30", Scenario.loaded(runs: 100, timetable: everyMinute))
        XCTAssertEqual(job.evaluate(at: "2026-11-14 09:31", Scenario.loaded(runs: 101, timetable: everyMinute)).state, .ok)

        XCTAssertEqual(job.evaluate(at: "2026-11-14 10:00", Scenario.loaded(runs: 101, timetable: everyMinute)).state, .waiting)
        XCTAssertEqual(job.evaluate(at: "2026-11-14 10:05", Scenario.loaded(runs: 101, timetable: everyMinute)).state, .missed)
        XCTAssertEqual(job.evaluate(at: "2026-11-14 18:00", Scenario.loaded(runs: 101, timetable: everyMinute)).state, .missed)
    }

    func testJobThatRunsEveryMinuteIsCheapToEvaluateAfterADayAway() {
        let everyMinute = Timetable(calendarRules: [.init()])
        let job = Scenario()
        job.evaluate(at: "2026-11-13 09:30", Scenario.loaded(runs: 100, timetable: everyMinute))
        let started = Date()

        job.evaluate(at: "2026-11-14 09:30", Scenario.loaded(runs: 101, timetable: everyMinute))

        XCTAssertLessThan(Date().timeIntervalSince(started), 0.2)
    }

    // MARK: - Runs that last long

    /// An hourly job whose runs take 70 minutes. launchd does not start a job that is still running, so every
    /// second scheduled time has no run of its own. That is not a missed run.
    func testRunStillInProgressAccountsForTheScheduledTimeItRunsThrough() {
        let hourly = Timetable(calendarRules: [.init(minute: 0)])
        let job = Scenario()
        job.evaluate(at: "2026-11-14 01:30", Scenario.loaded(runs: 5, timetable: hourly))
        var states: [JobState] = []

        // Runs from 02:00 to 03:10 and from 04:00 to 05:10, looked at every ten minutes.
        for minute in stride(from: 120, through: 330, by: 10) {
            let running = (120..<190).contains(minute) || (240..<310).contains(minute)
            let runs = minute < 120 ? 5 : (minute < 240 ? 6 : 7)
            let moment = String(format: "2026-11-14 %02d:%02d", minute / 60, minute % 60)
            states.append(job.evaluate(at: moment, Scenario.loaded(runs: runs, running: running, timetable: hourly)).state)
        }

        XCTAssertFalse(states.contains(.missed), "\(states)")
        XCTAssertFalse(states.contains(.waiting), "\(states)")
        XCTAssertEqual(Set(states), [.running, .ok])
    }

    func testIntervalJobWithARunLongerThanItsIntervalIsNotMissedWhenItEnds() {
        let hourly = Timetable(interval: 3600)
        let job = Scenario()
        job.evaluate(at: "2026-11-14 09:50", Scenario.loaded(runs: 5, timetable: hourly))
        XCTAssertEqual(job.evaluate(at: "2026-11-14 10:01", Scenario.loaded(runs: 6, running: true, timetable: hourly)).state, .running)
        XCTAssertEqual(job.evaluate(at: "2026-11-14 11:44", Scenario.loaded(runs: 6, running: true, timetable: hourly)).state, .running)

        // The run ended at 11:45, long after the interval from its start was over.
        XCTAssertEqual(job.evaluate(at: "2026-11-14 11:46", Scenario.loaded(runs: 6, timetable: hourly)).state, .ok)
        XCTAssertEqual(job.evaluate(at: "2026-11-14 13:14", Scenario.loaded(runs: 6, timetable: hourly)).state, .ok)
        XCTAssertEqual(job.evaluate(at: "2026-11-14 13:16", Scenario.loaded(runs: 6, timetable: hourly)).state, .missed)
    }

    func testOverdueIntervalJobStaysMissedThroughAWake() {
        let hourly = Timetable(interval: 3600)
        let job = Scenario()
        job.evaluate(at: "2026-11-14 09:59", Scenario.loaded(runs: 5, timetable: hourly))
        job.evaluate(at: "2026-11-14 10:00", Scenario.loaded(runs: 6, timetable: hourly))
        XCTAssertEqual(job.evaluate(at: "2026-11-14 11:31", Scenario.loaded(runs: 6, timetable: hourly)).state, .missed)
        job.evaluate(at: "2026-11-14 11:39", Scenario.loaded(runs: 6, timetable: hourly))

        // Asleep from 11:40 to 11:45. Five minutes of sleep do not undo ninety minutes without a run.
        for moment in ["2026-11-14 11:50", "2026-11-14 12:30", "2026-11-14 13:16"] {
            let evaluation = job.evaluate(at: moment, Scenario.loaded(runs: 6, timetable: hourly, awakeSince: "2026-11-14 11:45"))
            XCTAssertEqual(evaluation.state, .missed, moment)
            XCTAssertFalse(evaluation.changed, moment)
        }
    }

    // MARK: - Runs nobody scheduled

    func testRunStartedByHandDoesNotStandInForTheScheduledOne() {
        let job = Scenario.watchedSinceYesterday()
        job.evaluate(at: "2026-11-13 23:29", Scenario.loaded(runs: 3))

        // Started by hand at 23:30. It is a run, but not the one due at 02:00.
        XCTAssertEqual(job.evaluate(at: "2026-11-13 23:31", Scenario.loaded(runs: 4)).state, .ok)
        XCTAssertEqual(job.evaluate(at: "2026-11-14 02:31", Scenario.loaded(runs: 4)).state, .missed)
    }

    func testLateRunStartedByHandClearsTheMiss() {
        let job = Scenario.watchedSinceYesterday()
        job.evaluate(at: "2026-11-14 02:31", Scenario.loaded(runs: 3))
        job.evaluate(at: "2026-11-14 09:59", Scenario.loaded(runs: 3))

        let evaluation = job.evaluate(at: "2026-11-14 10:01", Scenario.loaded(runs: 4))

        XCTAssertEqual(evaluation.state, .ok)
        XCTAssertEqual(evaluation.reason, "the run due at 2026-11-14 02:00 happened")
    }

    // MARK: - Clock changes

    /// In Helsinki the clocks go from 03:00 to 04:00 on 2026-03-29, so a job set for 03:30 has no such time
    /// that day. It is expected at 04:30 instead.
    func testScheduledTimeThatDoesNotExistWhenClocksGoForward() {
        let job = Scenario()
        job.calendar = TestClock.calendar(timeZone: "Europe/Helsinki")
        let at0330 = Timetable(calendarRules: [.init(minute: 30, hour: 3)])
        job.evaluate(at: "2026-03-28 12:00", Scenario.loaded(runs: 3, timetable: at0330))

        XCTAssertEqual(job.evaluate(at: "2026-03-29 04:20", Scenario.loaded(runs: 3, timetable: at0330)).state, .waiting)
        let evaluation = job.evaluate(at: "2026-03-29 04:35", Scenario.loaded(runs: 4, timetable: at0330))
        XCTAssertEqual(evaluation.state, .ok)
        XCTAssertEqual(evaluation.reason, "the run due at 2026-03-29 04:30 happened")
    }

    /// On 2026-10-25 the clocks go back from 04:00 to 03:00, so 03:30 comes twice. One run is enough.
    func testScheduledTimeThatComesTwiceWhenClocksGoBack() {
        let job = Scenario()
        job.calendar = TestClock.calendar(timeZone: "Europe/Helsinki")
        let at0330 = Timetable(calendarRules: [.init(minute: 30, hour: 3)])
        job.evaluate(at: "2026-10-24 12:00", Scenario.loaded(runs: 3, timetable: at0330))
        job.evaluate(at: "2026-10-25 02:59", Scenario.loaded(runs: 3, timetable: at0330))

        // 00:35 UTC is five minutes after the first 03:30 local time. The second comes an hour later.
        XCTAssertEqual(job.evaluate(at: TestClock.date("2026-10-25 00:35"), Scenario.loaded(runs: 4, timetable: at0330)).state, .ok)
        XCTAssertEqual(job.evaluate(at: TestClock.date("2026-10-25 01:35"), Scenario.loaded(runs: 4, timetable: at0330)).state, .ok)
        XCTAssertEqual(job.evaluate(at: "2026-10-25 05:00", Scenario.loaded(runs: 4, timetable: at0330)).state, .ok)
        XCTAssertEqual(job.evaluate(at: "2026-10-25 12:00", Scenario.loaded(runs: 4, timetable: at0330)).state, .ok)
    }

    // MARK: - Time zone

    func testTimetableIsReadInTheGivenTimeZone() {
        let job = Scenario()
        job.calendar = TestClock.calendar(timeZone: "Europe/Helsinki")
        job.evaluate(at: "2026-11-13 12:00", Scenario.loaded(runs: 3))

        let evaluation = job.evaluate(at: "2026-11-14 02:31", Scenario.loaded(runs: 3))

        // 02:00 in Helsinki is 00:00 UTC in November.
        XCTAssertEqual(evaluation.expectedRun, TestClock.date("2026-11-14 00:00"))
        XCTAssertEqual(evaluation.reason, "there is no sign of the run that was due at 2026-11-14 02:00")
    }
}
