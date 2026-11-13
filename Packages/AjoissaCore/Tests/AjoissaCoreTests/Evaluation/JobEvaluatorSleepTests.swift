import AjoissaCore
import XCTest

/// What happens to the verdict when the Mac sleeps, restarts or the job is reloaded. The job runs daily at
/// 02:00 with 30 minutes of grace.
final class JobEvaluatorSleepTests: XCTestCase {
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

    /// 2026-11-13 is a Friday. The Mac sleeps from Friday evening to Monday morning, through three scheduled
    /// times. launchd makes up for all of them with one run on wake.
    func testAsleepThroughSeveralScheduledTimesNeedsOnlyOneRunOnWake() {
        let job = Scenario.watchedSinceYesterday()

        let onWake = job.evaluate(at: "2026-11-16 08:00:20", Scenario.loaded(runs: 3, awakeSince: "2026-11-16 08:00"))
        XCTAssertEqual(onWake.state, .waiting)
        XCTAssertEqual(onWake.reason, "the run due at 2026-11-14 02:00 has not been seen yet; it has until 2026-11-16 08:30")

        XCTAssertEqual(job.evaluate(at: "2026-11-16 08:05", Scenario.loaded(runs: 4, awakeSince: "2026-11-16 08:00")).state, .ok)
        XCTAssertEqual(job.evaluate(at: "2026-11-16 08:31", Scenario.loaded(runs: 4, awakeSince: "2026-11-16 08:00")).state, .ok)
        XCTAssertEqual(job.evaluate(at: "2026-11-16 20:00", Scenario.loaded(runs: 4, awakeSince: "2026-11-16 08:00")).state, .ok)
    }

    func testAsleepThroughSeveralScheduledTimesAndTheRunWasAlreadyDoneAtTheFirstLook() {
        let job = Scenario.watchedSinceYesterday()

        XCTAssertEqual(job.evaluate(at: "2026-11-16 08:05", Scenario.loaded(runs: 4, awakeSince: "2026-11-16 08:00")).state, .ok)
    }

    func testAsleepThroughSeveralScheduledTimesAndNoRunOnWakeIsMissedOnce() {
        let job = Scenario.watchedSinceYesterday()

        XCTAssertEqual(job.evaluate(at: "2026-11-16 08:30", Scenario.loaded(runs: 3, awakeSince: "2026-11-16 08:00")).state, .waiting)
        let missed = job.evaluate(at: "2026-11-16 08:31", Scenario.loaded(runs: 3, awakeSince: "2026-11-16 08:00"))
        XCTAssertEqual(missed.state, .missed)
        XCTAssertEqual(missed.reason, "there is no sign of the run that was due at 2026-11-14 02:00")
    }

    /// Once a run is missed, waking the Mac again must not give it a new grace period. Nothing was slept
    /// through after 02:00: the Mac was awake then and the run did not come.
    func testWakeAfterARunWasAlreadyMissedChangesNothing() {
        let job = Scenario.watchedSinceYesterday()
        XCTAssertEqual(job.evaluate(at: "2026-11-14 02:00:30", Scenario.loaded(runs: 3)).state, .waiting)
        XCTAssertEqual(job.evaluate(at: "2026-11-14 02:31", Scenario.loaded(runs: 3)).state, .missed)
        job.evaluate(at: "2026-11-14 09:59", Scenario.loaded(runs: 3))

        // Asleep from 10:00 to 10:05, and again later.
        for (moment, woke) in [("2026-11-14 10:06", "2026-11-14 10:05"), ("2026-11-14 10:36", "2026-11-14 10:05"), ("2026-11-14 11:06", "2026-11-14 11:05")] {
            let evaluation = job.evaluate(at: moment, Scenario.loaded(runs: 3, awakeSince: woke))
            XCTAssertEqual(evaluation.state, .missed, moment)
            XCTAssertFalse(evaluation.changed, moment)
        }
    }

    func testWakeAfterARunWasAlreadyMissedDoesNotBringBackAnOldFailure() {
        let job = Scenario.watchedSinceYesterday()
        job.evaluate(at: "2026-11-13 23:30", Scenario.loaded(runs: 3, exit: .code(1)))
        XCTAssertEqual(job.evaluate(at: "2026-11-14 02:31", Scenario.loaded(runs: 3, exit: .code(1))).state, .missed)

        XCTAssertEqual(job.evaluate(at: "2026-11-14 10:06", Scenario.loaded(runs: 3, exit: .code(1), awakeSince: "2026-11-14 10:05")).state, .missed)
    }

