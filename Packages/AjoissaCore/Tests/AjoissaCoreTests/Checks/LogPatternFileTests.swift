import AjoissaCore
import XCTest

/// log-pattern on logs that are emptied, rewritten or rotated, and on text that is not clean.
final class LogPatternFileTests: LogCheckTestCase {
    // MARK: - Logs that do not simply grow

    /// The job empties its log at each run and happens to write more than before. The log is longer than
    /// where the last run ended, but it is not the same text.
    func testLogRewrittenInPlaceAndLongerThanBeforeIsReadFromItsStart() {
        let check = Check.logPattern(path: log, contains: "backup done", notContains: nil)
        host.put(log, modified: "2026-11-13 02:05", contents: "starting\nfailed early\n")
        look(at: "2026-11-14 01:59", since: run1, check)

        host.put(log, modified: "2026-11-14 02:03", contents: "starting\nbackup done\nand a longer tail than before\n")

        XCTAssertEqual(look(at: "2026-11-14 02:10", since: run2, check).result, .passed)
        XCTAssertEqual(state?.logBaselines[log]?.position.offset, 0)
    }

    func testLogReplacedByANewFileIsReadFromItsStart() {
        let check = Check.logPattern(path: log, contains: nil, notContains: "ERROR")
        host.put(log, modified: "2026-11-13 02:05", contents: "short\n")
        look(at: "2026-11-14 01:59", since: run1, check)

        // Rotated: the old log was moved away and a new file took its name.
        host.put(log, modified: "2026-11-14 02:03", contents: "ERROR at the very start, before where the old log ended\n", replaced: true)

        XCTAssertEqual(look(at: "2026-11-14 02:10", since: run2, check).result, .failed("the log contains \"ERROR\""))
    }

    /// A script that writes its whole log anew each night, and the same lines every time. The log is as long
    /// as it was and ends as it did, but it was written since.
    func testLogRewrittenWithTheSameTextIsReadFromItsStart() {
        let check = Check.logPattern(path: log, contains: "Backup done", notContains: nil)
        host.put(log, modified: "2026-11-13 02:01", contents: "Backup done\n")
        look(at: "2026-11-14 01:59", since: run1, check)

        host.put(log, modified: "2026-11-14 02:01", contents: "Backup done\n")

        XCTAssertEqual(look(at: "2026-11-14 02:10", since: run2, check).result, .passed)
        XCTAssertEqual(look(at: "2026-11-14 02:11", since: run2, check).result, .passed)
    }

    func testLogNotWrittenSinceHasNothingNewHoweverOftenItIsLookedAt() {
        let check = Check.logPattern(path: log, contains: "Backup done", notContains: nil)
        host.put(log, modified: "2026-11-13 02:01", contents: "Backup done\n")
        look(at: "2026-11-14 01:59", since: run1, check)

        for moment in ["2026-11-14 02:10", "2026-11-14 02:11", "2026-11-14 09:00"] {
            XCTAssertEqual(
                look(at: moment, since: run2, check).result,
                .failed("the log does not contain \"Backup done\" since 2026-11-14 02:00"),
                moment
            )
        }
    }

    /// The new file begins with the very bytes the old one had, so only its identity shows it is another file.
    func testReplacedLogThatBeginsLikeTheOldOneIsStillReadFromItsStart() {
        let check = Check.logPattern(path: log, contains: "start", notContains: nil)
        host.put(log, modified: "2026-11-13 02:01", contents: "start\n")
        look(at: "2026-11-14 01:59", since: run1, check)

        host.put(log, modified: "2026-11-14 02:01", contents: "start\nand more\n", replaced: true)

        XCTAssertEqual(look(at: "2026-11-14 02:10", since: run2, check).result, .passed)
    }

    func testLogThatOnlyGrewIsReadFromWhereItEnded() {
        let check = Check.logPattern(path: log, contains: nil, notContains: "ERROR")
        host.put(log, modified: "2026-11-13 02:05", contents: "ERROR from the last run\n")
        look(at: "2026-11-14 01:59", since: run1, check)
        host.put(log, modified: "2026-11-14 02:03", contents: "ERROR from the last run\nall fine\n")

        XCTAssertEqual(look(at: "2026-11-14 02:10", since: run2, check).result, .passed)
        XCTAssertEqual(state?.logBaselines[log]?.position.offset, 24)
    }

    // MARK: - Text

    func testBytesThatAreNotTextDoNotHideLettersOutsideASCII() {
        let check = Check.logPattern(path: log, contains: nil, notContains: "yhteys hylätty")
        host.put(log, modified: "2026-11-13 02:05", contents: "")
        look(at: "2026-11-14 01:59", since: run1, check)
        var data = Data([0xFF, 0xFE, 0x0A])
        data.append(Data("virhe: yhteys hylätty\n".utf8))
        host.put(log, modified: "2026-11-14 02:03", data: data)

        XCTAssertEqual(look(at: "2026-11-14 02:10", since: run2, check).result, .failed("the log contains \"yhteys hylätty\""))
    }

    func testEndOfOneLogAndStartOfTheNextDoNotFormAMatch() {
        let check = Check.logPattern(path: nil, contains: nil, notContains: "ERROR")
        let logs = ["/tmp/job.out", "/tmp/job.err"]
        host.put("/tmp/job.out", modified: "2026-11-13 02:05", contents: "")
        host.put("/tmp/job.err", modified: "2026-11-13 02:05", contents: "")
        look(at: "2026-11-14 01:59", since: run1, check, defaultLogPaths: logs)

        host.put("/tmp/job.out", modified: "2026-11-14 02:03", contents: "transferred with ERR")
        host.put("/tmp/job.err", modified: "2026-11-14 02:03", contents: "OR nothing at all\n")

        XCTAssertEqual(look(at: "2026-11-14 02:10", since: run2, check, defaultLogPaths: logs).result, .passed)
    }

    /// One log cannot be judged yet. An error in the other one, which can, must still be found.
    func testLogThatCannotBeJudgedYetDoesNotHideAnErrorInAnother() {
        let check = Check.logPattern(path: nil, contains: nil, notContains: "ERROR")
        host.put("/tmp/job.err", modified: "2026-11-13 02:05", contents: "")
        look(at: "2026-11-14 01:59", since: run1, .logPattern(path: "/tmp/job.err", contains: nil, notContains: "ERROR"))

        host.put("/tmp/job.out", modified: "2026-11-14 02:03", contents: "first seen after the run wrote to it\n")
        host.put("/tmp/job.err", modified: "2026-11-14 02:03", contents: "ERROR: disk full\n")

        XCTAssertEqual(
            look(at: "2026-11-14 02:10", since: run2, check, defaultLogPaths: ["/tmp/job.out", "/tmp/job.err"]).result,
            .failed("the log contains \"ERROR\"")
        )
    }
}
