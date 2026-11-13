@testable import Ajoissa
import AjoissaCore
import XCTest

/// Hands out the outcomes a test has lined up, one per round, and counts the rounds.
private actor Rounds {
    private var outcomes: [WatchSession.Outcome]
    private(set) var count = 0
    private var gate: CheckedContinuation<Void, Never>?
    private var holdsNext = false

    init(_ outcomes: [WatchSession.Outcome]) {
        self.outcomes = outcomes
    }

    /// Makes the next round wait until `release` is called.
    func holdNext() {
        holdsNext = true
    }

    func release() {
        gate?.resume()
        gate = nil
    }

    func next() async -> WatchSession.Outcome {
        count += 1
        if holdsNext {
            holdsNext = false
            await withCheckedContinuation { gate = $0 }
        }
        return outcomes.count > 1 ? outcomes.removeFirst() : outcomes[0]
    }
}

private final class Fingerprint: @unchecked Sendable {
    private let lock = NSLock()
    private var stored = "1"

    var value: String {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}

@MainActor
final class WatchModelTests: XCTestCase {
    private let fingerprint = Fingerprint()

    // MARK: - What is shown

    func testBeforeTheFirstLook() {
        let model = model(rounds: Rounds([looked()]))

        XCTAssertEqual(model.content, .starting)
        XCTAssertEqual(model.menuBarSymbolName, "clock")
        XCTAssertEqual(model.headline, "Looking…")
        XCTAssertNil(model.lastLooked)
    }

    func testEverythingFine() async {
        let model = model(rounds: Rounds([looked(report("a", .ok), report("b", .waiting))]))

        await model.refresh()

        XCTAssertEqual(model.menuBarSymbolName, "clock.badge.checkmark")
        XCTAssertEqual(model.headline, "Everything is fine")
        XCTAssertEqual(model.reports.map(\.id), ["b", "a"])
        XCTAssertNotNil(model.lastLooked)
        XCTAssertFalse(model.isLooking)
    }

    func testAMissedJobNeedsAttention() async {
        let model = model(rounds: Rounds([looked(report("a", .ok), report("b", .missed))]))

        await model.refresh()

        XCTAssertEqual(model.menuBarSymbolName, "clock.badge.exclamationmark")
        XCTAssertEqual(model.headline, "1 needs attention")
    }

    func testAFailedJobIsAFailure() async {
        let model = model(rounds: Rounds([looked(report("a", .failed), report("b", .missed), report("c", .stale))]))

        await model.refresh()

        XCTAssertEqual(model.menuBarSymbolName, "clock.badge.xmark")
        XCTAssertEqual(model.headline, "1 failed, 2 need attention")
        XCTAssertEqual(model.report(withID: "b")?.state, .missed)
        XCTAssertNil(model.report(withID: "gone"))
    }

    func testNoJobs() async {
        let model = model(rounds: Rounds([looked()]))

        await model.refresh()

        XCTAssertEqual(model.content, .jobs([]))
        XCTAssertEqual(model.headline, "No jobs configured")
        XCTAssertEqual(model.menuBarSymbolName, "clock.badge.checkmark")
    }

    func testABrokenConfigShowsEveryProblemInsteadOfAList() async {
        let issues = [ConfigIssue(path: "jobs[0] (a)", message: "needs a source"), ConfigIssue(path: "", message: "version is required")]
        let model = model(rounds: Rounds([.configProblem(.invalid(issues))]))

        await model.refresh()

        XCTAssertEqual(model.content, .configProblem(["jobs[0] (a): needs a source", "version is required"]))
        XCTAssertEqual(model.menuBarSymbolName, "clock.badge.exclamationmark")
        XCTAssertEqual(model.headline, "The config file cannot be used")
        XCTAssertTrue(model.reports.isEmpty)
    }

    func testAnUnreadableHistoryIsShown() async {
        let model = model(rounds: Rounds([.historyProblem(.unreadable(path: "/h.json", reason: "it is not a valid history file"))]))

        await model.refresh()

        XCTAssertEqual(model.content, .historyProblem(
            "/h.json cannot be used as the history: it is not a valid history file. Move it aside to start a new history; runs seen so far will then be forgotten."
        ))
        XCTAssertEqual(model.menuBarSymbolName, "clock.badge.exclamationmark")
    }

