@testable import AjoissaCore
import XCTest

/// file-age, file-size and command. The run being judged was due at 2026-11-14 02:00, and it is now 03:00.
final class CheckRunnerTests: XCTestCase {
    private var host: FakeHost!
    private let reports = "/home/reports/*.md"

    override func setUp() {
        host = FakeHost()
    }

    // MARK: - file-age

    func testFileNewerThanTheExpectedRunPassesAndProvesTheRun() {
        host.put("/home/reports/old.md", modified: "2026-11-13 02:05")
        host.put("/home/reports/new.md", modified: "2026-11-14 02:05")

        XCTAssertEqual(run(.fileAge(path: reports, maxAge: nil)), CheckOutcome(
            result: .passed,
            provesRun: true,
            detail: "/home/reports/new.md was written at 2026-11-14 02:05"
        ))
    }

    func testFileWrittenJustBeforeTheExpectedRunStillCounts() {
        host.put("/home/reports/a.md", modified: "2026-11-14 01:59:30")
        XCTAssertEqual(run(.fileAge(path: reports, maxAge: nil)).result, .passed)

        host.put("/home/reports/a.md", modified: "2026-11-14 01:58:30")
        XCTAssertNotEqual(run(.fileAge(path: reports, maxAge: nil)).result, .passed)
    }

    func testNoFileNewerThanTheExpectedRunFails() {
        host.put("/home/reports/old.md", modified: "2026-11-13 02:05")

        XCTAssertEqual(run(.fileAge(path: reports, maxAge: nil)), CheckOutcome(
            result: .failed("no file matching /home/reports/*.md is newer than 2026-11-14 02:00; the newest was written at 2026-11-13 02:05")
        ))
    }

    func testNoMatchingFileFails() {
        host.put("/home/other/x.md", modified: "2026-11-14 02:05")

        XCTAssertEqual(run(.fileAge(path: reports, maxAge: nil)).result, .failed("no file matches /home/reports/*.md"))
    }

    func testFolderThatCannotBeReadIsNotAFailure() {
        host.makeUnreadable(reports)

        XCTAssertEqual(
            run(.fileAge(path: reports, maxAge: nil)).result,
            .couldNotRun("/home/reports/*.md could not be read: permission denied")
        )
    }

    func testMaxAgeIsCountedFromNowAndDoesNotProveTheRun() {
        host.put("/home/reports/a.md", modified: "2026-11-13 02:00")

        XCTAssertEqual(run(.fileAge(path: reports, maxAge: 26 * 3600)), CheckOutcome(
            result: .passed,
            provesRun: false,
            detail: "/home/reports/a.md was written at 2026-11-13 02:00"
        ))
        XCTAssertEqual(
            run(.fileAge(path: reports, maxAge: 24 * 3600)).result,
            .failed("no file matching /home/reports/*.md is less than 1d old; the newest was written at 2026-11-13 02:00")
        )
    }

    func testWithoutAnExpectedRunOnlyMaxAgeCanBeJudged() {
        host.put("/home/reports/a.md", modified: "2026-11-14 02:05")

        XCTAssertEqual(
            run(.fileAge(path: reports, maxAge: nil), since: nil).result,
            .couldNotRun("/home/reports/*.md has no expected run to be compared with; give the check a maxAge")
        )
        XCTAssertEqual(run(.fileAge(path: reports, maxAge: 3600), since: nil).result, .passed)
    }

    func testFileStampedInTheFutureIsNotTheNewest() {
        host.put("/home/reports/old.md", modified: "2026-11-13 02:05")
        host.put("/home/reports/future.md", modified: "2026-11-14 09:00")

        XCTAssertEqual(
            run(.fileAge(path: reports, maxAge: nil)).result,
            .failed("no file matching /home/reports/*.md is newer than 2026-11-14 02:00; the newest was written at 2026-11-13 02:05")
        )

        host.remove("/home/reports/old.md")
        XCTAssertEqual(run(.fileAge(path: reports, maxAge: nil)).result, .failed("every file matching /home/reports/*.md is stamped in the future"))
    }

    // MARK: - file-size

    func testNewestFileOfAtLeastTheSizePasses() {
        host.put("/backup/old.tar", modified: "2026-11-13 02:05", size: 10)
        host.put("/backup/new.tar", modified: "2026-11-14 02:05", size: 500_000_000)

        XCTAssertEqual(run(.fileSize(path: "/backup/*.tar", minBytes: 500_000_000)), CheckOutcome(
            result: .passed,
            provesRun: false,
            detail: "/backup/new.tar is 500 MB"
        ))
    }

