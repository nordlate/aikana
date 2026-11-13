import AjoissaCore
import XCTest

/// The scenarios the evaluation exists for. The job in each runs daily at 02:00 with 30 minutes of grace,
/// unless the test says otherwise.
final class JobEvaluatorTests: XCTestCase {
    // MARK: - Ran

    func testRanOnTime() {
        let job = Scenario.watchedSinceYesterday()

        let before = job.evaluate(at: "2026-11-14 02:00:30", Scenario.loaded(runs: 3))
        XCTAssertEqual(before.state, .waiting)
        XCTAssertEqual(before.reason, "the run due at 2026-11-14 02:00 has not been seen yet; it has until 2026-11-14 02:30")

        XCTAssertEqual(job.evaluate(at: "2026-11-14 02:01:30", Scenario.loaded(runs: 4, running: true)).state, .running)

        let after = job.evaluate(at: "2026-11-14 02:05", Scenario.loaded(runs: 4))
        XCTAssertEqual(after.state, .ok)
        XCTAssertEqual(after.reason, "the run due at 2026-11-14 02:00 happened")
        XCTAssertEqual(after.expectedRun, TestClock.date("2026-11-14 02:00"))
        XCTAssertEqual(after.nextRun, TestClock.date("2026-11-15 02:00"))
        XCTAssertTrue(after.changed)

        let later = job.evaluate(at: "2026-11-14 20:00", Scenario.loaded(runs: 4))
        XCTAssertEqual(later.state, .ok)
        XCTAssertFalse(later.changed)
    }

    func testRanLateWithinGrace() {
        let job = Scenario.watchedSinceYesterday()

        XCTAssertEqual(job.evaluate(at: "2026-11-14 02:19", Scenario.loaded(runs: 3)).state, .waiting)
        XCTAssertEqual(job.evaluate(at: "2026-11-14 02:21", Scenario.loaded(runs: 4)).state, .ok)
        XCTAssertFalse(job.record?.transitions.contains { $0.state == .missed } ?? true)
    }

    func testRanAfterGraceIsMissedAndThenFine() {
        let job = Scenario.watchedSinceYesterday()

        XCTAssertEqual(job.evaluate(at: "2026-11-14 02:30", Scenario.loaded(runs: 3)).state, .waiting)
        let missed = job.evaluate(at: "2026-11-14 02:31", Scenario.loaded(runs: 3))
        XCTAssertEqual(missed.state, .missed)
        XCTAssertEqual(missed.reason, "there is no sign of the run that was due at 2026-11-14 02:00")
        XCTAssertEqual(job.evaluate(at: "2026-11-14 02:50", Scenario.loaded(runs: 4)).state, .ok)
    }

    func testLogWrittenAfterTheScheduledTimeShowsTheRun() {
        let job = Scenario.watchedSinceYesterday()

        // The run count is not available, as for a scheduler that does not report one.
        let evaluation = job.evaluate(at: "2026-11-14 03:00", Scenario.loaded(runs: nil, log: "2026-11-14 02:03"))

        XCTAssertEqual(evaluation.state, .ok)
    }

    func testLogWrittenBeforeTheScheduledTimeDoesNot() {
        let job = Scenario.watchedSinceYesterday()

        XCTAssertEqual(job.evaluate(at: "2026-11-14 03:00", Scenario.loaded(runs: nil, log: "2026-11-14 01:30")).state, .missed)
    }

    func testTimestampFromTheFutureProvesNothingLaterThanNow() {
        let job = Scenario.watchedSinceYesterday()

        job.evaluate(at: "2026-11-14 01:00", Scenario.loaded(runs: 3, log: "2026-11-14 05:00"))

        XCTAssertEqual(job.evaluate(at: "2026-11-14 02:40", Scenario.loaded(runs: 3, log: "2026-11-14 05:00")).state, .missed)
    }

    // MARK: - Failed

    func testFailedExit() {
        let job = Scenario.watchedSinceYesterday()

        let failed = job.evaluate(at: "2026-11-14 02:05", Scenario.loaded(runs: 4, exit: .code(3)))
        XCTAssertEqual(failed.state, .failed)
        XCTAssertEqual(failed.reason, "its last run exited with code 3")

        // The next day, until a new run is seen or missed, the failure is still the latest news.
        XCTAssertEqual(job.evaluate(at: "2026-11-15 02:10", Scenario.loaded(runs: 4, exit: .code(3))).state, .failed)
        XCTAssertEqual(job.evaluate(at: "2026-11-15 02:40", Scenario.loaded(runs: 4, exit: .code(3))).state, .missed)
        XCTAssertEqual(job.evaluate(at: "2026-11-15 02:45", Scenario.loaded(runs: 5, exit: .code(0))).state, .ok)
    }

