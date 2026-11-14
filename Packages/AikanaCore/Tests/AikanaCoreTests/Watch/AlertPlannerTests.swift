import AikanaCore
import XCTest

final class AlertPlannerTests: XCTestCase {
    private var history = History()

    // MARK: - Once per incident

    func testAProblemIsToldOnce() {
        XCTAssertEqual(plan(("a", .failed)).map(\.kind), [.problem(.failed)])
        XCTAssertEqual(plan(("a", .failed)), [])
        XCTAssertEqual(plan(("a", .failed)), [])
    }

    func testEachProblemStateIsTold() {
        for state in [JobState.failed, .missed, .stale] {
            history = History()
            XCTAssertEqual(plan(("a", state)).map(\.kind), [.problem(state)], state.rawValue)
        }
    }

    func testStatesThatAreNotProblemsAreNotTold() {
        for state in [JobState.ok, .waiting, .running, .unknown, .hostOffline] {
            history = History()
            XCTAssertEqual(plan(("a", state)), [], state.rawValue)
        }
    }

    func testAProblemThatTurnsIntoAnotherIsToldAgain() {
        _ = plan(("a", .missed))
        XCTAssertEqual(plan(("a", .failed)).map(\.kind), [.problem(.failed)])
        XCTAssertEqual(plan(("a", .failed)), [])
    }

    func testAJobThatFailsAgainBeforeItWasFineIsNotToldAgain() {
        _ = plan(("a", .failed))
        for state in [JobState.waiting, .running, .unknown, .hostOffline] {
            XCTAssertEqual(plan(("a", state)), [], state.rawValue)
        }
        XCTAssertEqual(plan(("a", .failed)), [])
    }

    func testHavingToldIsRememberedInTheRecord() {
        _ = plan(("a", .missed))
        XCTAssertEqual(history.jobs["a"]?.alerted, .missed)
        _ = plan(("a", .ok))
        XCTAssertNil(history.jobs["a"]?.alerted)
    }

    // MARK: - Recovery

    func testRecoveryIsToldOnceWhenTheJobIsFineAgain() {
        _ = plan(("a", .failed))
        _ = plan(("a", .waiting))
        _ = plan(("a", .running))

        let alerts = plan(("a", .ok), reason: "the run due at 2026-11-14 02:00 happened")

        XCTAssertEqual(alerts, [
            Alert(kind: .recovered, jobID: "a", jobName: "Job a", hostID: "local", reason: "the run due at 2026-11-14 02:00 happened")
        ])
        XCTAssertEqual(plan(("a", .ok)), [])
    }

    func testAJobThatWasNeverInTroubleDoesNotRecover() {
        _ = plan(("a", .waiting))
        XCTAssertEqual(plan(("a", .ok)), [])
    }

    func testANewIncidentAfterARecoveryIsToldAgain() {
        _ = plan(("a", .failed))
        _ = plan(("a", .ok))
        XCTAssertEqual(plan(("a", .failed)).map(\.kind), [.problem(.failed)])
    }

    // MARK: - Which jobs

    func testAJobThatMustNotNotifyIsNeverTold() {
        XCTAssertEqual(plan(("a", .failed), notify: false), [])
        XCTAssertNil(history.jobs["a"]?.alerted)
        XCTAssertEqual(plan(("a", .ok), notify: false), [])
    }

    func testSwitchingAJobToNotNotifyDropsItsRecovery() {
        _ = plan(("a", .failed))
        XCTAssertEqual(plan(("a", .failed), notify: false), [])
        XCTAssertEqual(plan(("a", .ok)), [])
    }

    func testAJobThatWasNotJudgedIsLeftAlone() {
        let job = Job(id: "far", name: "far", hostID: "nas", source: nil, schedule: nil, grace: 0, notify: true, checks: [])
        let report = JobReport(job: job, state: .unknown, reason: "not judged yet", isJudged: false)
        XCTAssertEqual(AlertPlanner.plan(reports: [report], history: &history), [])
        XCTAssertNil(history.jobs["far"])
    }

    func testSeveralChangesInOneLookComeTogetherProblemsFirst() {
        _ = plan(("was-bad", .failed), ("fine", .ok))

        let alerts = plan(("was-bad", .ok), ("fine", .ok), ("b", .missed), ("c", .failed))

        XCTAssertEqual(alerts.map(\.jobID), ["b", "c", "was-bad"])
        XCTAssertEqual(alerts.map(\.kind), [.problem(.missed), .problem(.failed), .recovered])
    }

