import AjoissaCore
import XCTest

/// log-pattern. A log only grows, so the tests follow one through several looks, each with the state the
/// previous look left.
final class LogPatternTests: LogCheckTestCase {
    // MARK: - Only what the run wrote

    func testOnlyTextWrittenSinceTheRunIsRead() {
        host.put(log, modified: "2026-11-13 02:05", contents: "Traceback from last week\n")
        look(at: "2026-11-14 01:59", since: run1, .logPattern(path: log, contains: nil, notContains: "Traceback"))

        // The run of 02:00 appends its own lines.
        host.put(log, modified: "2026-11-14 02:03", contents: "Traceback from last week\ndump complete\n")

        XCTAssertEqual(
            look(at: "2026-11-14 02:10", since: run2, .logPattern(path: log, contains: "dump complete", notContains: "Traceback")),
            CheckOutcome(result: .passed, provesRunAt: TestClock.date("2026-11-14 02:03"))
        )
    }

    func testUnwantedTextWrittenByTheRunFailsAndShowsTheLine() {
        host.put(log, modified: "2026-11-13 02:05", contents: "fine\n")
        look(at: "2026-11-14 01:59", since: run1, .logPattern(path: log, contains: nil, notContains: "Traceback"))
        host.put(log, modified: "2026-11-14 02:03", contents: "fine\nstarting\nTraceback (most recent call last):\n  File x\n")

        XCTAssertEqual(
            look(at: "2026-11-14 02:10", since: run2, .logPattern(path: log, contains: nil, notContains: "Traceback")),
            CheckOutcome(result: .failed("the log contains \"Traceback\""), detail: "Traceback (most recent call last):")
        )
    }

    func testWantedTextThatTheRunDidNotWriteFails() {
        host.put(log, modified: "2026-11-13 02:05", contents: "dump complete\n")
        look(at: "2026-11-14 01:59", since: run1, .logPattern(path: log, contains: "dump complete", notContains: nil))
        host.put(log, modified: "2026-11-14 02:03", contents: "dump complete\nstarting\n")

        XCTAssertEqual(
            look(at: "2026-11-14 02:10", since: run2, .logPattern(path: log, contains: "dump complete", notContains: nil)),
            CheckOutcome(result: .failed("the log does not contain \"dump complete\" since 2026-11-14 02:00"))
        )
    }

    func testStartOfTheRunsTextStaysPutWhileTheRunKeepsWriting() {
        let check = Check.logPattern(path: log, contains: "done", notContains: "error")
        host.put(log, modified: "2026-11-13 02:05", contents: "old\n")
        look(at: "2026-11-14 01:59", since: run1, check)

        host.put(log, modified: "2026-11-14 02:03", contents: "old\nstarting\n")
        XCTAssertEqual(look(at: "2026-11-14 02:05", since: run2, check).result, .failed("the log does not contain \"done\" since 2026-11-14 02:00"))

        host.put(log, modified: "2026-11-14 02:08", contents: "old\nstarting\nerror: disk full\n")
        XCTAssertEqual(look(at: "2026-11-14 02:10", since: run2, check).result, .failed("the log contains \"error\""))

        // Even much later, the whole of what the run wrote is read, not only what is new since the last look.
        host.put(log, modified: "2026-11-14 02:09", contents: "old\nstarting\nerror: disk full\ndone\n")
        XCTAssertEqual(look(at: "2026-11-14 20:00", since: run2, check).result, .failed("the log contains \"error\""))
    }

    func testNextRunIsReadFromWhereTheLogStoodBeforeIt() {
        let check = Check.logPattern(path: log, contains: nil, notContains: "error")
        host.put(log, modified: "2026-11-13 02:05", contents: "old\n")
        look(at: "2026-11-14 01:59", since: run1, check)
        host.put(log, modified: "2026-11-14 02:03", contents: "old\nerror: disk full\n")
        XCTAssertEqual(look(at: "2026-11-14 02:10", since: run2, check).result, .failed("the log contains \"error\""))
        look(at: "2026-11-15 01:59", since: run2, check)

        host.put(log, modified: "2026-11-15 02:03", contents: "old\nerror: disk full\nall fine\n")

        XCTAssertEqual(look(at: "2026-11-15 02:10", since: "2026-11-15 02:00", check).result, .passed)
    }

    func testLogThatWasEmptiedIsReadFromItsStart() {
        let check = Check.logPattern(path: log, contains: "done", notContains: nil)
        host.put(log, modified: "2026-11-13 02:05", contents: String(repeating: "old line\n", count: 100))
        look(at: "2026-11-14 01:59", since: run1, check)

        host.put(log, modified: "2026-11-14 02:03", contents: "done\n")

        XCTAssertEqual(look(at: "2026-11-14 02:10", since: run2, check).result, .passed)
    }

