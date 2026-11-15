@testable import Aikana
import AikanaCore
import XCTest

@MainActor
final class WordingTests: WatchModelTestCase {
    func testOnlyALeadingTildeSlashIsTheHomeFolder() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        XCTAssertEqual(LogSection.fileURL(of: "~/Library/Logs/a b.log").path, "\(home)/Library/Logs/a b.log")
        XCTAssertEqual(LogSection.fileURL(of: "/var/log/a.log").path, "/var/log/a.log")
        XCTAssertEqual(LogSection.fileURL(of: "/var/~/a.log").path, "/var/~/a.log")
    }

    func testAMomentAWeekAwayHasItsDate() {
        let calendar = Calendar.current
        let now = calendar.date(from: DateComponents(year: 2026, month: 11, day: 9, hour: 23, minute: 30)) ?? .distantPast
        let inSix = calendar.date(from: DateComponents(year: 2026, month: 11, day: 15, hour: 0, minute: 15)) ?? .distantPast
        let inSeven = calendar.date(from: DateComponents(year: 2026, month: 11, day: 16, hour: 0, minute: 15)) ?? .distantPast
        XCTAssertEqual(Wording.moment(inSix, now: now), inSix.formatted(.dateTime.weekday(.abbreviated).hour().minute()))
        XCTAssertEqual(Wording.moment(inSeven, now: now), inSeven.formatted(.dateTime.day().month(.abbreviated).hour().minute()))
    }

    func testRecentMoments() {
        let calendar = Calendar.current
        let now = calendar.date(from: DateComponents(year: 2026, month: 11, day: 15, hour: 9)) ?? .distantPast
        XCTAssertEqual(Wording.recent(now.addingTimeInterval(-30), now: now), "just now")
        XCTAssertEqual(Wording.recent(now.addingTimeInterval(-120), now: now), "2 min ago")
        let early = now.addingTimeInterval(-5 * 3600)
        XCTAssertEqual(Wording.recent(early, now: now), "today \(Wording.moment(early, now: now))")
        let saturday = now.addingTimeInterval(-24 * 3600)
        XCTAssertEqual(Wording.recent(saturday, now: now), Wording.moment(saturday, now: now))
    }

    func testIntervals() {
        XCTAssertEqual(Wording.interval(30), "30 s")
        XCTAssertEqual(Wording.interval(15 * 60), "15 min")
        XCTAssertEqual(Wording.interval(2 * 3600), "2 h")
        XCTAssertEqual(Wording.interval(5400), "1 h 30 min")
        XCTAssertEqual(Wording.interval(86_400), "1 d")
        XCTAssertEqual(Wording.interval(90_000), "25 h")
    }

    func testRowDetails() {
        let calendar = Calendar.current
        let now = calendar.date(from: DateComponents(year: 2026, month: 11, day: 15, hour: 9)) ?? .distantPast
        let lastRun = calendar.date(from: DateComponents(year: 2026, month: 11, day: 14, hour: 2, minute: 6)) ?? now
        let due = calendar.date(from: DateComponents(year: 2026, month: 11, day: 15, hour: 2)) ?? now
        let last = Wording.moment(lastRun, now: now)
        let dueText = Wording.moment(due, now: now)

        var report = report("a", .ok)
        report.reason = "its checks pass"
        XCTAssertEqual(JobRowView.detail(of: PanelRow(report: report, hostName: nil), now: now), "Its checks pass")
        report.source = "launchd com.example.a"
        XCTAssertEqual(JobRowView.detail(of: PanelRow(report: report, hostName: nil), now: now), "No run seen yet")
        report.lastRun = now.addingTimeInterval(-10)
        XCTAssertEqual(JobRowView.detail(of: PanelRow(report: report, hostName: "studio"), now: now), "Ran just now · studio")

        report.state = .missed
        report.lastRun = lastRun
        report.expectedRun = due
        XCTAssertEqual(JobRowView.detail(of: PanelRow(report: report, hostName: nil), now: now), "Due today \(dueText) · last ran \(last)")

        report.state = .failed
        report.reason = "its last run exited with code 1"
        XCTAssertEqual(JobRowView.detail(of: PanelRow(report: report, hostName: nil), now: now), "\(last) · exited with code 1")

        report.state = .unknown
        report.reason = "not judged yet: of the schedulers, only launchd is read so far"
        XCTAssertEqual(JobRowView.detail(of: PanelRow(report: report, hostName: nil), now: now), "Not judged yet: of the schedulers, only launchd is read so far")
    }

    func testRowTrailing() {
        let calendar = Calendar.current
        let now = calendar.date(from: DateComponents(year: 2026, month: 11, day: 15, hour: 9)) ?? .distantPast
        var report = report("a", .ok)
        XCTAssertEqual(JobRowView.trailing(of: report, now: now).text, "")
        report.nextRun = calendar.date(from: DateComponents(year: 2026, month: 11, day: 16, hour: 3))
        XCTAssertEqual(JobRowView.trailing(of: report, now: now).text, Wording.moment(report.nextRun ?? now, now: now))
        report.repeatInterval = 15 * 60
        XCTAssertEqual(JobRowView.trailing(of: report, now: now).text, "Every 15 min")
        XCTAssertFalse(JobRowView.trailing(of: report, now: now).isState)
        report.state = .missed
        XCTAssertEqual(JobRowView.trailing(of: report, now: now).text, "Missed")
        XCTAssertTrue(JobRowView.trailing(of: report, now: now).isState)
    }

    func testSectionsNameTheMachineOnlyWhenThereAreSeveral() throws {
        let config = try ConfigLoader.load(Data("""
            { version: 1, hosts: [ { id: 'studio', ssh: 'studio' } ], jobs: [
              { id: 'x', source: { launchd: 'com.example.x' } },
              { id: 'y', host: 'studio', source: { launchd: 'com.example.y' } } ] }
            """.utf8))
        var other = report("b", .unknown)
        other.job = Job(id: "b", name: "b", hostID: "studio", source: nil, schedule: nil, grace: Job.defaultGrace, notify: true, checks: [])
        let one = PanelSection.sections(of: HostGroup.groups(of: [report("a", .ok)], hosts: config.hosts))
        XCTAssertEqual(one.first?.rows.first?.hostName, nil)
        let two = PanelSection.sections(of: HostGroup.groups(of: [report("a", .ok), other], hosts: config.hosts))
        XCTAssertEqual(two.map(\.kind), [.fine, .unknown])
        XCTAssertEqual(two.last?.rows.first?.hostName, "studio")
    }

    func testSentence() {
        XCTAssertEqual(Wording.sentence("its last run exited with code 3"), "Its last run exited with code 3")
        XCTAssertEqual(Wording.sentence(""), "")
    }
}
