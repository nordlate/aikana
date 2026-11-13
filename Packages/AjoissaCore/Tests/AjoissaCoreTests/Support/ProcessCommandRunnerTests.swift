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

    func testProgramThatRunsTooLongIsStopped() {
        let started = Date()

        XCTAssertThrowsError(try runner.run("/bin/sleep", arguments: ["30"], timeout: 0.3)) { error in
            XCTAssertEqual(error as? CommandError, .timedOut(after: 0.3))
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 5)
    }
}
