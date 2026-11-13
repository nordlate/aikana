import AjoissaCore
import XCTest

/// log-pattern. A log only grows, so the tests follow one through several looks, each with the state the
/// previous look left.
final class LogPatternTests: XCTestCase {
    private var host: FakeHost!
    private var state: CheckState?
    private let log = "/var/log/job.log"
    private let run1 = "2026-11-13 02:00"
    private let run2 = "2026-11-14 02:00"

    override func setUp() {
        host = FakeHost()
        state = nil
    }

    // MARK: - Only what the run wrote

    func testOnlyTextWrittenSinceTheRunIsRead() {
        host.put(log, modified: "2026-11-13 02:05", contents: "Traceback from last week\n")
        look(at: "2026-11-14 01:59", since: run1, .logPattern(path: log, contains: nil, notContains: "Traceback"))

        // The run of 02:00 appends its own lines.
        host.put(log, modified: "2026-11-14 02:03", contents: "Traceback from last week\ndump complete\n")

        XCTAssertEqual(
            look(at: "2026-11-14 02:10", since: run2, .logPattern(path: log, contains: "dump complete", notContains: "Traceback")),
            CheckOutcome(result: .passed, provesRun: true)
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
            CheckOutcome(result: .passed, provesRun: false, detail: "not read yet: /var/log/job.log is read from the next run on")
        )
        XCTAssertEqual(state?.logMarks[log], CheckState.LogMark(size: 10, date: TestClock.date("2026-11-14 03:00")))
        XCTAssertEqual(host.reads, [])
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
        XCTAssertEqual(host.reads, [log])
    }

    func testStateKeepsOnlyTheLogsThatWereLookedAt() {
        host.put(log, modified: "2026-11-12 02:05", contents: "old\n")
        state = CheckState(
            logMarks: ["/var/log/gone.log": CheckState.LogMark(size: 5, date: TestClock.date("2026-11-13 12:00"))],
            logBaselines: ["/var/log/gone.log": CheckState.LogBaseline(since: TestClock.date(run1), offset: 0)]
        )

        look(at: "2026-11-14 01:59", since: run1, .logPattern(path: log, contains: nil, notContains: "x"))

        XCTAssertEqual(state?.logMarks.keys.sorted(), [log])
        XCTAssertEqual(state?.logBaselines.keys.sorted(), [log])
        XCTAssertEqual(state?.logMarks[log], CheckState.LogMark(size: 4, date: TestClock.date("2026-11-14 01:59")))
    }

    // MARK: - Helpers

    @discardableResult
    private func look(at moment: String, since: String?, _ check: Check, defaultLogPaths: [String] = []) -> CheckOutcome {
        let context = CheckContext(
            now: TestClock.date(moment),
            since: since.map { TestClock.date($0) },
            defaultLogPaths: defaultLogPaths,
            calendar: TestClock.utc
        )
        let result = CheckRunner.run([check], on: host, context: context, state: state)
        state = result.state
        return result.outcomes[0]
    }
}
