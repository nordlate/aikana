import AjoissaCore
import XCTest

final class ConfigCheckTests: XCTestCase {
    private let prefix = "jobs[0] (a).checks[0]"

    // MARK: - Any check

    func testCheckMustBeAnObjectWithAKnownType() {
        XCTAssertEqual(
            ConfigFixture.issues(ConfigFixture.config(job: "id: 'a', source: { launchd: 'x' }, checks: [ 'file-age' ]")),
            ["\(prefix): must be an object"]
        )
        XCTAssertEqual(issues("path: '/tmp/x'"), ["\(prefix).type: is required"])
        XCTAssertEqual(
            issues("type: 'http', url: 'https://example.com'"),
            ["\(prefix).type: is \"http\", but must be one of file-age, file-size, command, log-pattern"]
        )
    }

    func testMisspelledCheckSettingIsReported() {
        XCTAssertEqual(
            issues("type: 'file-age', path: '/tmp/x', maxage: '1h'"),
            ["\(prefix).maxage: is not a known setting"]
        )
    }

    func testChecksMustBeAList() {
        XCTAssertEqual(
            ConfigFixture.issues(ConfigFixture.config(job: "id: 'a', source: { launchd: 'x' }, checks: {}")),
            ["jobs[0] (a).checks: must be a list"]
        )
    }

    // MARK: - file-age

    func testFileAge() throws {
        XCTAssertEqual(
            try ConfigFixture.check("type: 'file-age', path: '~/Reports/*.md'"),
            .fileAge(path: "~/Reports/*.md", maxAge: nil)
        )
        XCTAssertEqual(
            try ConfigFixture.check("type: 'file-age', path: '/var/backups/x', maxAge: '26h'"),
            .fileAge(path: "/var/backups/x", maxAge: 93600)
        )
    }

    func testPathIsRequiredAndMustNotBeRelative() {
        XCTAssertEqual(issues("type: 'file-age'"), ["\(prefix).path: is required"])
        for path in ["reports/x.md", "./x", "~user/x", "~"] {
            XCTAssertEqual(
                issues("type: 'file-age', path: '\(path)'"),
                ["\(prefix).path: must be an absolute path, or start with ~/ for the home directory on the job's host"],
                path
            )
        }
    }

    func testMaxAgeMustBeADuration() {
        XCTAssertEqual(
            issues("type: 'file-age', path: '/tmp/x', maxAge: 'a day'"),
            ["\(prefix).maxAge: must be a duration such as \"90s\", \"30m\", \"26h\" or \"2d\""]
        )
    }

    // MARK: - file-size

    func testFileSize() throws {
        XCTAssertEqual(
            try ConfigFixture.check("type: 'file-size', path: '/backup/*.tar', minSize: '500MB'"),
            .fileSize(path: "/backup/*.tar", minBytes: 500_000_000)
        )
    }

    func testMinSizeIsRequiredAndMustBeASize() {
        XCTAssertEqual(issues("type: 'file-size', path: '/tmp/x'"), ["\(prefix).minSize: is required"])
        for size in ["10 MB", "0MB", "10mb", "10", "MB", "1.5GB", "10TB"] {
            XCTAssertEqual(
                issues("type: 'file-size', path: '/tmp/x', minSize: '\(size)'"),
                ["\(prefix).minSize: must be a size such as \"500KB\", \"10MB\" or \"1GB\""],
                size
            )
        }
    }

    // MARK: - command

    func testCommand() throws {
        XCTAssertEqual(
            try ConfigFixture.check("type: 'command', run: ['/usr/bin/test', '-s', '/tmp/a file']"),
            .command(arguments: ["/usr/bin/test", "-s", "/tmp/a file"], timeout: Check.defaultCommandTimeout)
        )
        XCTAssertEqual(
            try ConfigFixture.check("type: 'command', run: ['/usr/bin/true'], timeout: '10m'"),
            .command(arguments: ["/usr/bin/true"], timeout: 600)
        )
    }

    func testRunIsRequiredAndMustBeAListOfStrings() {
        let message = "\(prefix).run: must be a list of strings: the program, then its arguments, such as [\"/usr/bin/true\"]"

        XCTAssertEqual(issues("type: 'command'"), ["\(prefix).run: is required"])
        XCTAssertEqual(issues("type: 'command', run: 'ls -l'"), ["\(prefix).run: must be a list"])
        XCTAssertEqual(issues("type: 'command', run: []"), [message])
        XCTAssertEqual(issues("type: 'command', run: ['ls', 1]"), [message])
        XCTAssertEqual(issues("type: 'command', run: ['']"), [message])
    }

    func testTimeoutHasAnUpperLimit() {
        XCTAssertEqual(
            issues("type: 'command', run: ['/usr/bin/true'], timeout: '11m'"),
            ["\(prefix).timeout: must be at most 10m"]
        )
    }

    // MARK: - log-pattern

    func testLogPattern() throws {
        XCTAssertEqual(
            try ConfigFixture.check("type: 'log-pattern', notContains: 'Traceback'"),
            .logPattern(path: nil, contains: nil, notContains: "Traceback")
        )
        XCTAssertEqual(
            try ConfigFixture.check("type: 'log-pattern', path: '/var/log/x.log', contains: 'done', notContains: 'error'"),
            .logPattern(path: "/var/log/x.log", contains: "done", notContains: "error")
        )
    }

    func testLogPatternNeedsSomethingToLookFor() {
        XCTAssertEqual(issues("type: 'log-pattern', path: '/var/log/x.log'"), ["\(prefix): needs contains or notContains"])
    }

    func testLogPatternNeedsAPathUnlessTheSourceIsLaunchd() {
        let check = "checks: [ { type: 'log-pattern', contains: 'done' } ]"
        let message = "\(prefix).path: is required unless the job's source is launchd, whose log file is then used"

        XCTAssertEqual(ConfigFixture.issues(ConfigFixture.config(job: "id: 'a', source: { cron: 'x' }, \(check)")), [message])
        XCTAssertEqual(
            ConfigFixture.issues(ConfigFixture.config(job: "id: 'a', schedule: { daily: '02:00' }, \(check)")),
            [message]
        )
    }

    func testBrokenSourceDoesNotAlsoAskForALogPath() {
        let job = "id: 'a', source: { launchd: 'com example' }, checks: [ { type: 'log-pattern', contains: 'done' } ]"
        let issues = ConfigFixture.issues(ConfigFixture.config(job: job))

        XCTAssertEqual(issues.count, 1)
        XCTAssertTrue(issues[0].hasPrefix("jobs[0] (a).source.launchd:"))
    }

    private func issues(_ check: String) -> [String] {
        ConfigFixture.issues(ConfigFixture.config(check: check))
    }
}
