import AjoissaCore
import Foundation

/// One job followed through time: each evaluation gets the record the previous one left.
final class Scenario {
    static let daily0200 = Timetable(calendarRules: [.init(minute: 0, hour: 2)])

    var job: Job
    var record: JobRecord?
    var calendar = TestClock.utc

    init(source: JobSource? = .launchd(label: "com.example.job"), schedule: Schedule? = nil, grace: TimeInterval = 30 * 60) {
        job = Job(id: "job", name: "Job", hostID: "local", source: source, schedule: schedule, grace: grace, notify: true, checks: [])
    }

    @discardableResult
    func evaluate(at moment: String, _ evidence: Evidence) -> JobEvaluation {
        let evaluation = JobEvaluator.evaluate(
            job: job,
            evidence: evidence,
            previous: record,
            now: TestClock.date(moment, calendar: calendar),
            calendar: calendar
        )
        record = evaluation.record
        return evaluation
    }

    /// Evidence from a loaded launchd job.
    static func loaded(
        runs: Int?,
        exit: RunExit? = .code(0),
        running: Bool = false,
        log: String? = nil,
        timetable: Timetable? = daily0200,
        awakeSince: String? = nil,
        checks: [CheckOutcome] = []
    ) -> Evidence {
        Evidence(
            source: SourceEvidence(
                availability: .available,
                timetable: timetable,
                isRunning: running,
                runCount: runs,
                lastExit: exit,
                logModified: log.map { TestClock.date($0) }
            ),
            awakeSince: awakeSince.map { TestClock.date($0) },
            checks: checks
        )
    }

    /// A job that has been watched since the day before, with its run of 2026-11-13 seen and fine.
    static func watchedSinceYesterday(grace: TimeInterval = 30 * 60) -> Scenario {
        let scenario = Scenario(grace: grace)
        scenario.evaluate(at: "2026-11-12 12:00", loaded(runs: 2))
        scenario.evaluate(at: "2026-11-13 02:01", loaded(runs: 3))
        scenario.evaluate(at: "2026-11-13 23:00", loaded(runs: 3))
        return scenario
    }
}
