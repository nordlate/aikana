import AjoissaCore
import XCTest

final class LaunchdEvidenceTests: XCTestCase {
    private let definition = LaunchdJobDefinition(
        label: "com.example.job",
        calendarIntervals: [LaunchdCalendarInterval(minute: 0, hour: 2)],
        standardOutPath: "/tmp/plist.log",
        standardErrorPath: "/tmp/shared.err"
    )
    private let written = Date(timeIntervalSince1970: 1_800_000_000)

    func testLoadedJob() {
        let state = LaunchdServiceState(runState: .notRunning, runs: 3, lastExit: .code(3))
        let observation = LaunchdObservation(label: "com.example.job", status: .loaded(state), definition: definition)

        XCTAssertEqual(SourceEvidence(launchd: observation, logModified: written), SourceEvidence(
            availability: .available,
            timetable: Timetable(calendarRules: [.init(minute: 0, hour: 2)]),
            isRunning: false,
            runCount: 3,
            lastExit: .code(3),
            logModified: written
        ))
    }

    func testRunningJobAndEveryKindOfExit() {
        let running = LaunchdServiceState(runState: .running, processID: 42, runs: 1, lastExit: .neverExited)
        let evidence = SourceEvidence(launchd: LaunchdObservation(label: "x", status: .loaded(running)))
        XCTAssertEqual(evidence.isRunning, true)
        XCTAssertEqual(evidence.lastExit, .neverExited)

        let signalled = LaunchdServiceState(lastExit: .signal("Terminated: 15"))
        XCTAssertEqual(SourceEvidence(launchd: LaunchdObservation(label: "x", status: .loaded(signalled))).lastExit, .signal("Terminated: 15"))
    }

    func testStateThatLaunchdDidNotReportStaysUnknown() {
        let evidence = SourceEvidence(launchd: LaunchdObservation(label: "x", status: .loaded(LaunchdServiceState())))

        XCTAssertEqual(evidence.availability, .available)
        XCTAssertNil(evidence.isRunning)
        XCTAssertNil(evidence.runCount)
        XCTAssertNil(evidence.lastExit)
        // No plist was read, so the timetable is unknown, not empty.
        XCTAssertNil(evidence.timetable)
    }

    func testJobWithoutATimetableHasAnEmptyOneNotAnUnknownOne() {
        let observation = LaunchdObservation(
            label: "x",
            status: .loaded(LaunchdServiceState()),
            definition: LaunchdJobDefinition(label: "x")
        )

        XCTAssertEqual(SourceEvidence(launchd: observation).timetable, Timetable())
    }

    func testNotLoadedMissingAndUnknown() {
        let notLoaded = LaunchdObservation(label: "x", status: .notLoaded, definition: definition)
        XCTAssertEqual(SourceEvidence(launchd: notLoaded).availability, .notLoaded)
        XCTAssertEqual(SourceEvidence(launchd: notLoaded).timetable, Timetable(calendarRules: [.init(minute: 0, hour: 2)]))

        XCTAssertEqual(SourceEvidence(launchd: LaunchdObservation(label: "x", status: .plistMissing)).availability, .missing)

        let unknown = LaunchdObservation(label: "x", status: .unknown(reason: "launchctl did not answer in time"))
        XCTAssertEqual(SourceEvidence(launchd: unknown).availability, .unknown(reason: "launchctl did not answer in time"))
    }

    func testLogPathsPreferWhatLaunchdUsesAndListEachOnce() {
        let state = LaunchdServiceState(standardOutPath: "/tmp/loaded.log", standardErrorPath: "/tmp/shared.err")
        let loaded = LaunchdObservation(label: "x", status: .loaded(state), definition: definition)
        XCTAssertEqual(loaded.logPaths, ["/tmp/loaded.log", "/tmp/shared.err", "/tmp/plist.log"])

        XCTAssertEqual(LaunchdObservation(label: "x", status: .notLoaded, definition: definition).logPaths, ["/tmp/plist.log", "/tmp/shared.err"])
        XCTAssertEqual(LaunchdObservation(label: "x", status: .plistMissing).logPaths, [])
    }

    func testAwakeSinceIsInThePast() throws {
        let awakeSince = try XCTUnwrap(SystemUptime.awakeSince())

        XCTAssertLessThan(awakeSince, Date())
        XCTAssertGreaterThan(awakeSince, Date(timeIntervalSince1970: 1_000_000_000))
    }
}