    func testEndedBySignal() {
        let job = Scenario.watchedSinceYesterday()

        let evaluation = job.evaluate(at: "2026-11-14 02:05", Scenario.loaded(runs: 4, exit: .signal("Terminated: 15")))

        XCTAssertEqual(evaluation.state, .failed)
        XCTAssertEqual(evaluation.reason, "its last run was ended by signal Terminated: 15")
    }

    func testJobThatCannotRun() {
        let job = Scenario.watchedSinceYesterday()

        let notLoaded = job.evaluate(at: "2026-11-14 01:00", Evidence(source: SourceEvidence(availability: .notLoaded)))
        XCTAssertEqual(notLoaded.state, .failed)
        XCTAssertEqual(notLoaded.reason, "the scheduler has not loaded this job, so it will not run")

        let missing = job.evaluate(at: "2026-11-14 01:01", Evidence(source: SourceEvidence(availability: .missing)))
        XCTAssertEqual(missing.state, .failed)
        XCTAssertEqual(missing.reason, "the scheduler does not know this job and it has no definition, so it will not run")
    }

    // MARK: - Never ran

    func testNeverRan() {
        let job = Scenario()
        job.evaluate(at: "2026-11-13 12:00", Scenario.loaded(runs: 0, exit: .neverExited))

        XCTAssertEqual(job.evaluate(at: "2026-11-14 02:15", Scenario.loaded(runs: 0, exit: .neverExited)).state, .waiting)
        XCTAssertEqual(job.evaluate(at: "2026-11-14 02:31", Scenario.loaded(runs: 0, exit: .neverExited)).state, .missed)
        XCTAssertEqual(job.evaluate(at: "2026-11-14 23:00", Scenario.loaded(runs: 0, exit: .neverExited)).state, .missed)
    }

    // MARK: - Asleep over the scheduled time

    func testAsleepOverTheScheduledTimeThenCaughtUp() {
        let job = Scenario.watchedSinceYesterday()

        // Woken at 07:00. launchd makes up for the 02:00 run on wake, so the grace counts from the wake.
        let onWake = job.evaluate(at: "2026-11-14 07:00:20", Scenario.loaded(runs: 3, awakeSince: "2026-11-14 07:00"))
        XCTAssertEqual(onWake.state, .waiting)
        XCTAssertEqual(onWake.reason, "the run due at 2026-11-14 02:00 has not been seen yet; it has until 2026-11-14 07:30")

        XCTAssertEqual(job.evaluate(at: "2026-11-14 07:01:20", Scenario.loaded(runs: 4, awakeSince: "2026-11-14 07:00")).state, .ok)
    }

    func testAsleepAndTheRunStartedBeforeTheFirstLookAfterWaking() {
        let job = Scenario.watchedSinceYesterday()

        // Last looked at 23:00. One run was scheduled since, and one started: it is the 02:00 run made up on wake.
        let evaluation = job.evaluate(at: "2026-11-14 07:00:20", Scenario.loaded(runs: 4, awakeSince: "2026-11-14 07:00"))

        XCTAssertEqual(evaluation.state, .ok)
    }

    func testAsleepAndNotCaughtUpIsMissedOnceTheGraceAfterWakingIsOver() {
        let job = Scenario.watchedSinceYesterday()

        XCTAssertEqual(job.evaluate(at: "2026-11-14 07:30", Scenario.loaded(runs: 3, awakeSince: "2026-11-14 07:00")).state, .waiting)
        XCTAssertEqual(job.evaluate(at: "2026-11-14 07:31", Scenario.loaded(runs: 3, awakeSince: "2026-11-14 07:00")).state, .missed)
    }

    func testWakeBeforeTheScheduledTimeDoesNotExtendTheGrace() {
        let job = Scenario.watchedSinceYesterday()

        XCTAssertEqual(job.evaluate(at: "2026-11-14 02:31", Scenario.loaded(runs: 3, awakeSince: "2026-11-14 01:00")).state, .missed)
    }

    // MARK: - Schedule changed

