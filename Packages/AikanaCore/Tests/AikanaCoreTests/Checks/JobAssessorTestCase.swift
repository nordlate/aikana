import AikanaCore
import XCTest

/// What the assessor tests share: a host, the record one look leaves for the next, and a way to look.
class JobAssessorTestCase: XCTestCase {
    var host: FakeHost!
    var record: JobRecord?
    let backup = "/backup/*.tar"

    override func setUp() {
        host = FakeHost()
        record = Scenario.watchedSinceYesterday().record
    }

    // MARK: - Helpers

    @discardableResult
    func assess(
        at moment: String,
        _ checks: [Check],
        _ evidence: Evidence,
        logs: [String] = [],
        grace: TimeInterval = 30 * 60,
        source: JobSource? = .launchd(label: "com.example.job"),
        schedule: Schedule? = nil
    ) -> JobAssessor.Assessment {
        let job = Job(
            id: "job", name: "Job", hostID: "local", source: source,
            schedule: schedule, grace: grace, notify: true, checks: checks
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