    // MARK: - As one notification

    func testNoAlertsIsNoAnnouncement() {
        XCTAssertNil(Announcement(alerts: []))
    }

    func testOneProblemNamesTheJobTheHostAndTheReason() {
        let failed = Alert(kind: .problem(.failed), jobID: "a", jobName: "Nightly report", hostID: "local", reason: "its last run exited with code 3")
        XCTAssertEqual(Announcement(alerts: [failed]), Announcement(
            title: "Nightly report failed",
            body: "This Mac: its last run exited with code 3",
            jobID: "a"
        ))
        let missed = Alert(kind: .problem(.missed), jobID: "b", jobName: "Backup", hostID: "nas", reason: "the run due at 2026-11-14 02:00 has not happened")
        XCTAssertEqual(Announcement(alerts: [missed]), Announcement(
            title: "Backup missed a run",
            body: "nas: the run due at 2026-11-14 02:00 has not happened",
            jobID: "b"
        ))
        let stale = Alert(kind: .problem(.stale), jobID: "c", jobName: "Sync", hostID: "local", reason: "its state has not been readable since 2026-11-13 02:00: no answer")
        XCTAssertEqual(Announcement(alerts: [stale])?.title, "Sync cannot be read")
    }

    func testOneRecovery() {
        let alert = Alert(kind: .recovered, jobID: "a", jobName: "Nightly report", hostID: "local", reason: "the run due at 2026-11-14 02:00 happened")
        XCTAssertEqual(Announcement(alerts: [alert]), Announcement(
            title: "Nightly report is fine again",
            body: "This Mac: the run due at 2026-11-14 02:00 happened",
            jobID: "a"
        ))
    }

    func testSeveralAlertsAreOneAnnouncementWithALineEach() {
        let alerts = [
            Alert(kind: .problem(.failed), jobID: "a", jobName: "Report", hostID: "local", reason: "its last run exited with code 3"),
            Alert(kind: .problem(.missed), jobID: "b", jobName: "Backup", hostID: "nas", reason: "the run due at 02:00 has not happened"),
            Alert(kind: .recovered, jobID: "c", jobName: "Sync", hostID: "local", reason: "its checks pass")
        ]
        XCTAssertEqual(Announcement(alerts: alerts), Announcement(
            title: "2 jobs have problems, 1 is fine again",
            body: """
                Report (This Mac) failed: its last run exited with code 3
                Backup (nas) missed a run: the run due at 02:00 has not happened
                Sync (This Mac) is fine again: its checks pass
                """,
            jobID: nil
        ))
    }

    func testTitlesOfSeveral() {
        func title(_ kinds: Alert.Kind...) -> String? {
            Announcement(alerts: kinds.map { Alert(kind: $0, jobID: "a", jobName: "a", hostID: "local", reason: "") })?.title
        }
        XCTAssertEqual(title(.problem(.failed), .problem(.missed)), "2 jobs have problems")
        XCTAssertEqual(title(.recovered, .recovered, .recovered), "3 jobs are fine again")
        XCTAssertEqual(title(.problem(.failed), .recovered, .recovered), "1 job has a problem, 2 are fine again")
    }

    func testManyAlertsAreCutShort() {
        let alerts = (1...7).map { Alert(kind: .problem(.failed), jobID: "\($0)", jobName: "Job \($0)", hostID: "local", reason: "r") }
        let body = Announcement(alerts: alerts)?.body ?? ""
        XCTAssertEqual(body.split(separator: "\n").count, 5)
        XCTAssertTrue(body.hasSuffix("\nand 3 more"))
    }

    // MARK: - Helpers

    /// One look: each job is found in the given state, as the watch would leave it in the history.
    private func plan(_ jobs: (id: String, state: JobState)..., notify: Bool = true, reason: String = "why") -> [Alert] {
        let reports = jobs.map { id, state in
            let job = Job(id: id, name: "Job \(id)", hostID: "local", source: nil, schedule: nil, grace: 0, notify: notify, checks: [])
            var record = history.jobs[id] ?? JobRecord(watchingSince: .distantPast)
            record.state = state
            history.jobs[id] = record
            return JobReport(job: job, state: state, reason: reason)
        }
        return AlertPlanner.plan(reports: reports, history: &history)
    }
}
