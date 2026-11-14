import AjoissaCore
import XCTest

/// A Mac made of a folder of plists, a fake `launchctl` and a fake file system, for looking at whole configs.
class WatchTestCase: XCTestCase {
    var root: URL!
    var agents: URL!
    var runner: FakeCommandRunner!
    var host: FakeHost!
    var watch: JobWatch!
    let calendar = TestClock.utc

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appending(path: "ajoissa-tests-\(UUID().uuidString)")
        agents = root.appending(path: "Home/Library/LaunchAgents")
        try FileManager.default.createDirectory(at: agents, withIntermediateDirectories: true)
        runner = FakeCommandRunner()
        host = FakeHost()
        watch = JobWatch(
            collector: LaunchdCollector(runner: runner, locations: [LaunchdSearchLocation(directory: agents, domain: .user(id: 501))]),
            host: host,
            uptime: { JobWatch.Uptime(awakeSince: nil, bootedAt: nil) },
            remoteShell: { _ in RemoteShell(runner: ProcessCommandRunner(), executable: "/usr/bin/false", arguments: []) }
        )
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: root)
    }

    /// A loaded agent that runs daily at 02:00 and whose last run exited with code 3.
    func addFailingAgent() throws {
        let plist: [String: Any] = [
            "Label": "com.example.exit-3",
            "ProgramArguments": ["/usr/bin/true"],
            "StartCalendarInterval": ["Hour": 2, "Minute": 0]
        ]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            .write(to: agents.appending(path: "com.example.exit-3.plist"))
        runner.answer("gui/501/com.example.exit-3", output: LaunchdFixture.agentExit3.text)
    }

    static let failingAgentJob = "{ id: 'report', name: 'Nightly report', source: { launchd: 'com.example.exit-3' } }"

    static func configText(jobs: String, hosts: String = "") -> String {
        "{ version: 1, hosts: [\(hosts)], jobs: [ \(jobs) ] }"
    }
}
