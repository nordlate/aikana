import AjoissaCore
import XCTest

/// The evaluation and the checks together. The job runs daily at 02:00 with 30 minutes of grace and has been
/// watched since the day before.
final class JobAssessorTests: XCTestCase {
    private var host: FakeHost!
    private var record: JobRecord?
    private let backup = "/backup/*.tar"

    override func setUp() {
        host = FakeHost()
        record = Scenario.watchedSinceYesterday().record
    }

    // MARK: - Checks decide

    func testFailingCheckTurnsACleanExitIntoAFailureWithTheChecksMessage() {
        host.put("/backup/today.tar", modified: "2026-11-14 02:04", size: 3200)

        let assessment = assess(at: "2026-11-14 02:05", [.fileSize(path: backup, minBytes: 500_000_000)], Scenario.loaded(runs: 4, exit: .code(0)))

        XCTAssertEqual(assessment.evaluation.state, .failed)
        XCTAssertEqual(assessment.evaluation.reason, "/backup/today.tar is 3.2 KB, less than the 500 MB it should be")
        XCTAssertEqual(assessment.outcomes.map(\.result), [.failed("/backup/today.tar is 3.2 KB, less than the 500 MB it should be")])
    }

    func testPassingChecksLeaveTheJobFine() {
        host.put("/backup/today.tar", modified: "2026-11-14 02:04", size: 600_000_000)

        let assessment = assess(
            at: "2026-11-14 02:05",
            [.fileSize(path: backup, minBytes: 500_000_000), .fileAge(path: backup, maxAge: nil), .command(arguments: ["/usr/bin/true"], timeout: 30)],
            Scenario.loaded(runs: 4)
        )

        XCTAssertEqual(assessment.evaluation.state, .ok)
        XCTAssertEqual(assessment.outcomes.map(\.result), [.passed, .passed, .passed])
    }

    func testCheckThatCouldNotBeCarriedOutMakesTheJobUnknownNotFailed() {
        host.makeUnreadable(backup)

        let assessment = assess(at: "2026-11-14 02:05", [.fileSize(path: backup, minBytes: 1)], Scenario.loaded(runs: 4))

        XCTAssertEqual(assessment.evaluation.state, .unknown)
        XCTAssertEqual(assessment.evaluation.reason, "/backup/*.tar could not be read: permission denied")
    }

    /// The run itself was not seen: the count did not move. But the file it writes is newer than its scheduled
    /// time, and that is proof enough.
    func testFileNewerThanTheScheduledTimeStandsInForARunNobodySaw() {
        XCTAssertEqual(assess(at: "2026-11-14 03:00", [.fileAge(path: backup, maxAge: nil)], Scenario.loaded(runs: 3)).evaluation.state, .missed)

        host.put("/backup/today.tar", modified: "2026-11-14 02:04")

        let assessment = assess(at: "2026-11-14 03:01", [.fileAge(path: backup, maxAge: nil)], Scenario.loaded(runs: 3))
        XCTAssertEqual(assessment.evaluation.state, .ok)
        XCTAssertEqual(assessment.evaluation.reason, "the run due at 2026-11-14 02:00 happened")
    }

    func testChecksAreJudgedAgainstTheRunThatIsExpected() {
        // Yesterday's file is still there. It must not pass for today's run.
        host.put("/backup/yesterday.tar", modified: "2026-11-13 02:04")

        let waiting = assess(at: "2026-11-14 02:10", [.fileAge(path: backup, maxAge: nil)], Scenario.loaded(runs: 3))
        XCTAssertEqual(waiting.evaluation.state, .waiting)
        XCTAssertEqual(
            waiting.outcomes.map(\.result),
            [.failed("no file matching /backup/*.tar is newer than 2026-11-14 02:00; the newest was written at 2026-11-13 02:04")]
        )

        XCTAssertEqual(assess(at: "2026-11-14 02:31", [.fileAge(path: backup, maxAge: nil)], Scenario.loaded(runs: 3)).evaluation.state, .missed)
    }

    func testIntervalJobIsCheckedAgainstTheStretchThatMustHaveHadARun() {
        let every15 = Timetable(interval: 900)
        let job = Scenario(grace: 300)
        job.evaluate(at: "2026-11-14 11:00", Scenario.loaded(runs: 10, timetable: every15))
        record = job.record
        host.put("/backup/a.tar", modified: "2026-11-14 11:35")

        // At 12:00 a run must have happened since 11:40. The file from 11:35 is too old to show one.
        let assessment = assess(at: "2026-11-14 12:00", [.fileAge(path: backup, maxAge: nil)], Scenario.loaded(runs: 10, timetable: every15), grace: 300)

        XCTAssertEqual(assessment.evaluation.checksSince, TestClock.date("2026-11-14 11:40"))
        XCTAssertEqual(assessment.evaluation.state, .missed)
    }

    // MARK: - When checks are not run

    func testChecksAreNotRunWhileTheJobIsRunning() {
        let assessment = assess(at: "2026-11-14 02:01", [.command(arguments: ["/usr/bin/verify"], timeout: 30)], Scenario.loaded(runs: 4, running: true))

        XCTAssertEqual(assessment.evaluation.state, .running)
        XCTAssertEqual(assessment.outcomes, [])
        XCTAssertEqual(host.commands, [])
    }

