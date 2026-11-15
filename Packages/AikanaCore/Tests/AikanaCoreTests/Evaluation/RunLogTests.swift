import AikanaCore
import XCTest

/// The runs kept for showing follow the verdicts, one mark per run, each with the verdict it settled on.
final class RunLogTests: XCTestCase {
    private var runs: [RunMark] = []

    private func look(_ job: Scenario, at moment: String, _ evidence: Evidence) {
        runs = RunLog.note(job.evaluate(at: moment, evidence), in: runs)
    }

    private func mark(_ moment: String, _ outcome: RunMark.Outcome) -> RunMark {
        RunMark(date: TestClock.date(moment), outcome: outcome)
    }

    func testOneMarkPerRunWithTheVerdictItSettledOn() {
        let job = Scenario(grace: 30 * 60)
        look(job, at: "2026-11-12 12:00", Scenario.loaded(runs: 2))
        XCTAssertEqual(runs, [], "nothing was due while watched")

        look(job, at: "2026-11-13 02:01", Scenario.loaded(runs: 3))
        look(job, at: "2026-11-13 23:00", Scenario.loaded(runs: 3))
        look(job, at: "2026-11-14 02:05", Scenario.loaded(runs: 4))
        look(job, at: "2026-11-14 20:00", Scenario.loaded(runs: 4))
        XCTAssertEqual(runs, [mark("2026-11-13 02:00", .ok), mark("2026-11-14 02:00", .ok)])

        look(job, at: "2026-11-15 02:10", Scenario.loaded(runs: 4))
        XCTAssertEqual(runs.count, 2, "a run that still has time is not marked")
        look(job, at: "2026-11-15 03:00", Scenario.loaded(runs: 4))
        look(job, at: "2026-11-15 04:00", Scenario.loaded(runs: 4))
        XCTAssertEqual(runs.last, mark("2026-11-15 02:00", .missed))
        XCTAssertEqual(runs.count, 3, "a missed run is marked once")

        look(job, at: "2026-11-15 05:00", Scenario.loaded(runs: 5, exit: .code(1)))
        XCTAssertEqual(runs, [mark("2026-11-13 02:00", .ok), mark("2026-11-14 02:00", .ok), mark("2026-11-15 02:00", .failed)])
    }

    func testStatesThatSayNothingAboutTheJobLeaveTheRunsAlone() {
        let job = Scenario.watchedSinceYesterday()
        runs = [mark("2026-11-13 02:00", .ok)]
        look(job, at: "2026-11-14 02:01", Scenario.loaded(runs: 3, running: true))
        look(job, at: "2026-11-14 03:00", Evidence(source: SourceEvidence(availability: .unknown(reason: "launchctl did not answer"))))
        XCTAssertEqual(runs, [mark("2026-11-13 02:00", .ok)])
    }

    func testOnlyTheLatestRunsAreKept() {
        let job = Scenario.watchedSinceYesterday()
        runs = (0..<RunLog.limit).map { RunMark(date: TestClock.date("2026-10-01 02:00").addingTimeInterval(Double($0) * 86_400), outcome: .ok) }
        look(job, at: "2026-11-14 02:05", Scenario.loaded(runs: 4))
        XCTAssertEqual(runs.count, RunLog.limit)
        XCTAssertEqual(runs.last, mark("2026-11-14 02:00", .ok))
    }
}