    // MARK: - Which run

    /// After a missed run the run in question changes to a time after the last look. The start of the earlier
    /// run is still known, and reading from there is better than not reading.
    func testWhenTheRunChangesToOneAfterTheLastLookTheEarlierStartIsUsed() {
        let check = Check.logPattern(path: log, contains: nil, notContains: "ERROR")
        host.put(log, modified: "2026-11-12 02:05", contents: "old\n")
        look(at: "2026-11-13 01:59", since: "2026-11-12 02:00", check)
        look(at: "2026-11-14 09:00", since: run1, check)

        host.put(log, modified: "2026-11-14 09:01", contents: "old\nERROR: late run failed\n")

        XCTAssertEqual(look(at: "2026-11-14 09:02", since: run2, check).result, .failed("the log contains \"ERROR\""))
    }

    /// For a job on an interval the run in question is the latest one seen, and stays that until the next.
    func testOutputOfTheLatestRunIsReadUntilTheNextRunIsSeen() {
        let check = Check.logPattern(path: log, contains: nil, notContains: "ERROR")
        host.put(log, modified: "2026-11-14 10:00", contents: "run 1 fine\n")
        look(at: "2026-11-14 10:14", since: "2026-11-14 10:00", check)

        // The 10:15 run is noticed at 10:16, and wrote an error.
        host.put(log, modified: "2026-11-14 10:15", contents: "run 1 fine\nERROR in run 2\n")
        for moment in ["2026-11-14 10:16", "2026-11-14 10:17", "2026-11-14 10:29"] {
            XCTAssertEqual(look(at: moment, since: "2026-11-14 10:16", check).result, .failed("the log contains \"ERROR\""), moment)
        }

        // The 10:30 run is fine, and from then on so is the check.
        host.put(log, modified: "2026-11-14 10:30", contents: "run 1 fine\nERROR in run 2\nrun 3 fine\n")
        XCTAssertEqual(look(at: "2026-11-14 10:31", since: "2026-11-14 10:31", check).result, .passed)
    }

    func testWantedTextDoesNotProveARunWhenTheLogCannot() {
        let check = Check.logPattern(path: log, contains: "done", notContains: nil)
        host.put(log, modified: "2026-11-13 02:05", contents: "")
        look(at: "2026-11-14 01:59", since: run1, check)
        host.put(log, modified: "2026-11-14 02:03", contents: "done\n")
        var context = CheckContext(now: TestClock.date("2026-11-14 02:10"), since: TestClock.date(run2), calendar: TestClock.utc)
        context.logProvesRun = false

        let outcome = CheckRunner.run([check], on: host, context: context, state: state).outcomes[0]

        XCTAssertEqual(outcome, CheckOutcome(result: .passed))
    }

    // MARK: - First look

    func testFirstLookAtALogNotWrittenSinceTheRunFindsNothingNew() {
        host.put(log, modified: "2026-11-13 02:05", contents: "Traceback\ndone\n")

        XCTAssertEqual(look(at: "2026-11-14 03:00", since: run2, .logPattern(path: log, contains: nil, notContains: "Traceback")).result, .passed)
        state = nil
        XCTAssertEqual(
            look(at: "2026-11-14 03:00", since: run2, .logPattern(path: log, contains: "done", notContains: nil)).result,
            .failed("the log does not contain \"done\" since 2026-11-14 02:00")
        )
    }

    /// The log was written by the run before anyone noted how long it was. Which part is the run's cannot be
    /// told, so this run is let through and the next one is read properly.
    func testFirstLookAtALogAlreadyWrittenSinceTheRunIsNotJudged() {
        host.put(log, modified: "2026-11-14 02:05", contents: "Traceback\n")

        XCTAssertEqual(
            look(at: "2026-11-14 03:00", since: run2, .logPattern(path: log, contains: "done", notContains: "Traceback")),
            CheckOutcome(result: .passed, detail: "not read yet: /var/log/job.log is read from the next run on")
        )
        XCTAssertEqual(state?.logMarks[log]?.position.offset, 10)
        XCTAssertEqual(state?.logMarks[log]?.date, TestClock.date("2026-11-14 03:00"))
        // Only the few bytes that mark where the log ends were read, not the log.
        XCTAssertEqual(host.reads, ["/var/log/job.log 0..<10"])
    }

    func testLogThatDoesNotExist() {
        XCTAssertEqual(
            look(at: "2026-11-14 03:00", since: run2, .logPattern(path: log, contains: "done", notContains: nil)).result,
            .failed("the log does not contain \"done\" since 2026-11-14 02:00")
        )
        state = nil
        XCTAssertEqual(look(at: "2026-11-14 03:00", since: run2, .logPattern(path: log, contains: nil, notContains: "error")).result, .passed)
    }

    // MARK: - Which log

