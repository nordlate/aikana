import AjoissaCore
import XCTest

final class WatchSessionTests: WatchTestCase {
    private var configURL: URL { root.appending(path: "config.json5") }
    private var historyURL: URL { root.appending(path: "state/history.json") }
    private let now = TestClock.date("2026-11-14 09:00")

    func testARoundLooksAtTheJobsAndRemembersThem() throws {
        try addFailingAgent()
        try writeConfig(Self.configText(jobs: Self.failingAgentJob))

        guard case let .looked(config, reports, _, saveProblem) = round() else {
            return XCTFail("Expected the jobs to be looked at")
        }

        XCTAssertEqual(config.jobs.map(\.id), ["report"])
        XCTAssertEqual(reports.map(\.state), [.failed])
        XCTAssertNil(saveProblem)
        XCTAssertEqual(try HistoryFile(url: historyURL).load().jobs["report"]?.state, .failed)
    }

    func testAMissingConfigIsAConfigProblem() {
        guard case let .configProblem(.unreadable(path, _)) = round() else {
            return XCTFail("Expected an unreadable config")
        }
        XCTAssertEqual(path, configURL.path)
        XCTAssertFalse(FileManager.default.fileExists(atPath: historyURL.path))
    }

    func testAnInvalidConfigIsReportedWithEveryProblemAndTheHistoryIsLeftAlone() throws {
        try writeConfig("{ version: 1, jobs: [ { id: 'a', colour: 'red' }, { id: 'a' } ] }")
        try writeHistory(History(jobs: ["kept": JobRecord(watchingSince: now)]))

        guard case let .configProblem(error) = round() else {
            return XCTFail("Expected a config problem")
        }

        XCTAssertGreaterThan(error.lines.count, 1)
        XCTAssertEqual(try HistoryFile(url: historyURL).load().jobs.keys.sorted(), ["kept"])
    }

    func testAnUnreadableHistoryStopsTheRoundAndIsNotReplaced() throws {
        try addFailingAgent()
        try writeConfig(Self.configText(jobs: Self.failingAgentJob))
        try FileManager.default.createDirectory(at: historyURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("not a history".utf8).write(to: historyURL)

        XCTAssertEqual(round(), .historyProblem(.unreadable(path: historyURL.path, reason: "it is not a valid history file")))
        XCTAssertEqual(try Data(contentsOf: historyURL), Data("not a history".utf8))
        XCTAssertTrue(runner.calls.isEmpty)
    }

    func testAHistoryThatCannotBeSavedStillGivesTheReports() throws {
        try addFailingAgent()
        try writeConfig(Self.configText(jobs: Self.failingAgentJob))
        // A folder nothing can be written into.
        let folder = historyURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: folder.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.path) }

        guard case let .looked(_, reports, _, saveProblem) = round() else {
            return XCTFail("Expected the jobs to be looked at")
        }

        XCTAssertEqual(reports.map(\.state), [.failed])
        guard case .unwritable = saveProblem else {
            return XCTFail("Expected a save problem, got \(String(describing: saveProblem))")
        }
    }

    func testAChangedConfigIsUsedAtTheNextRound() throws {
        try addFailingAgent()
        try writeConfig(Self.configText(jobs: Self.failingAgentJob))
        _ = round()

        try writeConfig(Self.configText(jobs: "{ id: 'other', schedule: { every: '1h' }, checks: [ { type: 'file-age', path: '/b/*' } ] }"))

        guard case let .looked(_, reports, _, _) = round() else {
            return XCTFail("Expected the jobs to be looked at")
        }
        XCTAssertEqual(reports.map(\.id), ["other"])
        XCTAssertEqual(try HistoryFile(url: historyURL).load().jobs.keys.sorted(), ["other"])
    }

    // MARK: - Announcing

    func testARoundThatAnnouncesTellsAProblemOnceAndRemembersHavingToldIt() throws {
        try addFailingAgent()
        try writeConfig(Self.configText(jobs: Self.failingAgentJob))

        XCTAssertEqual(alerts(of: round(announce: true)), [
            Alert(kind: .problem(.failed), jobID: "report", jobName: "Nightly report", hostID: "local", reason: "its last run exited with code 3")
        ])
        XCTAssertEqual(try HistoryFile(url: historyURL).load().jobs["report"]?.alerted, .failed)
        XCTAssertEqual(alerts(of: round(announce: true)), [])
    }

    func testARoundThatDoesNotAnnounceLeavesTheProblemToBeTold() throws {
        try addFailingAgent()
        try writeConfig(Self.configText(jobs: Self.failingAgentJob))

        XCTAssertEqual(alerts(of: round()), [])
        XCTAssertNil(try HistoryFile(url: historyURL).load().jobs["report"]?.alerted)
        XCTAssertEqual(alerts(of: round(announce: true))?.map(\.kind), [.problem(.failed)])
        // And a look that does not announce afterwards does not forget that it was told.
        XCTAssertEqual(alerts(of: round()), [])
        XCTAssertEqual(alerts(of: round(announce: true)), [])
    }

    private func alerts(of outcome: WatchSession.Outcome) -> [Alert]? {
        if case let .looked(_, _, alerts, _) = outcome {
            return alerts
        }
        return nil
    }

    private func round(announce: Bool = false) -> WatchSession.Outcome {
        WatchSession(configURL: configURL, historyFile: HistoryFile(url: historyURL), watch: watch)
            .round(now: now, calendar: calendar, announce: announce)
    }

    private func writeConfig(_ text: String) throws {
        try Data(text.utf8).write(to: configURL)
    }

    private func writeHistory(_ history: History) throws {
        try HistoryFile(url: historyURL).save(history)
    }
}