    func testScheduleChangedIsJudgedFromTheChangeOn() {
        let job = Scenario.watchedSinceYesterday()
        job.evaluate(at: "2026-11-14 02:05", Scenario.loaded(runs: 4))
        let at0900 = Timetable(calendarRules: [.init(minute: 0, hour: 9)])

        // Changed at 10:00 to run at 09:00. Today's 09:00 was never scheduled, so it cannot have been missed.
        let changed = job.evaluate(at: "2026-11-14 10:00", Scenario.loaded(runs: 4, timetable: at0900))
        XCTAssertEqual(changed.state, .waiting)
        XCTAssertEqual(changed.reason, "the run due at 2026-11-14 09:00 was before Ajoissa started watching; the next run is due at 2026-11-15 09:00")

        XCTAssertEqual(job.evaluate(at: "2026-11-15 09:20", Scenario.loaded(runs: 4, timetable: at0900)).state, .waiting)
        XCTAssertEqual(job.evaluate(at: "2026-11-15 09:40", Scenario.loaded(runs: 4, timetable: at0900)).state, .missed)
    }

    func testScheduleInTheConfigWinsOverTheSchedulers() throws {
        let job = Scenario(schedule: .daily(at: try XCTUnwrap(TimeOfDay(hour: 5, minute: 0))))
        job.evaluate(at: "2026-11-13 12:00", Scenario.loaded(runs: 3))

        let evaluation = job.evaluate(at: "2026-11-14 03:00", Scenario.loaded(runs: 3))

        XCTAssertEqual(evaluation.expectedRun, TestClock.date("2026-11-13 05:00"))
        XCTAssertEqual(evaluation.nextRun, TestClock.date("2026-11-14 05:00"))
    }

    func testUnreadableStateInBetweenDoesNotCountAsAScheduleChange() {
        let job = Scenario.watchedSinceYesterday()
        let watchingSince = job.record?.watchingSince

        job.evaluate(at: "2026-11-13 23:30", Evidence(source: SourceEvidence(availability: .unknown(reason: "launchctl did not answer in time"))))
        job.evaluate(at: "2026-11-14 02:05", Scenario.loaded(runs: 4))

        XCTAssertEqual(job.record?.watchingSince, watchingSince)
        XCTAssertEqual(job.record?.state, .ok)
    }

    // MARK: - First evaluation

    func testFirstEvaluationDoesNotJudgeARunFromBeforeItWasWatching() {
        let job = Scenario()

        let first = job.evaluate(at: "2026-11-14 12:00", Scenario.loaded(runs: 7))

        XCTAssertEqual(first.state, .waiting)
        XCTAssertEqual(first.reason, "the run due at 2026-11-14 02:00 was before Ajoissa started watching; the next run is due at 2026-11-15 02:00")
        XCTAssertTrue(first.changed)
        XCTAssertEqual(job.record?.watchingSince, TestClock.date("2026-11-14 12:00"))
        // The next scheduled time is the first one that is judged.
        XCTAssertEqual(job.evaluate(at: "2026-11-15 02:31", Scenario.loaded(runs: 7)).state, .missed)
    }

    func testFirstEvaluationBelievesEvidenceThatIsThere() {
        XCTAssertEqual(Scenario().evaluate(at: "2026-11-14 12:00", Scenario.loaded(runs: 7, log: "2026-11-14 02:04")).state, .ok)
        XCTAssertEqual(Scenario().evaluate(at: "2026-11-14 12:00", Scenario.loaded(runs: 7, exit: .code(1))).state, .failed)
    }

    func testFirstEvaluationJustBeforeTheScheduledTimeJudgesIt() {
        let job = Scenario()
        job.evaluate(at: "2026-11-14 01:59:30", Scenario.loaded(runs: 7))

        XCTAssertEqual(job.evaluate(at: "2026-11-14 02:31", Scenario.loaded(runs: 7)).state, .missed)
    }

    // MARK: - Not watched all the time

    func testOneScheduledRunAndOneStartedWhileNotLooking() {
        let job = Scenario()
        job.evaluate(at: "2026-11-12 12:00", Scenario.loaded(runs: 2))
        job.evaluate(at: "2026-11-13 20:00", Scenario.loaded(runs: 3))

        XCTAssertEqual(job.evaluate(at: "2026-11-14 09:00", Scenario.loaded(runs: 4)).state, .ok)
    }

