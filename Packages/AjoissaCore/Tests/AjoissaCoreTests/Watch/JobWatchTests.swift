import AjoissaCore
import XCTest

final class JobWatchTests: WatchTestCase {
    private let now = TestClock.date("2026-11-14 09:00")

    func testALaunchdJobIsReportedWithWhatItsSchedulerSaid() throws {
        try addFailingAgent()
        var history = History()

        let reports = try look(Self.failingAgentJob, history: &history)

        let report = try XCTUnwrap(reports.first)
        XCTAssertEqual(report.id, "report")
        XCTAssertEqual(report.state, .failed)
        XCTAssertEqual(report.reason, "its last run exited with code 3")
        XCTAssertTrue(report.isJudged)
        XCTAssertEqual(report.source, "launchd com.example.exit-3")
        XCTAssertEqual(report.sourceStatus, "loaded, not running, 1 run, last exit code 3")
        XCTAssertEqual(report.schedule, "daily at 02:00")
        XCTAssertEqual(report.nextRun, TestClock.date("2026-11-15 02:00"))
        XCTAssertEqual(report.logPaths, ["/tmp/com.example.exit3.log"])
        XCTAssertTrue(report.changed)
        XCTAssertEqual(report.transitions.map(\.state), [.failed])
        XCTAssertEqual(history.jobs["report"]?.state, .failed)
    }

    func testTheSecondLookIsNotNews() throws {
        try addFailingAgent()
        var history = History()
        _ = try look(Self.failingAgentJob, history: &history)

        let report = try XCTUnwrap(try look(Self.failingAgentJob, history: &history, at: "2026-11-14 09:01").first)

        XCTAssertEqual(report.state, .failed)
        XCTAssertFalse(report.changed)
    }

    func testAScheduleInTheConfigIsTheOneShown() throws {
        try addFailingAgent()
        var history = History()
        let job = "{ id: 'report', source: { launchd: 'com.example.exit-3' }, schedule: { weekly: { day: 'mon', at: '06:30' } } }"

        XCTAssertEqual(try look(job, history: &history).first?.schedule, "Mon at 06:30")
    }

    func testAJobKnownOnlyThroughItsChecksReportsThem() throws {
        host.put("/backups/latest.tar", modified: "2026-11-14 02:10", size: 10)
        var history = History()
        let job = """
            { id: 'backup', schedule: { daily: '02:00' }, checks: [
                { type: 'file-age', path: '/backups/*.tar' },
                { type: 'file-size', path: '/backups/*.tar', minSize: '1KB' },
                { type: 'log-pattern', path: '/backups/backup.log', notContains: 'error' }
            ] }
            """

        let report = try XCTUnwrap(try look(job, history: &history).first)

        XCTAssertNil(report.source)
        XCTAssertNil(report.sourceStatus)
        XCTAssertEqual(report.schedule, "daily at 02:00")
        XCTAssertEqual(report.state, .failed)
        XCTAssertEqual(report.reason, "/backups/latest.tar is 10 B, less than the 1 KB it should be")
        XCTAssertEqual(report.checks.map(\.label), ["file-age /backups/*.tar", "file-size /backups/*.tar", "log-pattern /backups/backup.log"])
        XCTAssertEqual(report.checks.first?.outcome.result, .passed)
        XCTAssertEqual(report.logPaths, ["/backups/backup.log"])
    }

    func testAJobOfASchedulerThatIsNotReadYetIsNotJudged() throws {
        var history = History()

        let report = try XCTUnwrap(try look("{ id: 'tab', source: { cron: 'backup.sh' } }", history: &history).first)

        XCTAssertFalse(report.isJudged)
        XCTAssertEqual(report.reason, "not judged yet: of the schedulers, only launchd is read so far")
        XCTAssertTrue(history.jobs.isEmpty)
    }

    func testReportsComeInTheOrderOfTheConfigAndRemovedJobsAreForgotten() throws {
        try addFailingAgent()
        var history = History(jobs: ["gone": JobRecord(watchingSince: now)])

        let reports = try look("{ id: 'b', schedule: { every: '1h' }, checks: [ { type: 'file-age', path: '/b/*' } ] }, \(Self.failingAgentJob)", history: &history)

        XCTAssertEqual(reports.map(\.id), ["b", "report"])
        XCTAssertEqual(history.jobs.keys.sorted(), ["b", "report"])
    }

    private func look(_ jobs: String, hosts: String = "", history: inout History, at time: String? = nil) throws -> [JobReport] {
        let config = try ConfigFixture.load(Self.configText(jobs: jobs, hosts: hosts))
        return watch.look(at: config, history: &history, now: time.map { TestClock.date($0) } ?? now, calendar: calendar)
    }
}
