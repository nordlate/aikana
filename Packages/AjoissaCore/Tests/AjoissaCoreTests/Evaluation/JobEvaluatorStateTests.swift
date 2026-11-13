import AjoissaCore
import XCTest

/// Checks, unreadable state, offline hosts and what the record keeps.
final class JobEvaluatorStateTests: XCTestCase {
    private let passed = CheckOutcome(result: .passed)
    private let fileIsNew = CheckOutcome(result: .passed, provesRun: true)
    private let fileIsOld = CheckOutcome(result: .failed("no file in ~/Reports is newer than 2026-11-14 02:00"), provesRun: true)
    private let tooSmall = CheckOutcome(result: .failed("the backup is 3 KB, less than 500 MB"))
    private let unreachable = CheckOutcome(result: .couldNotRun("the check timed out after 30s"))

    // MARK: - Checks on a job with a scheduler

    func testCheckThatProvesTheRunCountsAsTheRun() {
        let job = Scenario.watchedSinceYesterday()

        // No run was seen, but the file it writes is newer than its scheduled time.
        XCTAssertEqual(job.evaluate(at: "2026-11-14 03:00", Scenario.loaded(runs: 3, checks: [fileIsNew])).state, .ok)
    }

    func testCheckThatMerelyPassesDoesNotStandInForTheRun() {
        let job = Scenario.watchedSinceYesterday()

        XCTAssertEqual(job.evaluate(at: "2026-11-14 03:00", Scenario.loaded(runs: 3, checks: [passed])).state, .missed)
    }

    func testFailedCheckAfterACleanExitIsAFailure() {
        let job = Scenario.watchedSinceYesterday()

        let evaluation = job.evaluate(at: "2026-11-14 02:05", Scenario.loaded(runs: 4, checks: [passed, tooSmall]))

        XCTAssertEqual(evaluation.state, .failed)
        XCTAssertEqual(evaluation.reason, "the backup is 3 KB, less than 500 MB")
    }

    func testBadExitIsReportedBeforeAFailedCheck() {
        let job = Scenario.watchedSinceYesterday()

        let evaluation = job.evaluate(at: "2026-11-14 02:05", Scenario.loaded(runs: 4, exit: .code(1), checks: [tooSmall]))

        XCTAssertEqual(evaluation.reason, "its last run exited with code 1")
    }

    func testFailingCheckWhileTheRunStillHasTimeIsNotAFailure() {
        let job = Scenario.watchedSinceYesterday()

        XCTAssertEqual(job.evaluate(at: "2026-11-14 02:10", Scenario.loaded(runs: 3, checks: [fileIsOld])).state, .waiting)
        XCTAssertEqual(job.evaluate(at: "2026-11-14 02:31", Scenario.loaded(runs: 3, checks: [fileIsOld])).state, .missed)
    }

    func testCheckThatCouldNotBeCarriedOutIsUnknownNotFailed() {
        let job = Scenario.watchedSinceYesterday()

        let evaluation = job.evaluate(at: "2026-11-14 02:05", Scenario.loaded(runs: 4, checks: [unreachable]))

        XCTAssertEqual(evaluation.state, .unknown)
        XCTAssertEqual(evaluation.reason, "the check timed out after 30s")
        XCTAssertEqual(job.evaluate(at: "2026-11-14 02:06", Scenario.loaded(runs: 4, checks: [unreachable, tooSmall])).state, .failed)
    }

    // MARK: - A job known only through its checks

    func testJobWithoutASchedulerIsJudgedByItsChecks() throws {
        let job = Scenario(source: nil, schedule: .daily(at: try XCTUnwrap(TimeOfDay(hour: 2, minute: 0))))

        XCTAssertEqual(job.evaluate(at: "2026-11-14 02:10", Evidence(checks: [fileIsOld])).state, .waiting)
        XCTAssertEqual(job.evaluate(at: "2026-11-14 02:20", Evidence(checks: [fileIsNew])).state, .ok)

        let failed = job.evaluate(at: "2026-11-15 02:31", Evidence(checks: [fileIsOld]))
        XCTAssertEqual(failed.state, .failed)
        XCTAssertEqual(failed.reason, "no file in ~/Reports is newer than 2026-11-14 02:00")

        XCTAssertEqual(job.evaluate(at: "2026-11-15 02:32", Evidence(checks: [unreachable])).state, .unknown)
        XCTAssertEqual(job.evaluate(at: "2026-11-15 02:33", Evidence(checks: [passed])).state, .ok)
    }

    // MARK: - Unreadable and offline

    func testUnreadableStateIsUnknownAndStaleAfterADay() {
        let job = Scenario.watchedSinceYesterday()
        let unreadable = Evidence(source: SourceEvidence(availability: .unknown(reason: "launchctl did not answer in time")))

        let first = job.evaluate(at: "2026-11-14 01:00", unreadable)
        XCTAssertEqual(first.state, .unknown)
        XCTAssertEqual(first.reason, "launchctl did not answer in time")
        XCTAssertFalse(first.state.isProblem)

        XCTAssertEqual(job.evaluate(at: "2026-11-15 00:59", unreadable).state, .unknown)
        let stale = job.evaluate(at: "2026-11-15 01:00", unreadable)
        XCTAssertEqual(stale.state, .stale)
        XCTAssertEqual(stale.reason, "its state has not been readable since 2026-11-14 01:00: launchctl did not answer in time")
        XCTAssertTrue(stale.state.isProblem)
    }

