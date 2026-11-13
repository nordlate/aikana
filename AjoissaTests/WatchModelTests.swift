@testable import Ajoissa
import AjoissaCore
import XCTest

@MainActor
final class WatchModelTests: WatchModelTestCase {
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
            alerts: [],
            saveProblem: .unwritable(path: "/h.json", reason: "the disk is full")
        )
        let model = model(rounds: Rounds([outcome, looked(report("a", .ok))]))

        await model.refresh()
        XCTAssertEqual(model.saveProblem, "What was seen could not be saved to /h.json: the disk is full")
        XCTAssertEqual(model.reports.map(\.id), ["a"])
        XCTAssertEqual(model.menuBarSymbolName, "clock.badge.exclamationmark")

        await model.refresh()
        XCTAssertNil(model.saveProblem)
        XCTAssertEqual(model.menuBarSymbolName, "clock.badge.checkmark")
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

    func testALookThatDoesNotComeBackIsSaidToBeUnderWay() async {
        let rounds = Rounds([looked()])
        let model = model(rounds: rounds)
        await model.refresh()
        XCTAssertEqual(model.lookNote()?.hasPrefix("Looked at "), true)
        XCTAssertNil(model.lookingSince)

        await rounds.holdNext()
        let stuck = Task { await model.refresh() }
        while await rounds.count < 2 {
            await Task.yield()
        }
        let began = model.lookingSince ?? .distantFuture
        XCTAssertEqual(model.lookNote(now: began.addingTimeInterval(60))?.hasPrefix("Looked at "), true)
        XCTAssertEqual(model.lookNote(now: began.addingTimeInterval(120))?.hasPrefix("Still looking since "), true)

        await rounds.release()
        await stuck.value
        XCTAssertNil(model.lookingSince)
    }
}
