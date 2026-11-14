import AikanaCore
import XCTest

/// Which run the checks are about: jobs on an interval, proven runs, commands, and runs outside the timetable.
final class JobAssessorRunTests: JobAssessorTestCase {
    // MARK: - Jobs on an interval

    /// Every run of a job that runs each quarter of an hour writes an error. Looked at every minute, the job
    /// must be failed, not let through because the log is always "written since".
    func testLogCheckOnAnIntervalJobIsJudgedAtEveryRun() {
        let every15 = Timetable(interval: 900)
        let checks = [Check.logPattern(path: "/tmp/job.log", contains: nil, notContains: "ERROR")]
        record = nil
        host.put("/tmp/job.log", modified: "2026-11-14 09:45", contents: "")
        assess(at: "2026-11-14 09:59", checks, Scenario.loaded(runs: 10, timetable: every15), grace: 300)
        var states: [JobState] = []
        var log = ""

        for minute in 0..<90 {
            let moment = String(format: "2026-11-14 %02d:%02d", 10 + minute / 60, minute % 60)
            if minute % 15 == 0 {
                log += "ERROR in the run of \(moment)\n"
                host.put("/tmp/job.log", modified: moment, contents: log)
            }
            let evidence = Scenario.loaded(runs: 11 + minute / 15, timetable: every15)
            states.append(assess(at: moment, checks, evidence, grace: 300).evaluation.state)
        }

        XCTAssertEqual(Set(states), [.failed], "\(states)")
    }

    func testLogCheckOnAnIntervalJobClearsWithTheNextGoodRun() {
        let every15 = Timetable(interval: 900)
        let checks = [Check.logPattern(path: "/tmp/job.log", contains: nil, notContains: "ERROR")]
        record = nil
        host.put("/tmp/job.log", modified: "2026-11-14 09:45", contents: "")
        assess(at: "2026-11-14 09:59", checks, Scenario.loaded(runs: 10, timetable: every15), grace: 300)

        host.put("/tmp/job.log", modified: "2026-11-14 10:00", contents: "ERROR\n")
        XCTAssertEqual(assess(at: "2026-11-14 10:01", checks, Scenario.loaded(runs: 11, timetable: every15), grace: 300).evaluation.state, .failed)
        XCTAssertEqual(assess(at: "2026-11-14 10:10", checks, Scenario.loaded(runs: 11, timetable: every15), grace: 300).evaluation.state, .failed)

        host.put("/tmp/job.log", modified: "2026-11-14 10:15", contents: "ERROR\nfine\n")
        XCTAssertEqual(assess(at: "2026-11-14 10:16", checks, Scenario.loaded(runs: 12, timetable: every15), grace: 300).evaluation.state, .ok)
    }

    /// A run writes an error to its log and, two minutes later, the archive that proves it ran. The proof
    /// dates the run later than it was first seen. The error is still that run's and must stay reported.
    func testErrorStaysReportedWhenTheProofDatesTheRunLater() {
        let every15 = Timetable(interval: 900)
        let checks = [Check.fileAge(path: backup, maxAge: nil), Check.logPattern(path: "/tmp/job.log", contains: nil, notContains: "ERROR")]
        record = nil
        host.put("/tmp/job.log", modified: "2026-11-14 09:45", contents: "")
        assess(at: "2026-11-14 09:59", checks, Scenario.loaded(runs: 10, timetable: every15), grace: 300)

        assess(at: "2026-11-14 10:00:10", checks, Scenario.loaded(runs: 11, running: true, timetable: every15), grace: 300)
        host.put("/tmp/job.log", modified: "2026-11-14 10:00:20", contents: "ERROR: could not reach the server\n")
        assess(at: "2026-11-14 10:01:30", checks, Scenario.loaded(runs: 11, running: true, timetable: every15), grace: 300)
        host.put("/backup/a.tar", modified: "2026-11-14 10:02:20")

        for moment in ["2026-11-14 10:02:30", "2026-11-14 10:03:30", "2026-11-14 10:10:00", "2026-11-14 10:14:30"] {
            let assessment = assess(at: moment, checks, Scenario.loaded(runs: 11, timetable: every15), grace: 300)
            XCTAssertEqual(assessment.evaluation.state, .failed, moment)
            XCTAssertEqual(assessment.evaluation.reason, "the log contains \"ERROR\"", moment)
        }
    }