    func testReadableStateInBetweenStartsTheStaleClockOver() {
        let job = Scenario.watchedSinceYesterday()
        let unreadable = Evidence(source: SourceEvidence(availability: .unknown(reason: "launchctl did not answer in time")))

        job.evaluate(at: "2026-11-14 01:00", unreadable)
        job.evaluate(at: "2026-11-14 12:00", Scenario.loaded(runs: 4))
        XCTAssertNil(job.record?.unreadableSince)

        XCTAssertEqual(job.evaluate(at: "2026-11-15 06:00", unreadable).state, .unknown)
    }

    func testOfflineHostIsItsOwnStateAndForgetsNothing() {
        let job = Scenario.watchedSinceYesterday()
        let before = job.record

        let offline = job.evaluate(at: "2026-11-14 03:00", Evidence(hostReachable: false))

        XCTAssertEqual(offline.state, .hostOffline)
        XCTAssertEqual(offline.reason, "its host cannot be reached")
        XCTAssertFalse(offline.state.isProblem)
        XCTAssertEqual(job.record?.lastRunCount, before?.lastRunCount)
        XCTAssertEqual(job.record?.lastRun, before?.lastRun)
        XCTAssertEqual(job.record?.watchingSince, before?.watchingSince)
    }

    func testOnlyFailedMissedAndStaleAreProblems() {
        XCTAssertEqual(JobState.allCases.filter(\.isProblem), [.failed, .missed, .stale])
    }

    // MARK: - The record

    func testRecordListsTheVerdictsItSettledOn() {
        let job = Scenario()
        job.evaluate(at: "2026-11-13 12:00", Scenario.loaded(runs: 3))
        job.evaluate(at: "2026-11-13 12:01", Scenario.loaded(runs: 3))
        job.evaluate(at: "2026-11-14 02:31", Scenario.loaded(runs: 3))
        job.evaluate(at: "2026-11-14 02:32", Scenario.loaded(runs: 3))
        job.evaluate(at: "2026-11-14 02:50", Scenario.loaded(runs: 4))

        // The waiting before the first judged run is not a verdict and is not listed.
        XCTAssertEqual(job.record?.transitions.map(\.state), [.missed, .ok])
        XCTAssertEqual(job.record?.transitions.map(\.date), ["2026-11-14 02:31", "2026-11-14 02:50"].map { TestClock.date($0) })
        XCTAssertEqual(job.record?.stateSince, TestClock.date("2026-11-14 02:50"))
        XCTAssertEqual(job.record?.lastEvaluatedAt, TestClock.date("2026-11-14 02:50"))
        XCTAssertEqual(job.record?.reason, "the run due at 2026-11-14 02:00 happened")
    }

    func testWaitingAndRunningAroundEachRunDoNotFillTheRecord() {
        let job = Scenario.watchedSinceYesterday()

        for day in 14...20 {
            job.evaluate(at: "2026-11-\(day) 02:00:30", Scenario.loaded(runs: day - 11))
            job.evaluate(at: "2026-11-\(day) 02:01:30", Scenario.loaded(runs: day - 10, running: true))
            job.evaluate(at: "2026-11-\(day) 02:05", Scenario.loaded(runs: day - 10))
        }

        XCTAssertEqual(job.record?.transitions.map(\.state), [.ok])
        XCTAssertEqual(job.record?.state, .ok)
        XCTAssertEqual(job.record?.stateSince, TestClock.date("2026-11-20 02:05"))
    }

    func testRecordKeepsALimitedNumberOfChanges() {
        let job = Scenario(grace: 300)
        let every15 = Timetable(interval: 900)
        var runs = 0

        // Alternate between a seen run and a long silence, far more often than the record keeps.
        for hour in 0..<40 {
            runs += 1
            job.evaluate(at: String(format: "2026-11-%02d %02d:00", 1 + hour / 24, hour % 24), Scenario.loaded(runs: runs, timetable: every15))
            job.evaluate(at: String(format: "2026-11-%02d %02d:40", 1 + hour / 24, hour % 24), Scenario.loaded(runs: runs, timetable: every15))
        }

        XCTAssertEqual(job.record?.transitions.count, JobEvaluator.transitionLimit)
        XCTAssertEqual(job.record?.transitions.last?.state, .missed)
        XCTAssertEqual(job.record?.transitions.last?.date, TestClock.date("2026-11-02 15:40"))
    }

    func testSameInputsGiveTheSameVerdict() {
        let job = Scenario.watchedSinceYesterday()
        let evidence = Scenario.loaded(runs: 4)
        let record = job.record

        let first = job.evaluate(at: "2026-11-14 02:05", evidence)
        job.record = record
        let second = job.evaluate(at: "2026-11-14 02:05", evidence)

        XCTAssertEqual(first, second)
    }
}
