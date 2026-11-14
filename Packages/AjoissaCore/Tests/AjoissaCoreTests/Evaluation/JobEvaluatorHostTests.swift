import AjoissaCore
import XCTest

/// Jobs on machines that are not always there.
final class JobEvaluatorHostTests: XCTestCase {
    private func offline(mayBeOffline: Bool = false) -> Evidence {
        Evidence(hostReachable: false, hostProblem: "tower cannot be reached: no route to host", hostMayBeOffline: mayBeOffline)
    }

    private func loaded(runs: Int, mayBeOffline: Bool = false, timetable: Timetable? = Scenario.daily0200, awakeSince: String? = nil) -> Evidence {
        var evidence = Scenario.loaded(runs: runs, timetable: timetable, awakeSince: awakeSince)
        evidence.hostMayBeOffline = mayBeOffline
        return evidence
    }

    // MARK: - Any machine

    func testAnUnreachableMachineIsOfflineWithTheReasonAndComingBackIsNotNews() {
        let job = Scenario.watchedSinceYesterday()

        let away = job.evaluate(at: "2026-11-13 23:30", offline())
        XCTAssertEqual(away.state, .hostOffline)
        XCTAssertEqual(away.reason, "tower cannot be reached: no route to host")
        XCTAssertTrue(away.changed)
        XCTAssertEqual(job.record?.offlineSince, TestClock.date("2026-11-13 23:30"))

        XCTAssertFalse(job.evaluate(at: "2026-11-13 23:31", offline()).changed)
        XCTAssertEqual(job.record?.offlineSince, TestClock.date("2026-11-13 23:30"))

        let back = job.evaluate(at: "2026-11-13 23:40", loaded(runs: 3))
        XCTAssertEqual(back.state, .ok)
        XCTAssertFalse(back.changed)
        XCTAssertNil(job.record?.offlineSince)
    }

    func testARunThatHappenedWhileTheMachineCouldNotBeReachedIsSeenWhenItIsBack() {
        let job = Scenario.watchedSinceYesterday()
        job.evaluate(at: "2026-11-14 01:00", offline())
        job.evaluate(at: "2026-11-14 05:00", offline())

        let back = job.evaluate(at: "2026-11-14 09:00", loaded(runs: 4))

        XCTAssertEqual(back.state, .ok)
        XCTAssertEqual(back.reason, "the run due at 2026-11-14 02:00 happened")
    }

    func testOnAMachineThatShouldBeOnARunThatDidNotHappenWhileItWasAwayIsMissed() {
        let job = Scenario.watchedSinceYesterday()
        job.evaluate(at: "2026-11-14 01:00", offline())

        // No run in the count, and the machine did not sleep: the job simply did not run.
        let back = job.evaluate(at: "2026-11-14 09:00", loaded(runs: 3))

        XCTAssertEqual(back.state, .missed)
        XCTAssertEqual(back.reason, "there is no sign of the run that was due at 2026-11-14 02:00")
    }

    func testAnOfflineMachineIsNeverMissedFailedOrFine() {
        let job = Scenario.watchedSinceYesterday()
        for moment in ["2026-11-14 01:00", "2026-11-14 03:00", "2026-11-16 03:00"] {
            XCTAssertEqual(job.evaluate(at: moment, offline()).state, .hostOffline, moment)
        }
        XCTAssertEqual(job.record?.transitions.map(\.state), [.ok, .hostOffline])
    }

    // MARK: - A machine that may be offline

    func testOnAMachineThatMayBeOfflineWhatWasDueWhileItWasAwayIsNotHeldAgainstTheJob() {
        let job = Scenario.watchedSinceYesterday()
        job.evaluate(at: "2026-11-14 01:00", offline(mayBeOffline: true))

        let back = job.evaluate(at: "2026-11-14 09:00", loaded(runs: 3, mayBeOffline: true))

        XCTAssertEqual(back.state, .waiting)
        XCTAssertEqual(job.evaluate(at: "2026-11-14 12:00", loaded(runs: 3, mayBeOffline: true)).state, .waiting)
        // The next scheduled time, with the machine there, is judged as ever.
        XCTAssertEqual(job.evaluate(at: "2026-11-15 02:01", loaded(runs: 4, mayBeOffline: true)).state, .ok)
    }

    func testAfterComingBackTheNextScheduledTimeCanStillBeMissed() {
        let job = Scenario.watchedSinceYesterday()
        job.evaluate(at: "2026-11-14 01:00", offline(mayBeOffline: true))
        job.evaluate(at: "2026-11-14 09:00", loaded(runs: 3, mayBeOffline: true))

        XCTAssertEqual(job.evaluate(at: "2026-11-15 02:10", loaded(runs: 3, mayBeOffline: true)).state, .waiting)
        let late = job.evaluate(at: "2026-11-15 03:00", loaded(runs: 3, mayBeOffline: true))
        XCTAssertEqual(late.state, .missed)
        XCTAssertEqual(late.reason, "there is no sign of the run that was due at 2026-11-15 02:00")
    }

    func testARunMissedBeforeTheMachineWentAwayStaysMissed() {
        let job = Scenario.watchedSinceYesterday()
        XCTAssertEqual(job.evaluate(at: "2026-11-14 03:00", loaded(runs: 3, mayBeOffline: true)).state, .missed)
        job.evaluate(at: "2026-11-14 04:00", offline(mayBeOffline: true))
        job.evaluate(at: "2026-11-14 20:00", offline(mayBeOffline: true))

        let back = job.evaluate(at: "2026-11-15 09:00", loaded(runs: 3, mayBeOffline: true))

        XCTAssertEqual(back.state, .missed)
        XCTAssertFalse(back.changed)
        XCTAssertEqual(back.reason, "there is no sign of the run that was due at 2026-11-14 02:00")
    }