    func testFewerRunsStartedThanWereScheduledWhileNotLooking() {
        let job = Scenario()
        job.evaluate(at: "2026-11-11 12:00", Scenario.loaded(runs: 2))
        job.evaluate(at: "2026-11-12 20:00", Scenario.loaded(runs: 3))

        // Two nights passed and one run started. Which night it was cannot be told, so the latest is not credited.
        XCTAssertEqual(job.evaluate(at: "2026-11-14 09:00", Scenario.loaded(runs: 4)).state, .missed)
    }

    func testRunCountThatStartedOverAfterAReload() {
        let reloaded = Scenario.watchedSinceYesterday()
        XCTAssertEqual(reloaded.evaluate(at: "2026-11-14 02:05", Scenario.loaded(runs: 1)).state, .ok)

        let reloadedAndIdle = Scenario.watchedSinceYesterday()
        XCTAssertEqual(reloadedAndIdle.evaluate(at: "2026-11-14 02:31", Scenario.loaded(runs: 0, exit: .neverExited)).state, .missed)
    }

    // MARK: - Interval

    func testIntervalJob() {
        let every15 = Timetable(interval: 900)
        let job = Scenario(grace: 300)

        let first = job.evaluate(at: "2026-11-14 12:00", Scenario.loaded(runs: 10, timetable: every15))
        XCTAssertEqual(first.state, .waiting)
        XCTAssertEqual(first.reason, "no run has been seen yet; one is expected by 2026-11-14 12:20")
        XCTAssertNil(first.expectedRun)

        let ran = job.evaluate(at: "2026-11-14 12:10", Scenario.loaded(runs: 11, timetable: every15))
        XCTAssertEqual(ran.state, .ok)
        XCTAssertEqual(ran.reason, "it has run since 2026-11-14 11:50")

        XCTAssertEqual(job.evaluate(at: "2026-11-14 12:19", Scenario.loaded(runs: 11, timetable: every15)).state, .ok)
        let missed = job.evaluate(at: "2026-11-14 12:31", Scenario.loaded(runs: 11, timetable: every15))
        XCTAssertEqual(missed.state, .missed)
        XCTAssertEqual(missed.reason, "there is no sign of a run since 2026-11-14 12:11")
    }

    func testIntervalJobIsNotMissedRightAfterWaking() {
        let every15 = Timetable(interval: 900)
        let job = Scenario(grace: 300)
        job.evaluate(at: "2026-11-13 22:00", Scenario.loaded(runs: 10, timetable: every15))
        job.evaluate(at: "2026-11-13 22:10", Scenario.loaded(runs: 11, timetable: every15))

        // Time asleep does not count towards the interval.
        XCTAssertEqual(job.evaluate(at: "2026-11-14 07:05", Scenario.loaded(runs: 11, timetable: every15, awakeSince: "2026-11-14 07:00")).state, .waiting)
        XCTAssertEqual(job.evaluate(at: "2026-11-14 07:21", Scenario.loaded(runs: 11, timetable: every15, awakeSince: "2026-11-14 07:00")).state, .missed)
    }

    func testCalendarRulesDecideWhenATimetableHasBoth() {
        let both = Timetable(calendarRules: [.init(minute: 0, hour: 2)], interval: 900)
        let job = Scenario()
        job.evaluate(at: "2026-11-13 12:00", Scenario.loaded(runs: 3, timetable: both))

        XCTAssertEqual(job.evaluate(at: "2026-11-14 01:00", Scenario.loaded(runs: 3, timetable: both)).expectedRun, TestClock.date("2026-11-13 02:00"))
    }

    // MARK: - No timetable

    func testJobWithoutATimetableIsJudgedByItsLastResult() {
        let none = Timetable()

        let fine = Scenario().evaluate(at: "2026-11-14 12:00", Scenario.loaded(runs: 1, exit: .neverExited, timetable: none))
        XCTAssertEqual(fine.state, .ok)
        XCTAssertEqual(fine.reason, "it has no timetable, and nothing is known to be wrong")

        XCTAssertEqual(Scenario().evaluate(at: "2026-11-14 12:00", Scenario.loaded(runs: 1, running: true, timetable: none)).state, .running)
        XCTAssertEqual(Scenario().evaluate(at: "2026-11-14 12:00", Scenario.loaded(runs: 4, exit: .code(2), timetable: none)).state, .failed)
    }

    func testRuleThatNeverMatchesIsTreatedAsNoTimetable() {
        let never = Timetable(calendarRules: [.init(day: 30, month: 2)])

        XCTAssertEqual(Scenario().evaluate(at: "2026-11-14 12:00", Scenario.loaded(runs: 0, exit: .neverExited, timetable: never)).state, .ok)
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
