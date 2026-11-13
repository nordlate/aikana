import AjoissaCore
import XCTest

final class LaunchdCollectorTests: XCTestCase {
    private var root: URL!
    private var agents: URL!
    private var daemons: URL!
    private var runner: FakeCommandRunner!
    private var collector: LaunchdCollector!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appending(path: "ajoissa-tests-\(UUID().uuidString)")
        agents = root.appending(path: "Home/Library/LaunchAgents")
        daemons = root.appending(path: "Library/LaunchDaemons")
        try FileManager.default.createDirectory(at: agents, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: daemons, withIntermediateDirectories: true)
        runner = FakeCommandRunner()
        collector = LaunchdCollector(runner: runner, locations: [
            LaunchdSearchLocation(directory: agents, domain: .user(id: 501)),
            LaunchdSearchLocation(directory: daemons, domain: .system)
        ])
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: root)
    }

    // MARK: - The three states

    func testLoadedAgent() throws {
        let plist = try write(label: "com.example.exit-3", in: agents, extra: ["StartInterval": 86400])
        runner.answer("gui/501/com.example.exit-3", output: LaunchdFixture.agentExit3.text)

        let observation = collector.observe(label: "com.example.exit-3")

        guard case let .loaded(state) = observation.status else {
            return XCTFail("Expected loaded, got \(observation.status)")
        }
        XCTAssertEqual(state.lastExit, .code(3))
        XCTAssertEqual(observation.domain, .user(id: 501))
        XCTAssertEqual(observation.plistPath, plist.path)
        XCTAssertEqual(observation.definition?.startInterval, 86400)
        XCTAssertNil(observation.definitionProblem)
        XCTAssertEqual(runner.calls, [["/bin/launchctl", "print", "gui/501/com.example.exit-3"]])
    }

    func testPlistThatLaunchdHasNotLoaded() throws {
        let plist = try write(label: "com.example.job", in: agents, extra: ["StartCalendarInterval": ["Hour": 2, "Minute": 0]])

        let observation = collector.observe(label: "com.example.job")

        XCTAssertEqual(observation.status, .notLoaded)
        XCTAssertEqual(observation.plistPath, plist.path)
        XCTAssertEqual(observation.definition?.scheduleDescription, "daily at 02:00")
        XCTAssertEqual(runner.calls, [["/bin/launchctl", "print", "gui/501/com.example.job"]])
    }

    func testNoPlistAndNotLoadedAnywhere() {
        let observation = collector.observe(label: "com.example.job")

        XCTAssertEqual(observation, LaunchdObservation(label: "com.example.job", status: .plistMissing))
        XCTAssertEqual(runner.calls, [
            ["/bin/launchctl", "print", "gui/501/com.example.job"],
            ["/bin/launchctl", "print", "system/com.example.job"]
        ])
    }

    // MARK: - Where the plist is

    func testDaemonIsAskedAboutInTheSystemDomain() throws {
        try write(label: "com.example.updater", in: daemons)
        runner.answer("system/com.example.updater", output: LaunchdFixture.daemonRunning.text)

        let observation = collector.observe(label: "com.example.updater")

        guard case let .loaded(state) = observation.status else {
            return XCTFail("Expected loaded, got \(observation.status)")
        }
        XCTAssertEqual(state.runState, .running)
        XCTAssertEqual(observation.domain, .system)
        XCTAssertEqual(runner.calls, [["/bin/launchctl", "print", "system/com.example.updater"]])
    }

    func testPlistNamedDifferentlyFromItsLabelIsFoundByContent() throws {
        try write(label: "com.example.other", in: agents)
        let plist = try write(label: "com.example.job", in: agents, fileName: "renamed.plist")

        let observation = collector.observe(label: "com.example.job")

        XCTAssertEqual(observation.status, .notLoaded)
        XCTAssertEqual(observation.plistPath, plist.path)
    }

    func testFileNamedAfterTheLabelButDefiningAnotherJobIsNotIt() throws {
        try write(label: "com.example.other", in: agents, fileName: "com.example.job.plist")

        XCTAssertEqual(collector.observe(label: "com.example.job").status, .plistMissing)
    }

    func testJobLoadedFromOutsideTheSearchFolders() throws {
        let elsewhere = try write(label: "com.example.job", in: root, extra: ["StartInterval": 900])
        runner.answer("gui/501/com.example.job", output: "gui/501/com.example.job = {\n\tpath = \(elsewhere.path)\n\tstate = not running\n}\n")

        let observation = collector.observe(label: "com.example.job")

        XCTAssertEqual(observation.status, .loaded(LaunchdServiceState(runState: .notRunning, plistPath: elsewhere.path)))
        XCTAssertEqual(observation.domain, .user(id: 501))
        XCTAssertEqual(observation.plistPath, elsewhere.path)
        XCTAssertEqual(observation.definition?.startInterval, 900)
    }

    func testJobLoadedFromAPlistThatCannotBeRead() {
        runner.answer("system/com.example.running", output: LaunchdFixture.agentRunning.text)

        let observation = collector.observe(label: "com.example.running")

        guard case .loaded = observation.status else {
            return XCTFail("Expected loaded, got \(observation.status)")
        }
        XCTAssertEqual(observation.domain, .system)
        XCTAssertNil(observation.plistPath)
        XCTAssertNil(observation.definition)
        XCTAssertEqual(observation.scheduleDescription, "unknown: no plist was found")
    }

    func testPlistThatIsNotUnderstoodIsReportedAndTheJobIsStillRead() throws {
        let file = agents.appending(path: "com.example.exit-3.plist")
        try Data("garbage".utf8).write(to: file)
        runner.answer("gui/501/com.example.exit-3", output: LaunchdFixture.agentExit3.text)

        let observation = collector.observe(label: "com.example.exit-3")

        guard case .loaded = observation.status else {
            return XCTFail("Expected loaded, got \(observation.status)")
        }
        XCTAssertEqual(observation.plistPath, file.path)
        XCTAssertNil(observation.definition)
        XCTAssertEqual(observation.definitionProblem, "it is not a property list")
        XCTAssertEqual(observation.scheduleDescription, "unreadable: it is not a property list")
    }

    func testPlistWithAScheduleLaunchdWouldNotAcceptIsReported() throws {
        try write(label: "com.example.job", in: agents, extra: ["StartCalendarInterval": ["Hour": 25]])

        let observation = collector.observe(label: "com.example.job")

        XCTAssertEqual(observation.status, .notLoaded)
        XCTAssertEqual(observation.definitionProblem, "its StartCalendarInterval is not something launchd accepts")
    }

    // MARK: - When the state cannot be read

    func testLaunchctlFailingIsUnknownNotMissing() throws {
        try write(label: "com.example.job", in: agents)
        runner.answer("gui/501/com.example.job", with: .success(CommandResult(exitCode: 1, errorOutput: "Something else\n")))

        XCTAssertEqual(
            collector.observe(label: "com.example.job").status,
            .unknown(reason: "launchctl print failed with exit code 1")
        )
    }

    func testLaunchctlNotAnsweringIsUnknown() throws {
        try write(label: "com.example.job", in: agents)
        runner.answer("gui/501/com.example.job", with: .failure(.timedOut(after: 10)))

        XCTAssertEqual(collector.observe(label: "com.example.job").status, .unknown(reason: "launchctl did not answer in time"))
    }

    func testLaunchctlNotStartingIsUnknown() throws {
        try write(label: "com.example.job", in: agents)
        runner.answer("gui/501/com.example.job", with: .failure(.notStarted(reason: "no such file")))

        XCTAssertEqual(
            collector.observe(label: "com.example.job").status,
            .unknown(reason: "launchctl could not be started: no such file")
        )
    }

    func testOutputThatIsNotUnderstoodIsUnknown() throws {
        try write(label: "com.example.job", in: agents)
        runner.answer("gui/501/com.example.job", output: "something entirely different\n")

        XCTAssertEqual(
            collector.observe(label: "com.example.job").status,
            .unknown(reason: "the output of launchctl print was not understood")
        )
    }

    func testNotFoundIsRecognisedByItsMessageWhateverTheExitCode() throws {
        try write(label: "com.example.job", in: agents)
        let result = CommandResult(exitCode: 3, errorOutput: "Could not find service \"com.example.job\" in domain for user gui: 501\n")
        runner.answer("gui/501/com.example.job", with: .success(result))

        XCTAssertEqual(collector.observe(label: "com.example.job").status, .notLoaded)
    }

    func testLabelThatIsNotAPlainNameNeverReachesLaunchctl() {
        for label in ["", "-x", "com example", "com.example/../x", "a;b", "$(id)", "gui/501/x"] {
            XCTAssertEqual(collector.observe(label: label).status, .unknown(reason: "the label is not a plain name"), label)
        }
        XCTAssertEqual(runner.calls, [])
    }

    // MARK: - Descriptions

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

    func testScheduleDescriptionForAJobWithoutATimetable() {
        let observation = LaunchdObservation(
            label: "com.example.job",
            status: .notLoaded,
            definition: LaunchdJobDefinition(label: "com.example.job")
        )

        XCTAssertEqual(observation.scheduleDescription, "none: the job does not run on a timetable")
    }

    // MARK: - Helpers

    @discardableResult
    private func write(label: String, in directory: URL, fileName: String? = nil, extra: [String: Any] = [:]) throws -> URL {
        let url = directory.appending(path: fileName ?? "\(label).plist")
        let plist = extra.merging(["Label": label, "ProgramArguments": ["/usr/bin/true"]]) { _, new in new }
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: url)
        return url
    }
}
