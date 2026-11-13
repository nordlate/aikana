import AjoissaCore
import XCTest

final class WatchSessionTests: WatchTestCase {
    private var configURL: URL { root.appending(path: "config.json5") }
    private var historyURL: URL { root.appending(path: "state/history.json") }
    private let now = TestClock.date("2026-11-14 09:00")

    func testARoundLooksAtTheJobsAndRemembersThem() throws {
        try addFailingAgent()
        try writeConfig(Self.configText(jobs: Self.failingAgentJob))

        guard case let .looked(config, reports, saveProblem) = round() else {
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

        guard case let .looked(_, reports, saveProblem) = round() else {
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

        guard case let .looked(_, reports, _) = round() else {
            return XCTFail("Expected the jobs to be looked at")
        }
        XCTAssertEqual(reports.map(\.id), ["other"])
        XCTAssertEqual(try HistoryFile(url: historyURL).load().jobs.keys.sorted(), ["other"])
    }

    private func round() -> WatchSession.Outcome {
        WatchSession(configURL: configURL, historyFile: HistoryFile(url: historyURL), watch: watch).round(now: now, calendar: calendar)
    }

    private func writeConfig(_ text: String) throws {
        try Data(text.utf8).write(to: configURL)
    }

    private func writeHistory(_ history: History) throws {
        try HistoryFile(url: historyURL).save(history)
    }
}
