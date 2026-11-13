import AjoissaCore
import XCTest

final class ProcessCommandRunnerTests: XCTestCase {
    private let runner = ProcessCommandRunner()

    func testOutputAndExitCode() throws {
        let result = try runner.run("/bin/echo", arguments: ["one", "two  three"], timeout: 10)

        XCTAssertEqual(result, CommandResult(exitCode: 0, output: "one two  three\n", errorOutput: ""))
    }

    func testNonZeroExitAndErrorOutputAreReturnedNotThrown() throws {
        let result = try runner.run("/bin/sh", arguments: ["-c", "echo problem >&2; exit 7"], timeout: 10)

        XCTAssertEqual(result, CommandResult(exitCode: 7, output: "", errorOutput: "problem\n"))
    }

    func testArgumentsAreNotReadByAShell() throws {
        let result = try runner.run("/bin/echo", arguments: ["$HOME; echo injected", "`id`"], timeout: 10)

        XCTAssertEqual(result.output, "$HOME; echo injected `id`\n")
    }

    func testOutputLargerThanAPipeDoesNotHang() throws {
        let result = try runner.run("/bin/sh", arguments: ["-c", "head -c 300000 /dev/zero | tr '\\0' 'a'"], timeout: 10)

        XCTAssertEqual(result.output.count, 300_000)
    }

    func testProgramThatDoesNotExist() {
        XCTAssertThrowsError(try runner.run("/nonexistent/program", arguments: [], timeout: 10)) { error in
            guard case .notStarted = error as? CommandError else {
                return XCTFail("Expected notStarted, got \(error)")
            }
        }
    }

    func testProgramThatRunsTooLongIsStopped() throws {
        let pidFile = FileManager.default.temporaryDirectory.appending(path: "ajoissa-pid-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: pidFile) }
        let started = Date()

        // "exec" makes sleep take over the shell's process, so the recorded id is the one that must be stopped.
        XCTAssertThrowsError(try runner.run("/bin/sh", arguments: ["-c", "echo $$ > '\(pidFile.path)'; exec sleep 30"], timeout: 0.5)) { error in
            XCTAssertEqual(error as? CommandError, .timedOut(after: 0.5))
        }

        XCTAssertLessThan(Date().timeIntervalSince(started), 5)
        let recorded = try String(contentsOf: pidFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        let pid = try XCTUnwrap(Int32(recorded))
        // Signal 0 only asks whether the process exists.
        XCTAssertEqual(kill(pid, 0), -1, "the process is still there")
    }

    /// A program can exit while something it started keeps its output open. What the program wrote must still
    /// be returned, and the call must not wait for the leftover process.
    func testOutputIsKeptWhenTheProgramLeavesSomethingRunning() throws {
        let started = Date()

        let result = try runner.run("/bin/sh", arguments: ["-c", "echo hi; echo oops >&2; sleep 6 &"], timeout: 10)

        XCTAssertEqual(result, CommandResult(exitCode: 0, output: "hi\n", errorOutput: "oops\n"))
        XCTAssertLessThan(Date().timeIntervalSince(started), 5)
    }
}
