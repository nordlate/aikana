import AikanaCore
import XCTest

/// Jobs on "another machine" that is this Mac behind a real shell: the scripts are the real ones, the home
/// folder and `launchctl` are the test's own.
final class JobWatchRemoteTests: XCTestCase {
    private var root: URL!
    private var home: URL!
    private var fakeBin: URL!
    /// Programs that stand in for the machine's own, by name: found first on the shell's path.
    private var standIns: [String: String] = [:]
    private let hosts = "{ id: 'studio', ssh: 'studio-mac' }, { id: 'tower', ssh: 'tower', mayBeOffline: true }"

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appending(path: "aikana-watch-\(UUID().uuidString)")
        home = root.appending(path: "home")
        fakeBin = root.appending(path: "bin")
        try FileManager.default.createDirectory(at: home.appending(path: "Library/LaunchAgents"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: fakeBin, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appending(path: "launchctl"), withIntermediateDirectories: true)
        // Answers `print <target>` from a file named after the target, as launchctl does for a job it knows.
        try script("launchctl", """
            f="\(root.path)/launchctl/$(printf '%s' "$2" | tr / _)"
            if [ -f "$f" ]; then cat "$f"; else echo 'Could not find service' >&2; exit 113; fi
            """)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: root)
    }

    // MARK: - A Mac that answers

    func testALaunchdJobOnAnotherMacIsJudgedLikeALocalOne() throws {
        try addAgent(label: "com.example.exit-3", fixture: .agentExit3)
        var history = History()

        let report = try XCTUnwrap(try look("{ id: 'report', host: 'studio', source: { launchd: 'com.example.exit-3' } }", history: &history).first)

        XCTAssertEqual(report.state, .failed)
        XCTAssertEqual(report.reason, "its last run exited with code 3")
        XCTAssertEqual(report.source, "launchd com.example.exit-3")
        XCTAssertEqual(report.sourceStatus, "loaded, not running, 1 run, last exit code 3")
        XCTAssertEqual(report.schedule, "daily at 02:00")
        XCTAssertEqual(report.logPaths, ["/tmp/com.example.exit3.log"])
        XCTAssertTrue(report.isJudged)
        XCTAssertEqual(history.jobs["report"]?.state, .failed)
    }

    func testAJobThatIsNotLoadedOnTheOtherMac() throws {
        try addAgent(label: "com.example.idle", fixture: nil)
        var history = History()

        let report = try XCTUnwrap(try look("{ id: 'idle', host: 'studio', source: { launchd: 'com.example.idle' } }", history: &history).first)

        XCTAssertEqual(report.state, .failed)
        XCTAssertEqual(report.reason, "the scheduler has not loaded this job, so it will not run")
    }

    func testChecksRunOnTheOtherMachine() throws {
        try Data(count: 2000).write(to: home.appending(path: "backup.tar"))
        try Data("started\nall done\n".utf8).write(to: home.appending(path: "backup.log"))
        var history = History()
        let job = """
            { id: 'backup', host: 'studio', schedule: { daily: '02:00' }, checks: [
                { type: 'file-size', path: '~/backup.tar', minSize: '1KB' },
                { type: 'file-size', path: '~/backup.tar', minSize: '1MB' },
                { type: 'command', run: ['/bin/test', '-f', '\(home.path)/backup.tar'] },
                { type: 'command', run: ['/usr/bin/false'] },
                { type: 'file-age', path: '~/none/*.tar', maxAge: '1d' }
            ] }
            """

        let report = try XCTUnwrap(try look(job, history: &history).first)

        XCTAssertEqual(report.checks.map(\.outcome.result), [
            .passed,
            .failed("\(home.path)/backup.tar is 2 KB, less than the 1 MB it should be"),
            .passed,
            .failed("/usr/bin/false exited with code 1"),
            .failed("no file matches ~/none/*.tar")
        ])
        XCTAssertEqual(report.state, .failed)
    }

    func testALogOnTheOtherMachineIsReadForItsPattern() throws {
        try Data("started\nTraceback (most recent call last)\n".utf8).write(to: home.appending(path: "job.log"))
        var history = History()
        let job = "{ id: 'job', host: 'studio', schedule: { every: '1h' }, checks: [ { type: 'file-age', path: '~/job.log', maxAge: '1h' } ] }"
        XCTAssertEqual(try look(job, history: &history).first?.checks.map(\.outcome.result), [.passed])
    }

    func testTimesAreReadInTheOtherMachinesTimeZone() throws {
        try script("readlink", "echo /usr/share/zoneinfo/Pacific/Auckland")
        var history = History()
        let job = "{ id: 'far', host: 'studio', schedule: { daily: '02:00' }, checks: [ { type: 'command', run: ['/usr/bin/true'] } ] }"

        let next = try XCTUnwrap(try look(job, history: &history).first?.nextRun)

        var auckland = Calendar(identifier: .gregorian)
        auckland.timeZone = try XCTUnwrap(TimeZone(identifier: "Pacific/Auckland"))
        XCTAssertEqual(auckland.dateComponents([.hour, .minute], from: next), DateComponents(hour: 2, minute: 0))
    }

    // MARK: - A machine that cannot be used

    func testAMachineThatCannotBeReachedIsOfflineAndItsJobsAreNotJudgedOrChecked() throws {
        try Data().write(to: home.appending(path: "touched-by-check"))
        var history = History()
        let jobs = """
            { id: 'a', host: 'studio', source: { launchd: 'com.example.a' } },
            { id: 'b', host: 'studio', schedule: { daily: '02:00' }, checks: [ { type: 'command', run: ['/usr/bin/true'] } ] }
            """

        let reports = try look(jobs, history: &history, shell: unreachable)

        XCTAssertEqual(reports.map(\.state), [.hostOffline, .hostOffline])
        XCTAssertEqual(reports.map(\.reason), Array(repeating: "studio cannot be reached: ssh: connect to host studio-mac port 22: Operation timed out", count: 2))
        XCTAssertEqual(reports.map(\.checks.count), [0, 0])
        XCTAssertEqual(reports.map(\.needsAttention), [true, true])
        XCTAssertEqual(OverallStatus(reports: reports), .needsAttention)
        XCTAssertNotNil(history.jobs["a"]?.offlineSince)
    }

    func testAMachineThatMayBeOfflineIsOfflineWithoutBeingAProblem() throws {
        var history = History()

        let reports = try look("{ id: 'a', host: 'tower', source: { launchd: 'com.example.a' } }", history: &history, shell: unreachable)

        XCTAssertEqual(reports.map(\.state), [.hostOffline])
        XCTAssertEqual(reports.map(\.needsAttention), [false])
        XCTAssertEqual(OverallStatus(reports: reports), .allFine)
    }

    func testAMachineWhoseClockIsOffIsNotJudged() throws {
        try addAgent(label: "com.example.exit-3", fixture: .agentExit3)
        var history = History()

        let report = try XCTUnwrap(try look(
            "{ id: 'report', host: 'studio', source: { launchd: 'com.example.exit-3' } }",
            history: &history,
            now: Date().addingTimeInterval(3 * 3600)
        ).first)

        XCTAssertEqual(report.state, .unknown)
        XCTAssertEqual(report.reason, "the clock on studio differs from this Mac's by 3h")
        XCTAssertTrue(report.checks.isEmpty)
    }

    func testAMachineThatAnswersWithSomethingElseIsUnknownNotOffline() throws {
        var history = History()
        let silent: @Sendable (String) -> RemoteShell = { _ in RemoteShell(runner: ProcessCommandRunner(), executable: "/usr/bin/true", arguments: []) }

        let report = try XCTUnwrap(try look("{ id: 'a', host: 'studio', source: { launchd: 'com.example.a' } }", history: &history, shell: silent).first)

        XCTAssertEqual(report.state, .unknown)
        XCTAssertEqual(report.reason, "studio did not answer as expected: the script did not finish")
    }

    func testALaunchdJobOnAMachineThatIsNotAMacIsNotJudged() throws {
        try script("uname", "echo Linux")
        var history = History()

        let report = try XCTUnwrap(try look("{ id: 'a', host: 'studio', source: { launchd: 'com.example.a' } }", history: &history).first)

        XCTAssertFalse(report.isJudged)
        XCTAssertEqual(report.reason, "not judged yet: studio is not a Mac, so it has no launchd jobs")
        XCTAssertTrue(history.jobs.isEmpty)
    }

    func testOneMachineThatDoesNotAnswerDoesNotKeepTheOthersFromBeingJudged() throws {
        try addAgent(label: "com.example.exit-3", fixture: .agentExit3)
        var history = History()
        let home = home.path, fakeBin = fakeBin.path
        let mixed: @Sendable (String) -> RemoteShell = { alias in
            alias == "tower" ? Self.unreachableShell(alias) : Self.localShell(home: home, fakeBin: fakeBin)
        }
        let jobs = """
            { id: 'far', host: 'tower', source: { launchd: 'com.example.far' } },
            { id: 'report', host: 'studio', source: { launchd: 'com.example.exit-3' } },
            { id: 'here', schedule: { every: '1h' }, checks: [ { type: 'command', run: ['/usr/bin/true'] } ] }
            """

        let reports = try look(jobs, history: &history, shell: mixed)

        XCTAssertEqual(reports.map(\.id), ["far", "report", "here"])
        XCTAssertEqual(reports.map(\.state), [.hostOffline, .failed, .ok])
        XCTAssertEqual(history.jobs.keys.sorted(), ["far", "here", "report"])
    }

    // MARK: - Helpers

    private var unreachable: @Sendable (String) -> RemoteShell {
        { Self.unreachableShell($0) }
    }

    private static func unreachableShell(_ alias: String) -> RemoteShell {
        let runner = RecordingRunner(answer: CommandResult(
            exitCode: 255,
            errorOutput: "ssh: connect to host \(alias) port 22: Operation timed out\r\n"
        ))
        return RemoteShell.ssh(alias: alias, runner: runner, controlDirectory: nil)
    }

    /// A shell on this Mac whose home folder is the test's, with the test's stand-ins first on its path.
    private static func localShell(home: String, fakeBin: String) -> RemoteShell {
        RemoteShell(
            runner: ProcessCommandRunner(),
            executable: "/usr/bin/env",
            arguments: ["HOME=\(home)", "PATH=\(fakeBin):/usr/bin:/bin:/usr/sbin:/sbin", "/bin/sh"]
        )
    }

    private func script(_ name: String, _ body: String) throws {
        let url = fakeBin.appending(path: name)
        try Data("#!/bin/sh\n\(body)\n".utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }

    /// A daily agent in the "remote" home folder; loaded, with the fixture as what launchctl prints, or not.
    private func addAgent(label: String, fixture: LaunchdFixture?) throws {
        let plist: [String: Any] = ["Label": label, "ProgramArguments": ["/usr/bin/true"], "StartCalendarInterval": ["Hour": 2, "Minute": 0]]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .binary, options: 0)
            .write(to: home.appending(path: "Library/LaunchAgents/\(label).plist"))
        if let fixture {
            try Data(fixture.text.utf8).write(to: root.appending(path: "launchctl/gui_\(getuid())_\(label)"))
        }
    }

    private func look(
        _ jobs: String,
        history: inout History,
        shell: (@Sendable (String) -> RemoteShell)? = nil,
        now: Date = Date()
    ) throws -> [JobReport] {
        let config = try ConfigFixture.load("{ version: 1, hosts: [\(hosts)], jobs: [ \(jobs) ] }")
        let home = home.path, fakeBin = fakeBin.path
        let runner = FakeCommandRunner()
        let watch = JobWatch(
            collector: LaunchdCollector(runner: runner, locations: []),
            host: LocalHost(homeDirectory: self.home, runner: ProcessCommandRunner()),
            uptime: { JobWatch.Uptime(awakeSince: nil, bootedAt: nil) },
            remoteShell: shell ?? { _ in Self.localShell(home: home, fakeBin: fakeBin) },
            remoteLaunchctlPath: self.fakeBin.appending(path: "launchctl").path
        )
        return watch.look(at: config, history: &history, now: now, calendar: .current)
    }
}
