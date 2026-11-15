@testable import Aikana
import AikanaCore
import XCTest

@MainActor
final class DetailWordingTests: WatchModelTestCase {
    private let calendar = Calendar.current
    private var now: Date { date(15, 9) }

    private func date(_ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 11, day: day, hour: hour, minute: minute)) ?? .distantPast
    }

    private func time(_ date: Date) -> String {
        date.formatted(.dateTime.hour().minute())
    }

    func testHeadlines() {
        var report = report("a", .ok)
        XCTAssertEqual(DetailWording.headline(of: report, now: now), "OK")
        report.lastRun = date(15, 4, 5)
        XCTAssertEqual(DetailWording.headline(of: report, now: now), "Ran today at \(time(date(15, 4, 5)))")
        report.expectedRun = date(15, 4)
        report.runs = [RunMark(date: date(15, 4), outcome: .ok)]
        XCTAssertEqual(DetailWording.headline(of: report, now: now), "Ran today at \(time(date(15, 4, 5))), on schedule")

        report.state = .failed
        report.runs = [RunMark(date: date(15, 3), outcome: .failed)]
        XCTAssertEqual(DetailWording.headline(of: report, now: now), "Failed today at \(time(date(15, 3)))")
        report.runs = []
        XCTAssertEqual(DetailWording.headline(of: report, now: now), "Failed")

        report.state = .missed
        report.expectedRun = date(14, 2)
        let saturday = date(14, 2).formatted(.dateTime.weekday(.abbreviated))
        XCTAssertEqual(DetailWording.headline(of: report, now: now), "Missed the run due \(saturday) at \(time(date(14, 2)))")
    }

    func testSublines() {
        var report = report("a", .failed)
        report.reason = "its last run exited with code 1"
        XCTAssertEqual(DetailWording.subline(of: report, now: now), "Exited with code 1")
        report.checks = [
            JobReport.CheckReport(label: "file-age /a", kind: "file-age", target: "/a", outcome: CheckOutcome(result: .failed("too old"))),
            JobReport.CheckReport(label: "command /b", kind: "command", target: "/b", outcome: CheckOutcome(result: .passed))
        ]
        XCTAssertEqual(DetailWording.subline(of: report, now: now), "Exited with code 1 · 1 check failed")

        report.state = .ok
        XCTAssertNil(DetailWording.subline(of: report, now: now))

        report.state = .missed
        XCTAssertEqual(DetailWording.subline(of: report, now: now), "No run seen yet")
        report.lastRun = now.addingTimeInterval(-120)
        XCTAssertEqual(DetailWording.subline(of: report, now: now), "Last ran 2 min ago")
    }

    func testRuns() {
        var report = report("a", .ok)
        report.runs = (0..<20).map { RunMark(date: date(1, 2).addingTimeInterval(Double($0) * 86_400), outcome: .ok) }
        let shown = DetailWording.shownRuns(of: report)
        XCTAssertEqual(shown.count, DetailWording.runLimit)
        XCTAssertEqual(shown.last, report.runs.last)
        XCTAssertEqual(DetailWording.runsCaption(shown), "Last 14 runs on schedule")
        XCTAssertEqual(DetailWording.runsCaption([RunMark(date: now, outcome: .ok)]), "Last run on schedule")
        XCTAssertEqual(DetailWording.runsCaption(shown + [RunMark(date: now, outcome: .missed)]), "Last 15 runs")
    }

    func testSmallWords() {
        XCTAssertEqual(DetailWording.shortPath("/Volumes/Backup/backups/latest.manifest"), "…/backups/latest.manifest")
        XCTAssertEqual(DetailWording.shortPath("/var/run.log"), "/var/run.log")
        XCTAssertEqual(DetailWording.shortPath("the job's log"), "the job's log")
        XCTAssertEqual(DetailWording.source("launchd com.example.backup").name, "launchd job")
        XCTAssertEqual(DetailWording.source("launchd com.example.backup").value, "com.example.backup")
        XCTAssertEqual(DetailWording.passedCaption(count: 2), "2 checks passed")
        XCTAssertEqual(DetailWording.passedCaption(count: 1), "1 check passed")
        XCTAssertEqual(DetailWording.checkMessage(.failed("the newest file is 2 days old")), "The newest file is 2 days old")
        XCTAssertNil(DetailWording.checkMessage(.passed))
        XCTAssertEqual(DetailWording.checkResult(.couldNotRun("no such host")), "Could not run")
        XCTAssertEqual(DetailWording.linesCaption(count: 5), "Latest 5 lines")
    }

    func testLogLines() {
        let text = (1...8).map { "line \($0)" }.joined(separator: "\n") + "\n\n  \n"
        XCTAssertEqual(LogSection.lastLines(of: text), ["line 4", "line 5", "line 6", "line 7", "line 8"])
        XCTAssertEqual(LogSection.lastLines(of: ""), [])

        XCTAssertNotNil("Sat 03:02:14 backup finished".firstMatch(of: LogSection.stampPattern))
        XCTAssertNotNil("2026-11-15 03:00:01 backup started".firstMatch(of: LogSection.stampPattern))
        XCTAssertNotNil("[2026-11-15T03:00:01] started".firstMatch(of: LogSection.stampPattern))
        XCTAssertNil("Step 1 took 12:30 minutes".firstMatch(of: LogSection.stampPattern))
        XCTAssertNil("nightly help-next next".firstMatch(of: LogSection.stampPattern))

        XCTAssertTrue(LogSection.looksLikeError("Sun 03:00:41 error: destination volume is not mounted"))
        XCTAssertFalse(LogSection.looksLikeError("Sun 03:00:41 exiting with status 1"))
    }
}
