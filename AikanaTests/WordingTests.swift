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
}
