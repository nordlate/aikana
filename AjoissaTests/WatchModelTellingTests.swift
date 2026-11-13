@testable import Ajoissa
import AjoissaCore
import XCTest

@MainActor
final class WatchModelTellingTests: WatchModelTestCase {
    func testTheAlertsOfALookAreToldAsOneNotification() async {
        let model = model(rounds: Rounds([looked(alerts: [failed("a"), missed("b")]), looked()]))

        await model.refresh()
        await model.refresh()

        let announcements = await told.announcements
        XCTAssertEqual(announcements.map(\.title), ["2 jobs have problems"])
    }

    func testOneAlertOpensItsJob() async {
        let model = model(rounds: Rounds([looked(alerts: [failed("a")])]))

        await model.refresh()

        let announcements = await told.announcements
        XCTAssertEqual(announcements, [Announcement(title: "a failed", body: "This Mac: why", jobID: "a")])
        model.showJob(withID: "a")
        XCTAssertEqual(model.shownJobID, "a")
    }

    func testAnAlertThatComesBackBecauseItCouldNotBeSavedIsToldOnce() async {
        let model = model(rounds: Rounds([looked(alerts: [failed("a")])]))

        await model.refresh()
        await model.refresh()
        await model.refresh()

        let count = await told.announcements.count
        XCTAssertEqual(count, 1)
    }

    func testAProblemAfterARecoveryIsToldAgain() async {
        let model = model(rounds: Rounds([looked(alerts: [failed("a")]), looked(alerts: [recovered("a")]), looked(alerts: [failed("a")])]))

        await model.refresh()
        await model.refresh()
        await model.refresh()

        let titles = await told.announcements.map(\.title)
        XCTAssertEqual(titles, ["a failed", "a is fine again", "a failed"])
    }

    func testNothingIsToldWithNotificationsOffAndNothingIsKeptForLater() async {
        let model = model(rounds: Rounds([looked(alerts: [failed("a")])]))
        model.notificationsEnabled = false

        await model.refresh()
        model.notificationsEnabled = true
        await model.refresh()

        let count = await told.announcements.count
        XCTAssertEqual(count, 0)
    }

    func testRecoveriesCanBeSwitchedOff() async {
        let model = model(rounds: Rounds([looked(alerts: [failed("a"), recovered("b")]), looked(alerts: [recovered("a")])]))
        model.notifiesRecovery = false

        await model.refresh()
        await model.refresh()

        let titles = await told.announcements.map(\.title)
        XCTAssertEqual(titles, ["a failed"])
    }

    func testSwitchesAreOnUntilSetAndAreRemembered() {
        let first = model(rounds: Rounds([looked()]))
        XCTAssertTrue(first.notificationsEnabled)
        XCTAssertTrue(first.notifiesRecovery)

        first.notificationsEnabled = false
        first.notifiesRecovery = false

        let second = model(rounds: Rounds([looked()]))
        XCTAssertFalse(second.notificationsEnabled)
        XCTAssertFalse(second.notifiesRecovery)
    }

    private func failed(_ id: String) -> Alert {
        Alert(kind: .problem(.failed), jobID: id, jobName: id, hostID: "local", reason: "why")
    }

    private func missed(_ id: String) -> Alert {
        Alert(kind: .problem(.missed), jobID: id, jobName: id, hostID: "local", reason: "why")
    }

    private func recovered(_ id: String) -> Alert {
        Alert(kind: .recovered, jobID: id, jobName: id, hostID: "local", reason: "why")
    }

    private func looked(alerts: [Alert]) -> WatchSession.Outcome {
        .looked(config: config(), reports: [], alerts: alerts, saveProblem: nil)
    }
}