    func testChecksAreNotRunWhenTheJobCannotBeLookedAtOrCannotRun() {
        let checks = [Check.command(arguments: ["/usr/bin/verify"], timeout: 30)]
        let cases: [(Evidence, JobState)] = [
            (Evidence(hostReachable: false), .hostOffline),
            (Evidence(source: SourceEvidence(availability: .unknown(reason: "launchctl did not answer in time"))), .unknown),
            (Evidence(source: SourceEvidence(availability: .notLoaded)), .failed),
            (Evidence(source: SourceEvidence(availability: .missing)), .failed)
        ]

        for (evidence, state) in cases {
            let assessment = assess(at: "2026-11-14 02:05", checks, evidence)
            XCTAssertEqual(assessment.evaluation.state, state)
            XCTAssertEqual(assessment.outcomes, [])
        }
        XCTAssertEqual(host.commands, [])
    }

    func testJobWithoutChecksIsOnlyEvaluated() {
        let assessment = assess(at: "2026-11-14 02:05", [], Scenario.loaded(runs: 4))

        XCTAssertEqual(assessment.evaluation.state, .ok)
        XCTAssertEqual(assessment.outcomes, [])
        XCTAssertNil(assessment.evaluation.record.checkState)
    }

    func testOutcomesHandedInFromOutsideAreNotUsed() {
        host.put("/backup/today.tar", modified: "2026-11-14 02:04", size: 600_000_000)
        var evidence = Scenario.loaded(runs: 4)
        evidence.checks = [CheckOutcome(result: .failed("stale outcome from somewhere else"))]

        XCTAssertEqual(assess(at: "2026-11-14 02:05", [.fileSize(path: backup, minBytes: 1)], evidence).evaluation.state, .ok)
    }

    // MARK: - What the checks remember

    func testLogIsReadFromWhereItStoodBeforeTheRunAcrossAssessments() {
        let checks = [Check.logPattern(path: nil, contains: nil, notContains: "Traceback")]
        host.put("/tmp/job.log", modified: "2026-11-13 02:05", contents: "Traceback from an old run\n")

        // A look before the run notes how long the log is.
        let before = assess(at: "2026-11-14 01:59", checks, Scenario.loaded(runs: 3), logs: ["/tmp/job.log"])
        XCTAssertEqual(before.evaluation.state, .ok)
        XCTAssertNotNil(record?.checkState?.logMarks["/tmp/job.log"])

        host.put("/tmp/job.log", modified: "2026-11-14 02:03", contents: "Traceback from an old run\nall fine\n")
        XCTAssertEqual(assess(at: "2026-11-14 02:05", checks, Scenario.loaded(runs: 4), logs: ["/tmp/job.log"]).evaluation.state, .ok)

        host.put("/tmp/job.log", modified: "2026-11-15 02:03", contents: "Traceback from an old run\nall fine\nTraceback (most recent call last):\n")
        let failed = assess(at: "2026-11-15 02:05", checks, Scenario.loaded(runs: 5), logs: ["/tmp/job.log"])
        XCTAssertEqual(failed.evaluation.state, .failed)
        XCTAssertEqual(failed.evaluation.reason, "the log contains \"Traceback\"")
    }

    func testWhatTheChecksRememberSurvivesALookThatSkipsThem() {
        let checks = [Check.logPattern(path: "/tmp/job.log", contains: "done", notContains: nil)]
        host.put("/tmp/job.log", modified: "2026-11-13 02:05", contents: "done\n")
        assess(at: "2026-11-14 01:59", checks, Scenario.loaded(runs: 3))
        let remembered = record?.checkState

        // While the job runs its checks are skipped, and the note taken before the run must still be there.
        assess(at: "2026-11-14 02:01", checks, Scenario.loaded(runs: 4, running: true))
        XCTAssertEqual(record?.checkState, remembered)

        host.put("/tmp/job.log", modified: "2026-11-14 02:04", contents: "done\nstarting\n")
        let after = assess(at: "2026-11-14 02:05", checks, Scenario.loaded(runs: 4))
        XCTAssertEqual(after.evaluation.state, .failed)
        XCTAssertEqual(after.evaluation.reason, "the log does not contain \"done\" since 2026-11-14 02:00")
    }

    // MARK: - Wording

    func testLabelsAndSummaries() {
        XCTAssertEqual(Check.fileAge(path: "~/Reports/*.md", maxAge: nil).label, "file-age ~/Reports/*.md")
        XCTAssertEqual(Check.fileSize(path: "/backup/*.tar", minBytes: 1).label, "file-size /backup/*.tar")
        XCTAssertEqual(Check.command(arguments: ["/usr/bin/verify", "--all"], timeout: 30).label, "command /usr/bin/verify")
        XCTAssertEqual(Check.logPattern(path: "/tmp/x.log", contains: "a", notContains: nil).label, "log-pattern /tmp/x.log")
        XCTAssertEqual(Check.logPattern(path: nil, contains: "a", notContains: nil).label, "log-pattern (the job's log)")

        XCTAssertEqual(CheckOutcome(result: .passed).summary, "passed")
        XCTAssertEqual(CheckOutcome(result: .failed("no file matches x")).summary, "failed: no file matches x")
        XCTAssertEqual(CheckOutcome(result: .couldNotRun("x could not be read")).summary, "could not be carried out: x could not be read")
    }

    // MARK: - Helpers

    @discardableResult
    private func assess(at moment: String, _ checks: [Check], _ evidence: Evidence, logs: [String] = [], grace: TimeInterval = 30 * 60) -> JobAssessor.Assessment {
        let job = Job(
            id: "job", name: "Job", hostID: "local", source: .launchd(label: "com.example.job"),
            schedule: nil, grace: grace, notify: true, checks: checks
        )
        let assessment = JobAssessor.assess(
            job: job,
            evidence: evidence,
            host: host,
            defaultLogPaths: logs,
            previous: record,
            now: TestClock.date(moment),
            calendar: TestClock.utc
        )
        record = assessment.evaluation.record
        return assessment
    }
}
