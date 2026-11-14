@testable import AikanaCore
import XCTest

final class LaunchctlPrintParserTests: XCTestCase {
    // MARK: - Real output

    func testRunningAgent() {
        XCTAssertEqual(LaunchctlPrintParser.parse(LaunchdFixture.agentRunning.text), LaunchdServiceState(
            runState: .running,
            processID: 12859,
            runs: 1,
            lastExit: .neverExited,
            plistPath: "/Users/example/Library/LaunchAgents/com.example.running.plist",
            standardOutPath: "/tmp/com.example.running.log",
            standardErrorPath: "/tmp/com.example.running.err"
        ))
    }

    func testAgentThatExitedWithACode() {
        let state = LaunchctlPrintParser.parse(LaunchdFixture.agentExit3.text)

        XCTAssertEqual(state?.runState, .notRunning)
        XCTAssertNil(state?.processID)
        XCTAssertEqual(state?.runs, 1)
        XCTAssertEqual(state?.lastExit, .code(3))
    }

    func testAgentEndedByASignal() {
        let state = LaunchctlPrintParser.parse(LaunchdFixture.agentSignal.text)

        XCTAssertEqual(state?.runState, .notRunning)
        XCTAssertEqual(state?.lastExit, .signal("Terminated: 15"))
    }

    func testAgentThatHasNeverRun() {
        let state = LaunchctlPrintParser.parse(LaunchdFixture.agentNeverRun.text)

        XCTAssertEqual(state?.runState, .notRunning)
        XCTAssertEqual(state?.runs, 0)
        XCTAssertEqual(state?.lastExit, .neverExited)
    }

    func testRunningDaemon() {
        XCTAssertEqual(LaunchctlPrintParser.parse(LaunchdFixture.daemonRunning.text), LaunchdServiceState(
            runState: .running,
            processID: 838,
            runs: 1,
            lastExit: .neverExited,
            plistPath: "/Library/LaunchDaemons/com.example.updater.plist",
            standardOutPath: nil,
            standardErrorPath: "/tmp/example.updater.log"
        ))
    }

    /// The job's arguments are printed in a nested block. One of them is the text "state = not running" in the
    /// first fixture and "pid = 1" in the second; neither may be taken for the job's own state.
    func testArgumentsThatLookLikeSettingsAreIgnored() {
        let exited = LaunchctlPrintParser.parse(LaunchdFixture.agentArgumentLooksLikeAKey.text)
        XCTAssertEqual(exited?.runState, .notRunning)
        XCTAssertEqual(exited?.lastExit, .code(1))
        XCTAssertNil(exited?.processID)

        XCTAssertTrue(LaunchdFixture.agentRunning.text.contains("\t\tpid = 1\n"))
        XCTAssertEqual(LaunchctlPrintParser.parse(LaunchdFixture.agentRunning.text)?.processID, 12859)
    }

    // MARK: - Made-up output

    func testNestedBlocksAreSkipped() {
        let state = LaunchctlPrintParser.parse("""
            gui/501/com.example.job = {
            \tstate = not running
            \targuments = {
            \t\t/bin/sh
            \t\truns = 99
            \t}
            \tresource coalition = {
            \t\tstate = active
            \t}
            \tevent triggers = {
            \t\tcom.example.job.1 => {
            \t\t\tstate = running
            \t\t}
            \t}
            \truns = 2
            \tlast exit code = 0
            }
            """)

        XCTAssertEqual(state, LaunchdServiceState(runState: .notRunning, runs: 2, lastExit: .code(0)))
    }

    func testExitCodeWithAName() {
        let state = LaunchctlPrintParser.parse("system/com.example.job = {\n\tlast exit code = 78: EX_CONFIG\n}\n")

        XCTAssertEqual(state?.lastExit, .code(78))
    }

    func testUnknownValuesAreKeptOrLeftOut() {
        let state = LaunchctlPrintParser.parse("""
            gui/501/com.example.job = {
            \tstate = spawn scheduled
            \truns = many
            \tpid = none
            \tlast exit code = (unknown)
            \tsomething new = 1
            }
            """)

        XCTAssertEqual(state, LaunchdServiceState(runState: .other("spawn scheduled")))
    }

    func testServiceWithNothingRecognisedIsStillAService() {
        XCTAssertEqual(LaunchctlPrintParser.parse("gui/501/com.example.job = {\n}\n"), LaunchdServiceState())
    }

    func testTextThatIsNotAServiceDescription() {
        XCTAssertNil(LaunchctlPrintParser.parse(""))
        XCTAssertNil(LaunchctlPrintParser.parse("Bad request.\nCould not find service \"x\" in domain for system\n"))
        XCTAssertNil(LaunchctlPrintParser.parse("\tstate = running\n"))
        XCTAssertNil(LaunchctlPrintParser.parse("Usage: launchctl print <service-target>\n"))
    }
}