    func testAJobOnAnIntervalIsGivenAFullIntervalAfterTheMachineIsBack() {
        let hourly = Timetable(interval: 3600)
        let job = Scenario()
        job.evaluate(at: "2026-11-14 10:00", loaded(runs: 5, mayBeOffline: true, timetable: hourly))
        job.evaluate(at: "2026-11-14 10:30", loaded(runs: 6, mayBeOffline: true, timetable: hourly))
        job.evaluate(at: "2026-11-14 11:00", offline(mayBeOffline: true))

        // Off for 21 hours: no runs, and none expected. The hour the last run started is counted on from
        // where it was left: 30 minutes of it were used before the machine went away.
        XCTAssertEqual(job.evaluate(at: "2026-11-15 08:00", loaded(runs: 6, mayBeOffline: true, timetable: hourly)).state, .ok)
        XCTAssertEqual(job.evaluate(at: "2026-11-15 08:59", loaded(runs: 6, mayBeOffline: true, timetable: hourly)).state, .ok)
        XCTAssertEqual(job.evaluate(at: "2026-11-15 09:01", loaded(runs: 6, mayBeOffline: true, timetable: hourly)).state, .missed)
    }

    func testAMachineThatDropsOutForAMomentEachDayDoesNotHideAJobThatNeverRuns() {
        let job = Scenario.watchedSinceYesterday()
        var states: [JobState] = []
        for day in 14...20 {
            job.evaluate(at: "2026-11-\(day) 02:10", loaded(runs: 3, mayBeOffline: true))
            job.evaluate(at: "2026-11-\(day) 02:20", offline(mayBeOffline: true))
            job.evaluate(at: "2026-11-\(day) 02:21", loaded(runs: 3, mayBeOffline: true))
            states.append(job.evaluate(at: "2026-11-\(day) 03:00", loaded(runs: 3, mayBeOffline: true)).state)
        }
        XCTAssertEqual(states, Array(repeating: .missed, count: 7))
        // Once missed, it is never called fine or waiting again.
        XCTAssertEqual(Set(job.record?.transitions.dropFirst().map(\.state) ?? []), [.hostOffline, .missed])
    }

    func testAMachineThatDropsOutNowAndThenDoesNotHideAnIntervalJobThatNeverRuns() {
        let hourly = Timetable(interval: 3600)
        let job = Scenario()
        var clock = TestClock.date("2026-11-14 10:00")
        var states: [JobState] = []
        for look in 0..<60 {
            let evidence = look % 4 == 3 ? offline(mayBeOffline: true) : loaded(runs: 5, mayBeOffline: true, timetable: hourly)
            states.append(job.evaluate(at: clock, evidence).state)
            clock = clock.addingTimeInterval(20 * 60)
        }
        // Each time away gives the job that much longer, and no more: it is missed in the end, and stays so.
        let firstMissed = states.firstIndex(of: .missed)
        XCTAssertNotNil(firstMissed)
        XCTAssertLessThan(firstMissed ?? 60, 12)
        XCTAssertEqual(Set(states.suffix(from: firstMissed ?? 0)), [.missed, .hostOffline])
    }

    func testARunStillWaitedForWhenTheMachineWentAwayIsJudgedWhenItIsBack() {
        let job = Scenario.watchedSinceYesterday()
        XCTAssertEqual(job.evaluate(at: "2026-11-14 02:05", loaded(runs: 3, mayBeOffline: true)).state, .waiting)
        job.evaluate(at: "2026-11-14 02:06", offline(mayBeOffline: true))

        XCTAssertEqual(job.evaluate(at: "2026-11-14 09:00", loaded(runs: 3, mayBeOffline: true)).state, .missed)
    }

    func testAFailedRunIsStillReportedAfterTheMachineIsBack() {
        let job = Scenario.watchedSinceYesterday()
        job.evaluate(at: "2026-11-14 01:00", offline(mayBeOffline: true))

        var evidence = Scenario.loaded(runs: 4, exit: .code(2))
        evidence.hostMayBeOffline = true
        let back = job.evaluate(at: "2026-11-14 09:00", evidence)

        XCTAssertEqual(back.state, .failed)
        XCTAssertEqual(back.reason, "its last run exited with code 2")
    }

    // MARK: - A machine that answers but cannot be relied on

    func testAMachineWithAProblemIsUnknownNeverFineMissedOrFailed() {
        let job = Scenario.watchedSinceYesterday()
        var evidence = Scenario.loaded(runs: 3, exit: .code(1))
        evidence.hostProblem = "the clock on tower differs from this Mac's by 3h"

        let first = job.evaluate(at: "2026-11-14 03:00", evidence)
        XCTAssertEqual(first.state, .unknown)
        XCTAssertEqual(first.reason, "the clock on tower differs from this Mac's by 3h")
        XCTAssertEqual(job.record?.lastRunCount, 3)

        let later = job.evaluate(at: "2026-11-15 03:00", evidence)
        XCTAssertEqual(later.state, .stale)
        XCTAssertEqual(later.reason, "its state has not been readable since 2026-11-14 03:00: the clock on tower differs from this Mac's by 3h")
    }
}
