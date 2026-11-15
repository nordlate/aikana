import AikanaCore
import XCTest

final class LaunchdObservationDescriptionTests: XCTestCase {
    func testStatusDescriptions() {
        let cases: [(LaunchdObservation.Status, String)] = [
            (.loaded(LaunchdServiceState(runState: .notRunning, runs: 3, lastExit: .code(0))), "loaded, not running, 3 runs, last exit code 0"),
            (.loaded(LaunchdServiceState(runState: .running, processID: 42, runs: 1, lastExit: .neverExited)), "loaded, running as process 42, 1 run, never exited"),
            (.loaded(LaunchdServiceState(runState: .running)), "loaded, running"),
            (.loaded(LaunchdServiceState(runState: .notRunning, runs: 0, lastExit: .signal("Terminated: 15"))), "loaded, not running, 0 runs, last run ended by signal Terminated: 15"),
            (.loaded(LaunchdServiceState(runState: .other("spawn scheduled"))), "loaded, spawn scheduled"),
            (.loaded(LaunchdServiceState()), "loaded"),
            (.notLoaded, "not loaded: the plist exists but launchd has not loaded it, so the job will not run"),
            (.plistMissing, "not found: there is no plist with this label and launchd does not know it"),
            (.unknown(reason: "launchctl did not answer in time"), "unknown: launchctl did not answer in time")
        ]

        for (status, expected) in cases {
            XCTAssertEqual(LaunchdObservation(label: "com.example.job", status: status).statusDescription, expected)
        }
    }

    func testStatusParts() {
        let cases: [(LaunchdObservation.Status, [StatusPart])] = [
            (.loaded(LaunchdServiceState(runState: .notRunning, runs: 41, lastExit: .code(1))),
             [StatusPart("loaded, idle"), StatusPart("last exit 1", isProblem: true), StatusPart("41 runs")]),
            (.loaded(LaunchdServiceState(runState: .notRunning, runs: 1, lastExit: .code(0))),
             [StatusPart("loaded, idle"), StatusPart("last exit 0"), StatusPart("1 run")]),
            (.loaded(LaunchdServiceState(runState: .running, processID: 42, lastExit: .neverExited)),
             [StatusPart("loaded, running as process 42"), StatusPart("never exited")]),
            (.loaded(LaunchdServiceState(lastExit: .signal("Killed: 9"))),
             [StatusPart("loaded"), StatusPart("ended by signal Killed: 9", isProblem: true)]),
            (.notLoaded, [StatusPart("not loaded", isProblem: true)]),
            (.plistMissing, [StatusPart("not found", isProblem: true)]),
            (.unknown(reason: "launchctl did not answer in time"), [StatusPart("unknown: launchctl did not answer in time")])
        ]

        for (status, expected) in cases {
            XCTAssertEqual(LaunchdObservation(label: "com.example.job", status: status).statusParts, expected)
        }
    }

    func testScheduleDescriptionForAJobWithoutATimetable() {
        let observation = LaunchdObservation(
            label: "com.example.job",
            status: .notLoaded,
            definition: LaunchdJobDefinition(label: "com.example.job")
        )

        XCTAssertEqual(observation.scheduleDescription, "none: the job does not run on a timetable")
    }
}
