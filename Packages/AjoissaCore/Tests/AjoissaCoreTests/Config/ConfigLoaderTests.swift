import AjoissaCore
import XCTest

final class ConfigLoaderTests: XCTestCase {
    // MARK: - Files

    func testExampleConfigLoads() throws {
        let config = try ConfigLoader.load(contentsOf: ConfigFixture.exampleURL)

        XCTAssertEqual(config.hosts.map(\.id), ["local", "studio", "tower"])
        XCTAssertEqual(config.jobs.map(\.id), [
            "nightly-report", "photo-backup", "render-cleanup", "tower-updates",
            "tower-db-dump", "weekly-export", "sync-heartbeat"
        ])
        XCTAssertEqual(config.host(withID: "tower"), Host(id: "tower", connection: .ssh(alias: "tower"), mayBeOffline: true))
        XCTAssertEqual(config.jobs[3].source, .systemd(unit: "package-update.timer", scope: .system))
        XCTAssertEqual(config.jobs[5].schedule, .weekly(on: .mon, at: try XCTUnwrap(TimeOfDay(hour: 6, minute: 30))))
    }

    func testMissingFileIsUnreadable() {
        let url = URL(fileURLWithPath: "/nonexistent/ajoissa/config.json5")

        XCTAssertThrowsError(try ConfigLoader.load(contentsOf: url)) { error in
            guard case let .unreadable(path, reason) = error as? ConfigError else {
                return XCTFail("Expected unreadable, got \(error)")
            }
            XCTAssertEqual(path, url.path)
            XCTAssertFalse(reason.isEmpty)
        }
    }

    func testBrokenSyntaxIsReportedAsSyntax() {
        XCTAssertThrowsError(try ConfigFixture.load("{ version: 1, jobs: [ }")) { error in
            guard case let .syntax(message) = error as? ConfigError else {
                return XCTFail("Expected syntax, got \(error)")
            }
            XCTAssertFalse(message.isEmpty)
        }
    }

    func testEmptyFileIsReportedAsSyntax() {
        XCTAssertThrowsError(try ConfigFixture.load("")) { error in
            guard case .syntax = error as? ConfigError else {
                return XCTFail("Expected syntax, got \(error)")
            }
        }
    }

    func testJSON5CommentsTrailingCommasAndUnquotedKeysAreAccepted() throws {
        let config = try ConfigFixture.load("""
            // a comment
            {
              version: 1, /* another */
              jobs: [
                { id: 'a', source: { launchd: "com.example.a" }, },
              ],
            }
            """)

        XCTAssertEqual(config.jobs.map(\.id), ["a"])
    }

    // MARK: - Top level

    func testFileMustBeAnObject() {
        XCTAssertEqual(ConfigFixture.issues("[1]"), ["The file must contain one object with version, hosts and jobs."])
    }

    func testEmptyJobListIsValidAndLocalHostAlwaysExists() throws {
        let config = try ConfigFixture.load("{ version: 1, jobs: [] }")

        XCTAssertEqual(config.hosts, [.local])
        XCTAssertEqual(config.jobs, [])
    }

    func testVersionIsRequired() {
        XCTAssertEqual(ConfigFixture.issues("{ jobs: [] }"), ["version: is required; use 1"])
    }

    func testOtherVersionsAreRefused() {
        XCTAssertEqual(
            ConfigFixture.issues("{ version: 2, jobs: [] }"),
            ["version: is 2, but this version of Ajoissa only reads version 1"]
        )
    }

    func testVersionMustBeAWholeNumber() {
        for value in ["'1'", "true", "1.5"] {
            XCTAssertEqual(ConfigFixture.issues("{ version: \(value), jobs: [] }"), ["version: must be a whole number"], value)
        }
    }

    func testJobsIsRequired() {
        XCTAssertEqual(ConfigFixture.issues("{ version: 1 }"), ["jobs: is required; it is a list and may be empty"])
    }

    func testJobsMustBeAListOfObjects() {
        XCTAssertEqual(ConfigFixture.issues("{ version: 1, jobs: {} }"), ["jobs: must be a list"])
        XCTAssertEqual(ConfigFixture.issues("{ version: 1, jobs: [1] }"), ["jobs[0]: must be an object"])
    }

    func testUnknownTopLevelSettingIsReported() {
        XCTAssertEqual(ConfigFixture.issues("{ version: 1, jobs: [], job: [] }"), ["job: is not a known setting"])
    }

    func testEveryProblemIsReportedInFileOrder() {
        let issues = ConfigFixture.issues("""
            {
              version: 1,
              hosts: [ { id: 'box' } ],
              jobs: [
                { id: 'a', source: { launchd: 'com.example.a' }, grace: 'soon' },
                { id: 'b', host: 'nowhere', source: { launchd: 'com.example.b' } },
              ],
            }
            """)

        XCTAssertEqual(issues, [
            "hosts[0] (box).ssh: is required",
            "jobs[0] (a).grace: must be a duration such as \"90s\", \"30m\", \"26h\" or \"2d\"",
            "jobs[1] (b).host: is \"nowhere\", which is not defined under hosts"
        ])
    }

    // MARK: - Settings written twice

    func testSettingWrittenTwiceIsReportedWithItsLine() {
        let issues = ConfigFixture.issues("""
            {
              version: 1,
              jobs: [],
              // a comment with "jobs" in it
              jobs: [ { id: 'a', source: { launchd: 'com.example.a' } } ],
            }
            """)

        XCTAssertEqual(issues, ["line 5: \"jobs\" is set twice in the same object, and only one of them would be used"])
    }