    func testAHistoryThatCannotBeSavedIsNotedBesideTheJobs() async {
        let outcome = WatchSession.Outcome.looked(
            config: config(),
            reports: [report("a", .ok)],
            saveProblem: .unwritable(path: "/h.json", reason: "the disk is full")
        )
        let model = model(rounds: Rounds([outcome, looked(report("a", .ok))]))

        await model.refresh()
        XCTAssertEqual(model.saveProblem, "What was seen could not be saved to /h.json: the disk is full")
        XCTAssertEqual(model.reports.map(\.id), ["a"])

        await model.refresh()
        XCTAssertNil(model.saveProblem)
    }

    func testAFixedConfigBringsTheListBack() async {
        let model = model(rounds: Rounds([.configProblem(.syntax(message: "line 3")), looked(report("a", .ok))]))

        await model.refresh()
        XCTAssertEqual(model.content, .configProblem(["Not valid JSON5: line 3"]))

        await model.refresh()
        XCTAssertEqual(model.reports.map(\.id), ["a"])
    }

    // MARK: - When it looks

    func testAnUnchangedConfigFileDoesNotCauseALook() async {
        let rounds = Rounds([looked()])
        let model = model(rounds: rounds)
        await model.refresh()

        await model.checkConfigFile()

        let count = await rounds.count
        XCTAssertEqual(count, 1)
    }

    func testAChangedConfigFileCausesOneLook() async {
        let rounds = Rounds([looked()])
        let model = model(rounds: rounds)
        await model.refresh()

        fingerprint.value = "2"
        await model.checkConfigFile()
        await model.checkConfigFile()

        let count = await rounds.count
        XCTAssertEqual(count, 2)
    }

    func testRequestsDuringALookAreAnsweredByOneMoreLook() async {
        let rounds = Rounds([looked()])
        let model = model(rounds: rounds)
        await rounds.holdNext()

        let first = Task { await model.refresh() }
        while await rounds.count < 1 {
            await Task.yield()
        }
        XCTAssertTrue(model.isLooking)
        await model.refresh()
        await model.refresh()
        await model.refresh()
        await rounds.release()
        await first.value

        let count = await rounds.count
        XCTAssertEqual(count, 2)
        XCTAssertFalse(model.isLooking)
    }

    // MARK: - Wording

    func testRowTimes() {
        let calendar = Calendar.current
        let now = calendar.date(from: DateComponents(year: 2026, month: 11, day: 14, hour: 9)) ?? .distantPast
        var report = report("a", .ok)
        XCTAssertNil(JobRowView.times(of: report, now: now))
        report.source = "launchd com.example.a"
        XCTAssertEqual(JobRowView.times(of: report, now: now), "No run seen yet")

        report.lastRun = calendar.date(from: DateComponents(year: 2026, month: 11, day: 14, hour: 2))
        report.nextRun = calendar.date(from: DateComponents(year: 2026, month: 11, day: 15, hour: 2))
        let last = Wording.moment(report.lastRun ?? now, now: now)
        let next = Wording.moment(report.nextRun ?? now, now: now)
        XCTAssertEqual(JobRowView.times(of: report, now: now), "Last run \(last) · Next \(next)")
        // Today is a time alone; another day says which.
        XCTAssertLessThan(last.count, next.count)
    }

    func testSentence() {
        XCTAssertEqual(Wording.sentence("its last run exited with code 3"), "Its last run exited with code 3")
        XCTAssertEqual(Wording.sentence(""), "")
    }

    // MARK: - Helpers

    private func model(rounds: Rounds) -> WatchModel {
        let fingerprint = fingerprint
        return WatchModel(environment: WatchModel.Environment(
            configURL: URL(fileURLWithPath: "/tmp/example/config.json5"),
            historyURL: URL(fileURLWithPath: "/tmp/example/history.json"),
            round: { _ in await rounds.next() },
            configFingerprint: { fingerprint.value },
            readLog: { _ in .missing }
        ))
    }

    private func looked(_ reports: JobReport...) -> WatchSession.Outcome {
        .looked(config: config(), reports: reports, saveProblem: nil)
    }

    private func config() -> Config {
        // The jobs shown come from the reports; the config only says which machines there are.
        let text = "{ version: 1, jobs: [ { id: 'x', source: { launchd: 'com.example.x' } } ] }"
        // swiftlint:disable:next force_unwrapping
        return (try? ConfigLoader.load(Data(text.utf8)))!
    }

    private func report(_ id: String, _ state: JobState) -> JobReport {
        let job = Job(id: id, name: id, hostID: "local", source: nil, schedule: nil, grace: Job.defaultGrace, notify: true, checks: [])
        return JobReport(job: job, state: state, reason: "")
    }
}