    func testNewestFileThatIsTooSmallFailsEvenIfAnOlderOneIsLarge() {
        host.put("/backup/old.tar", modified: "2026-11-13 02:05", size: 900_000_000)
        host.put("/backup/new.tar", modified: "2026-11-14 02:05", size: 3200)

        XCTAssertEqual(
            run(.fileSize(path: "/backup/*.tar", minBytes: 500_000_000)).result,
            .failed("/backup/new.tar is 3.2 KB, less than the 500 MB it should be")
        )
    }

    func testFileSizeWithNoMatchFailsAndUnreadableIsNotAFailure() {
        XCTAssertEqual(run(.fileSize(path: "/backup/*.tar", minBytes: 1)).result, .failed("no file matches /backup/*.tar"))

        host.makeUnreadable("/backup/*.tar")
        XCTAssertEqual(
            run(.fileSize(path: "/backup/*.tar", minBytes: 1)).result,
            .couldNotRun("/backup/*.tar could not be read: permission denied")
        )
    }

    func testSizesAreWrittenAsInTheConfig() {
        let cases: [(Int64, String)] = [
            (0, "0 B"), (999, "999 B"), (1000, "1 KB"), (1500, "1.5 KB"), (19197, "19.2 KB"),
            (999_949, "999.9 KB"), (1_000_000, "1 MB"), (2_500_000_000, "2.5 GB"), (5_000_000_000_000, "5000 GB")
        ]

        for (count, expected) in cases {
            XCTAssertEqual(CheckPass.bytes(count), expected)
        }
    }

    // MARK: - command

    func testCommandThatExitsWithZeroPasses() {
        host.answerCommands(with: .success(CommandResult(exitCode: 0, output: "all good\n")))

        XCTAssertEqual(run(.command(arguments: ["/usr/bin/verify", "--quick", "a b"], timeout: 30)), CheckOutcome(
            result: .passed,
            provesRun: false,
            detail: "all good"
        ))
        XCTAssertEqual(host.commands, [["/usr/bin/verify", "--quick", "a b"]])
    }

    func testCommandThatExitsWithAnErrorFailsAndKeepsItsOutput() {
        host.answerCommands(with: .success(CommandResult(exitCode: 2, output: "checking\n", errorOutput: "3 files missing\n")))

        XCTAssertEqual(run(.command(arguments: ["/usr/bin/verify"], timeout: 30)), CheckOutcome(
            result: .failed("/usr/bin/verify exited with code 2"),
            detail: "checking\n3 files missing"
        ))
    }

    func testCommandThatDoesNotFinishIsNotAFailure() {
        host.answerCommands(with: .failure(.timedOut(after: 30)))

        XCTAssertEqual(
            run(.command(arguments: ["/usr/bin/verify"], timeout: 30)).result,
            .couldNotRun("/usr/bin/verify did not finish within 30s")
        )
    }

    func testCommandThatCannotBeStartedIsNotAFailure() {
        host.answerCommands(with: .failure(.notStarted(reason: "no such file")))

        XCTAssertEqual(
            run(.command(arguments: ["/usr/bin/verify"], timeout: 30)).result,
            .couldNotRun("/usr/bin/verify could not be started: no such file")
        )
    }

    func testLongCommandOutputIsCutShort() {
        host.answerCommands(with: .success(CommandResult(exitCode: 0, output: String(repeating: "x", count: 5000))))

        let detail = run(.command(arguments: ["/usr/bin/verify"], timeout: 30)).detail

        XCTAssertEqual(detail?.count, CheckRunner.detailLimit + 1)
        XCTAssertEqual(detail?.last, "…")
    }

    func testCommandWithNoOutputHasNoDetail() {
        XCTAssertNil(run(.command(arguments: ["/usr/bin/true"], timeout: 30)).detail)
    }

    // MARK: - Several checks

    func testOutcomesComeBackInTheOrderOfTheChecks() {
        host.put("/home/reports/a.md", modified: "2026-11-14 02:05", size: 10)
        let context = CheckContext(now: TestClock.date("2026-11-14 03:00"), since: TestClock.date("2026-11-14 02:00"), calendar: TestClock.utc)

        let outcomes = CheckRunner.run(
            [.fileSize(path: reports, minBytes: 1000), .fileAge(path: reports, maxAge: nil), .command(arguments: ["/usr/bin/true"], timeout: 30)],
            on: host,
            context: context,
            state: nil
        ).outcomes

        XCTAssertEqual(outcomes.map(\.result), [.failed("/home/reports/a.md is 10 B, less than the 1 KB it should be"), .passed, .passed])
    }

    // MARK: - Helpers

    private func run(_ check: Check, since: String? = "2026-11-14 02:00") -> CheckOutcome {
        let context = CheckContext(
            now: TestClock.date("2026-11-14 03:00"),
            since: since.map { TestClock.date($0) },
            calendar: TestClock.utc
        )
        return CheckRunner.run([check], on: host, context: context, state: nil).outcomes[0]
    }
}