    /// The file a run writes shows that it ran, when the file was written. A file from the last run must not
    /// keep a job that has stopped looking alive for as long as the file is "recent".
    func testFileFromTheLastRunDoesNotDelayTheMissOfAStoppedIntervalJob() {
        let every15 = Timetable(interval: 900)
        let checks = [Check.fileAge(path: backup, maxAge: nil)]
        record = nil
        // The run count is not available here; the file is the only sign of a run.
        assess(at: "2026-11-14 09:50", checks, Scenario.loaded(runs: nil, timetable: every15), grace: 300)
        host.put("/backup/a.tar", modified: "2026-11-14 10:00")

        // The job stops after its 10:00 run. With 15 minutes and 5 of grace it is missed from 10:20.
        var states: [String: JobState] = [:]
        for minute in stride(from: 1, through: 45, by: 1) {
            let moment = String(format: "2026-11-14 10:%02d", minute)
            states[moment] = assess(at: moment, checks, Scenario.loaded(runs: nil, timetable: every15), grace: 300).evaluation.state
        }

        XCTAssertEqual(states["2026-11-14 10:01"], .ok)
        XCTAssertEqual(states["2026-11-14 10:20"], .ok)
        XCTAssertEqual(states["2026-11-14 10:21"], .missed)
        XCTAssertEqual(states["2026-11-14 10:45"], .missed)
    }

    // MARK: - When a proven run counts from

    /// Asleep from Friday evening to Monday morning with no run count to go by. The file written on wake is
    /// newer than every scheduled time slept through, and accounts for all of them at once.
    func testFileWrittenOnWakeAccountsForEveryScheduledTimeSleptThrough() {
        let checks = [Check.fileAge(path: backup, maxAge: nil)]
        let woke = "2026-11-16 08:00"
        host.put("/backup/a.tar", modified: "2026-11-16 08:01")

        var states: [JobState] = []
        for moment in ["2026-11-16 08:02", "2026-11-16 08:03", "2026-11-16 08:31", "2026-11-16 12:00"] {
            states.append(assess(at: moment, checks, Scenario.loaded(runs: nil, awakeSince: woke)).evaluation.state)
        }

        XCTAssertEqual(states, [.ok, .ok, .ok, .ok])
    }

    func testFileOlderThanTheOpenScheduledTimeProvesNothing() {
        host.put("/backup/a.tar", modified: "2026-11-13 02:04")

        let assessment = assess(at: "2026-11-14 02:31", [.fileAge(path: backup, maxAge: 3 * 86400)], Scenario.loaded(runs: 3))

        // The file is less than three days old, so the check passes. It says nothing about last night.
        XCTAssertEqual(assessment.outcomes.map(\.result), [.passed])
        XCTAssertEqual(assessment.evaluation.state, .missed)
    }

    // MARK: - Commands

    func testCommandWaitsForTheRunAndIsThenRunOnceUntilTheNextRun() {
        let checks = [Check.command(arguments: ["/usr/bin/verify"], timeout: 30)]

        // Due at 02:00 and not seen yet: the command has nothing to judge.
        let waiting = assess(at: "2026-11-14 02:10", checks, Scenario.loaded(runs: 3))
        XCTAssertEqual(waiting.evaluation.state, .waiting)
        XCTAssertEqual(waiting.outcomes.map(\.result), [.skipped("it is run once the job has run")])
        XCTAssertEqual(assess(at: "2026-11-14 02:31", checks, Scenario.loaded(runs: 3)).evaluation.state, .missed)
        XCTAssertEqual(host.commands.count, 0)

        // The run is seen at 02:40. Looked at every minute for ten minutes, the command runs once.
        for minute in 40..<50 {
            XCTAssertEqual(assess(at: "2026-11-14 02:\(minute)", checks, Scenario.loaded(runs: 4)).evaluation.state, .ok)
        }
        XCTAssertEqual(host.commands.count, 1)

        // The next night's run is judged anew.
        assess(at: "2026-11-15 02:05", checks, Scenario.loaded(runs: 5))
        XCTAssertEqual(host.commands.count, 2)
    }

    func testFailingCommandFailsTheJobAndIsAskedAgainAfterAQuarterOfAnHour() {
        let checks = [Check.command(arguments: ["/usr/bin/verify"], timeout: 30)]
        host.answerCommands(with: .success(CommandResult(exitCode: 1)))

        XCTAssertEqual(assess(at: "2026-11-14 02:05", checks, Scenario.loaded(runs: 4)).evaluation.reason, "/usr/bin/verify exited with code 1")
        XCTAssertEqual(assess(at: "2026-11-14 02:10", checks, Scenario.loaded(runs: 4)).evaluation.state, .failed)
        XCTAssertEqual(host.commands.count, 1)

        host.answerCommands(with: .success(CommandResult(exitCode: 0)))
        XCTAssertEqual(assess(at: "2026-11-14 02:21", checks, Scenario.loaded(runs: 4)).evaluation.state, .ok)
    }

