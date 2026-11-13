import AjoissaCore
import XCTest

final class JobReportTests: XCTestCase {
    // MARK: - The status at a glance

    func testNoJobsIsAllFine() {
        XCTAssertEqual(OverallStatus(reports: []), .allFine)
    }

    func testStatesThatAreNotProblemsAreAllFine() {
        XCTAssertEqual(OverallStatus(reports: reports(.ok, .running, .waiting, .unknown)), .allFine)
    }

    func testMissedStaleAndOfflineNeedAttention() {
        for state in [JobState.missed, .stale, .hostOffline] {
            XCTAssertEqual(OverallStatus(reports: reports(.ok, state)), .needsAttention, state.rawValue)
        }
    }

    func testAFailureOutweighsEverythingElse() {
        XCTAssertEqual(OverallStatus(reports: reports(.missed, .failed, .ok)), .failure)
    }

    // MARK: - Grouping

    func testJobsAreGroupedByHostInConfigOrder() {
        let hosts = [Host.local, Host(id: "nas", connection: .ssh(alias: "nas"), mayBeOffline: false)]
        let groups = HostGroup.groups(of: [
            report("on-nas", .ok, host: "nas"),
            report("on-mac", .ok)
        ], hosts: hosts)

        XCTAssertEqual(groups.map(\.host.id), ["local", "nas"])
        XCTAssertEqual(groups.map { $0.reports.map(\.id) }, [["on-mac"], ["on-nas"]])
    }

    func testAHostWithNoJobsIsLeftOut() {
        let hosts = [Host.local, Host(id: "nas", connection: .ssh(alias: "nas"), mayBeOffline: false)]
        XCTAssertEqual(HostGroup.groups(of: [report("a", .ok, host: "nas")], hosts: hosts).map(\.host.id), ["nas"])
    }

    func testProblemsComeFirstThenByName() {
        let groups = HostGroup.groups(of: [
            report("fine-b", .ok),
            report("waiting", .waiting),
            report("missed", .missed),
            report("fine-a", .ok),
            report("unknown", .unknown),
            report("failed", .failed),
            report("running", .running),
            report("stale", .stale),
            report("offline", .hostOffline)
        ], hosts: [.local])

        XCTAssertEqual(groups.first?.reports.map(\.id), [
            "failed", "missed", "stale", "offline", "unknown", "running", "waiting", "fine-a", "fine-b"
        ])
    }

    func testNamesAreSortedAsAPersonWould() {
        let groups = HostGroup.groups(of: [report("job 10", .ok), report("job 9", .ok), report("Job 1", .ok)], hosts: [.local])
        XCTAssertEqual(groups.first?.reports.map(\.id), ["Job 1", "job 9", "job 10"])
    }

    // MARK: - Schedules in words

    func testScheduleSummaries() throws {
        let time = try XCTUnwrap(TimeOfDay(hour: 2, minute: 5))
        XCTAssertEqual(Schedule.daily(at: time).summary, "daily at 02:05")
        XCTAssertEqual(Schedule.weekly(on: .mon, at: time).summary, "Mon at 02:05")
        XCTAssertEqual(Schedule.every(900).summary, "every 15m")
        XCTAssertEqual(Schedule.every(86400).summary, "every 1d")
    }

    // MARK: - Helpers

    private func reports(_ states: JobState...) -> [JobReport] {
        states.enumerated().map { report("job-\($0.offset)", $0.element) }
    }

    private func report(_ id: String, _ state: JobState, host: String = Host.localID) -> JobReport {
        let job = Job(id: id, name: id, hostID: host, source: nil, schedule: nil, grace: Job.defaultGrace, notify: true, checks: [])
        return JobReport(job: job, state: state, reason: "")
    }
}