    /// Awake at 02:00 and asleep from 02:10. The run had ten minutes to start and did not; sleeping afterwards
    /// does not excuse it.
    func testSleepThatBeginsAfterTheScheduledTimeDoesNotExtendTheGrace() {
        let job = Scenario.watchedSinceYesterday()
        XCTAssertEqual(job.evaluate(at: "2026-11-14 02:09", Scenario.loaded(runs: 3)).state, .waiting)

        XCTAssertEqual(job.evaluate(at: "2026-11-14 07:01", Scenario.loaded(runs: 3, awakeSince: "2026-11-14 07:00")).state, .missed)
    }

    /// A Mac that was switched off does not make up for the scheduled time. That is reported: the job did not
    /// run, even though nothing is wrong with it.
    func testSwitchedOffOverTheScheduledTimeIsMissedAfterTheGraceFromStarting() {
        let job = Scenario.watchedSinceYesterday()
        let started = "2026-11-14 08:00"

        XCTAssertEqual(job.evaluate(at: "2026-11-14 08:05", Scenario.loaded(runs: 0, exit: .neverExited, awakeSince: started, bootedAt: started)).state, .waiting)
        XCTAssertEqual(job.evaluate(at: "2026-11-14 08:31", Scenario.loaded(runs: 0, exit: .neverExited, awakeSince: started, bootedAt: started)).state, .missed)
    }

    // MARK: - Restart and reload

    func testRestartWhereTheRunCountComesBackTheSame() {
        let job = Scenario()
        job.evaluate(at: "2026-11-12 12:00", Scenario.loaded(runs: 0, exit: .neverExited))
        job.evaluate(at: "2026-11-13 02:01", Scenario.loaded(runs: 1))
        job.evaluate(at: "2026-11-13 23:00", Scenario.loaded(runs: 1))

        // Restarted at 01:00, so the count went back to 0, and the 02:00 run took it to 1 again.
        let restarted = "2026-11-14 01:00"
        let evaluation = job.evaluate(at: "2026-11-14 02:05", Scenario.loaded(runs: 1, awakeSince: restarted, bootedAt: restarted))

        XCTAssertEqual(evaluation.state, .ok)
    }

    func testRestartWithNoRunSinceIsNotTakenForARun() {
        let job = Scenario.watchedSinceYesterday()
        let restarted = "2026-11-14 01:00"

        XCTAssertEqual(job.evaluate(at: "2026-11-14 02:31", Scenario.loaded(runs: 0, exit: .neverExited, awakeSince: restarted, bootedAt: restarted)).state, .missed)
    }

    func testJobLoadedAgainIsJudgedFromThenOn() {
        let job = Scenario.watchedSinceYesterday()
        XCTAssertEqual(job.evaluate(at: "2026-11-13 23:30", Evidence(source: SourceEvidence(availability: .notLoaded))).state, .failed)
        XCTAssertEqual(job.evaluate(at: "2026-11-14 12:00", Evidence(source: SourceEvidence(availability: .notLoaded))).state, .failed)

        // Loaded again at noon. It could not run at 02:00, so that is not a missed run.
        let loaded = job.evaluate(at: "2026-11-14 12:01", Scenario.loaded(runs: 0, exit: .neverExited))
        XCTAssertEqual(loaded.state, .waiting)
        XCTAssertEqual(loaded.reason, "the run due at 2026-11-14 02:00 was before Ajoissa started watching; the next run is due at 2026-11-15 02:00")

        XCTAssertEqual(job.evaluate(at: "2026-11-15 02:31", Scenario.loaded(runs: 0, exit: .neverExited)).state, .missed)
    }

    // MARK: - Timetable that could not be read

    func testTimetableThatCannotBeReadThisTimeIsNotTakenForNoTimetable() {
        let job = Scenario.watchedSinceYesterday()

        // The job is loaded but its plist could not be read. The timetable it had still applies.
        let evaluation = job.evaluate(at: "2026-11-14 09:00", Scenario.loaded(runs: 3, timetable: nil))

        XCTAssertEqual(evaluation.state, .missed)
        XCTAssertEqual(job.record?.watchingSince, TestClock.date("2026-11-12 12:00"))
    }

    func testTimetableThatHasNeverBeenReadIsUnknown() {
        let evaluation = Scenario().evaluate(at: "2026-11-14 09:00", Scenario.loaded(runs: 3, timetable: nil))

        XCTAssertEqual(evaluation.state, .unknown)
        XCTAssertEqual(evaluation.reason, "its timetable could not be read")
    }
}