    /// A job with no scheduler is judged by its command. Asked while the job was still working, the command
    /// said no. Once the job's time is over it is asked again, not answered from memory.
    func testJobKnownOnlyThroughACommandIsAskedAgainWhenItsTimeIsOver() throws {
        let checks = [Check.command(arguments: ["/usr/bin/verify"], timeout: 30)]
        let schedule = Schedule.daily(at: try XCTUnwrap(TimeOfDay(hour: 2, minute: 0)))
        record = nil
        assess(at: "2026-11-13 12:00", checks, Evidence(), source: nil, schedule: schedule)

        host.answerCommands(with: .success(CommandResult(exitCode: 1)))
        XCTAssertEqual(assess(at: "2026-11-14 02:16", checks, Evidence(), source: nil, schedule: schedule).evaluation.state, .waiting)

        // The job finishes at 02:20.
        host.answerCommands(with: .success(CommandResult(exitCode: 0)))
        XCTAssertEqual(assess(at: "2026-11-14 02:30:30", checks, Evidence(), source: nil, schedule: schedule).evaluation.state, .ok)
    }

    // MARK: - Runs outside the timetable

    /// The scheduled run failed. The user fixes the cause and starts the job by hand. That run's output is
    /// what counts now; the night's error is no longer the latest word.
    func testRunStartedByHandAfterAFailedScheduledRunIsJudgedOnItsOwnOutput() {
        let checks = [Check.logPattern(path: "/tmp/job.log", contains: nil, notContains: "ERROR"), Check.command(arguments: ["/usr/bin/verify"], timeout: 30)]
        host.put("/tmp/job.log", modified: "2026-11-13 02:05", contents: "")
        assess(at: "2026-11-14 01:59", checks, Scenario.loaded(runs: 3))
        host.put("/tmp/job.log", modified: "2026-11-14 02:03", contents: "ERROR: token expired\n")
        XCTAssertEqual(assess(at: "2026-11-14 02:05", checks, Scenario.loaded(runs: 4)).evaluation.state, .failed)
        XCTAssertEqual(assess(at: "2026-11-14 09:59", checks, Scenario.loaded(runs: 4)).evaluation.state, .failed)
        let commandsBefore = host.commands.count

        host.put("/tmp/job.log", modified: "2026-11-14 10:00", contents: "ERROR: token expired\nall fine\n")
        let rerun = assess(at: "2026-11-14 10:01", checks, Scenario.loaded(runs: 5))

        XCTAssertEqual(rerun.evaluation.state, .ok)
        XCTAssertEqual(host.commands.count, commandsBefore + 1)
        XCTAssertEqual(assess(at: "2026-11-14 20:00", checks, Scenario.loaded(runs: 5)).evaluation.state, .ok)
    }

    func testScheduledRunItselfIsNotTakenForAnExtraRun() {
        let checks = [Check.logPattern(path: "/tmp/job.log", contains: nil, notContains: "ERROR")]
        host.put("/tmp/job.log", modified: "2026-11-13 02:05", contents: "")
        assess(at: "2026-11-14 01:59:30", checks, Scenario.loaded(runs: 3))

        // The run starts at 02:00:00 and writes its error at once, before the look at 02:00:30 and before
        // the look at 02:01:30 that sees the count go up.
        host.put("/tmp/job.log", modified: "2026-11-14 02:00:05", contents: "ERROR at the very start\n")
        assess(at: "2026-11-14 02:00:30", checks, Scenario.loaded(runs: 3))

        XCTAssertEqual(assess(at: "2026-11-14 02:01:30", checks, Scenario.loaded(runs: 4)).evaluation.state, .failed)
        XCTAssertEqual(assess(at: "2026-11-14 12:00", checks, Scenario.loaded(runs: 4)).evaluation.state, .failed)
    }

    /// A job that runs when a folder changes has no timetable. Its log is read for the latest run seen.
    func testLogCheckOnAJobWithoutATimetable() {
        let none = Timetable()
        let checks = [Check.logPattern(path: "/tmp/job.log", contains: nil, notContains: "ERROR")]
        record = nil
        host.put("/tmp/job.log", modified: "2026-11-14 09:00", contents: "fine\n")
        XCTAssertEqual(assess(at: "2026-11-14 10:00", checks, Scenario.loaded(runs: 1, timetable: none)).evaluation.state, .ok)

        host.put("/tmp/job.log", modified: "2026-11-14 10:30", contents: "fine\nERROR\n")
        let failed = assess(at: "2026-11-14 10:31", checks, Scenario.loaded(runs: 2, timetable: none))
        XCTAssertEqual(failed.evaluation.state, .failed)
        XCTAssertEqual(failed.evaluation.reason, "the log contains \"ERROR\"")

        host.put("/tmp/job.log", modified: "2026-11-14 11:00", contents: "fine\nERROR\nfine again\n")
        XCTAssertEqual(assess(at: "2026-11-14 11:01", checks, Scenario.loaded(runs: 3, timetable: none)).evaluation.state, .ok)
    }
}