    func testQuotedAndUnquotedSpellingsOfASettingAreTheSameSetting() {
        let issues = ConfigFixture.issues("""
            { version: 1, jobs: [
              { id: 'a', "id": 'b', 'id': 'c', source: { launchd: 'com.example.a' } }
            ] }
            """)

        XCTAssertEqual(issues, [
            "line 2: \"id\" is set twice in the same object, and only one of them would be used",
            "line 2: \"id\" is set twice in the same object, and only one of them would be used"
        ])
    }

    func testSameSettingInDifferentObjectsOrAsAValueIsNotADuplicate() throws {
        let config = try ConfigFixture.load("""
            {
              version: 1,
              hosts: [ { id: 'box', ssh: 'box' } ],
              jobs: [
                { id: 'a', name: 'id', source: { launchd: 'com.example.a' } },
                /* id: 'x', */
                { id: 'b', name: "a } ] 'quoted' \\" { id: 1, id: 2", source: { launchd: 'com.example.b' },
                  checks: [ { type: 'command', run: ['/usr/bin/true', 'id', 'id'] }, { type: 'file-age', path: '/tmp/x' } ] },
              ],
            }
            """)

        XCTAssertEqual(config.jobs.map(\.id), ["a", "b"])
    }

    // MARK: - Hosts

    func testHostIDIsRequired() {
        XCTAssertEqual(hostIssues("ssh: 'a'"), ["hosts[0].id: is required"])
    }

    func testHostIDMustBeAPlainIdentifier() {
        let message = "may only contain lower-case letters, digits, \".\", \"-\" and \"_\", and must start with a letter or digit"

        for id in ["Big Box", "-box", "box;reboot", "bäx", String(repeating: "a", count: 65)] {
            XCTAssertEqual(hostIssues("id: '\(id)', ssh: 'a'"), ["hosts[0].id: \(message)"], id)
        }
    }

    func testMalformedIDIsKeptOutOfTheLocation() {
        let issues = hostIssues("id: 'two\\nlines', ssh: 'a'")

        XCTAssertEqual(issues.count, 1)
        XCTAssertTrue(issues[0].hasPrefix("hosts[0].id: "), issues[0])
    }

    func testLocalHostCannotBeRedefined() {
        XCTAssertEqual(
            hostIssues("id: 'local', ssh: 'a'"),
            ["hosts[0] (local).id: \"local\" always means this Mac and cannot be redefined"]
        )
    }

    func testHostIDsMustBeUnique() {
        XCTAssertEqual(
            ConfigFixture.issues("{ version: 1, hosts: [ { id: 'a', ssh: 'x' }, { id: 'a', ssh: 'y' } ], jobs: [] }"),
            ["hosts[1] (a).id: is used more than once"]
        )
    }

    func testHostNeedsAnSSHAlias() {
        XCTAssertEqual(hostIssues("id: 'a'"), ["hosts[0] (a).ssh: is required"])
    }

    func testSSHAliasMustBeOnePlainWord() {
        let message = "hosts[0] (a).ssh: must be a host alias from ~/.ssh/config: letters, digits, \".\", \"_\" and \"-\" only, and not starting with \"-\""

        for alias in ["-oProxyCommand=evil", "my box", "box;reboot", "$(id)", "user@box", "box\\ttab", "bäx"] {
            XCTAssertEqual(hostIssues("id: 'a', ssh: '\(alias)'"), [message], alias)
        }
        XCTAssertEqual(hostIssues("id: 'a', ssh: 'Studio-Mac_2.local'"), [])
    }

    func testDuplicateHostIsReportedEvenWhenTheFirstOneIsBroken() {
        let issues = ConfigFixture.issues("{ version: 1, hosts: [ { id: 't', ssh: '-bad' }, { id: 't', ssh: 'ok' } ], jobs: [] }")

        XCTAssertEqual(issues.count, 2)
        XCTAssertEqual(issues.last, "hosts[1] (t).id: is used more than once")
    }

    func testMayBeOfflineMustBeABoolean() {
        XCTAssertEqual(hostIssues("id: 'a', ssh: 'a', mayBeOffline: 'yes'"), ["hosts[0] (a).mayBeOffline: must be true or false"])
        XCTAssertEqual(hostIssues("id: 'a', ssh: 'a', mayBeOffline: 1"), ["hosts[0] (a).mayBeOffline: must be true or false"])
    }

    func testUnknownHostSettingIsReported() {
        XCTAssertEqual(hostIssues("id: 'a', ssh: 'a', port: 22"), ["hosts[0] (a).port: is not a known setting"])
    }

    func testHostDefaultsToAlwaysExpectedOnline() throws {
        let config = try ConfigFixture.load("{ version: 1, hosts: [ { id: 'a', ssh: 'alias' } ], jobs: [] }")

        XCTAssertEqual(config.hosts.last, Host(id: "a", connection: .ssh(alias: "alias"), mayBeOffline: false))
    }

    func testBrokenHostDoesNotAlsoMakeItsJobsUnknown() {
        let issues = ConfigFixture.issues(ConfigFixture.config(
            job: "id: 'a', host: 'box', source: { launchd: 'com.example.a' }",
            hosts: "{ id: 'box', ssh: '-x' }"
        ))

        XCTAssertEqual(issues.count, 1)
        XCTAssertTrue(issues[0].hasPrefix("hosts[0] (box).ssh:"))
    }

    private func hostIssues(_ host: String) -> [String] {
        ConfigFixture.issues("{ version: 1, hosts: [ { \(host) } ], jobs: [] }")
    }
}