    func testJobsOwnLogsAreUsedWhenTheCheckNamesNone() {
        host.put("/tmp/job.out", modified: "2026-11-13 02:05", contents: "")
        host.put("/tmp/job.err", modified: "2026-11-13 02:05", contents: "")
        let check = Check.logPattern(path: nil, contains: nil, notContains: "fatal")
        look(at: "2026-11-14 01:59", since: run1, check, defaultLogPaths: ["/tmp/job.out", "/tmp/job.err"])

        host.put("/tmp/job.err", modified: "2026-11-14 02:03", contents: "fatal: no space\n")

        XCTAssertEqual(
            look(at: "2026-11-14 02:10", since: run2, check, defaultLogPaths: ["/tmp/job.out", "/tmp/job.err"]).result,
            .failed("the log contains \"fatal\"")
        )
    }

    /// With two logs, both must be noted at every look, also when the first one already settles the outcome.
    func testEveryLogIsNotedEvenWhenTheFirstOneCannotBeJudgedYet() {
        host.put("/tmp/job.out", modified: "2026-11-14 02:05", contents: "written by the run\n")
        host.put("/tmp/job.err", modified: "2026-11-14 02:05", contents: "also\n")
        let check = Check.logPattern(path: nil, contains: nil, notContains: "fatal")

        let outcome = look(at: "2026-11-14 03:00", since: run2, check, defaultLogPaths: ["/tmp/job.out", "/tmp/job.err"])

        XCTAssertEqual(outcome.detail, "not read yet: /tmp/job.out is read from the next run on")
        XCTAssertEqual(state?.logMarks.keys.sorted(), ["/tmp/job.err", "/tmp/job.out"])
    }

    func testCheckWithNoLogToReadIsNotAFailure() {
        XCTAssertEqual(
            look(at: "2026-11-14 03:00", since: run2, .logPattern(path: nil, contains: "done", notContains: nil)).result,
            .couldNotRun("the job has no log file of its own; give the check a path")
        )
    }

    func testCheckWithNoExpectedRunIsNotAFailure() {
        host.put(log, modified: "2026-11-14 02:05", contents: "done\n")

        XCTAssertEqual(
            look(at: "2026-11-14 03:00", since: nil, .logPattern(path: log, contains: "done", notContains: nil)).result,
            .couldNotRun("the log has no expected run to be read from")
        )
    }

    func testLogThatCannotBeReadIsNotAFailure() {
        host.makeUnreadable(log)

        XCTAssertEqual(
            look(at: "2026-11-14 03:00", since: run2, .logPattern(path: log, contains: nil, notContains: "error")).result,
            .couldNotRun("/var/log/job.log could not be read: permission denied")
        )
    }

    // MARK: - State

    func testLogUsedByTwoChecksIsReadOnce() {
        host.put(log, modified: "2026-11-13 02:05", contents: "old\n")
        look(at: "2026-11-14 01:59", since: run1, .logPattern(path: log, contains: nil, notContains: "x"))
        host.put(log, modified: "2026-11-14 02:03", contents: "old\ndone\n")
        let context = CheckContext(now: TestClock.date("2026-11-14 02:10"), since: TestClock.date(run2), calendar: TestClock.utc)

        let result = CheckRunner.run(
            [.logPattern(path: log, contains: "done", notContains: nil), .logPattern(path: log, contains: nil, notContains: "error")],
            on: host,
            context: context,
            state: state
        )

        XCTAssertEqual(result.outcomes.map(\.result), [.passed, .passed])
        // Where it ends now, whether the start of the run still holds, and the run's text: once each.
        XCTAssertEqual(Array(host.reads.suffix(3)), ["/var/log/job.log 0..<9", "/var/log/job.log 0..<4", "/var/log/job.log 4..<9"])
        XCTAssertEqual(host.reads.count, 4)
    }

    func testStateKeepsOnlyTheLogsThatWereLookedAt() {
        host.put(log, modified: "2026-11-12 02:05", contents: "old\n")
        let somewhere = CheckState.LogPosition(offset: 5)
        state = CheckState(
            logMarks: ["/var/log/gone.log": CheckState.LogMark(position: somewhere, date: TestClock.date("2026-11-13 12:00"))],
            logBaselines: ["/var/log/gone.log": CheckState.LogBaseline(since: TestClock.date(run1), position: somewhere)]
        )

        look(at: "2026-11-14 01:59", since: run1, .logPattern(path: log, contains: nil, notContains: "x"))

        XCTAssertEqual(state?.logMarks.keys.sorted(), [log])
        XCTAssertEqual(state?.logBaselines.keys.sorted(), [log])
        XCTAssertEqual(state?.logMarks[log]?.position.offset, 4)
        XCTAssertEqual(state?.logMarks[log]?.position.tail, Data("old\n".utf8))
    }
}
