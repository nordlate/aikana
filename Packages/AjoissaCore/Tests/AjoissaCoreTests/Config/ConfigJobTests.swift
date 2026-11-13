import AjoissaCore
import XCTest

final class ConfigJobTests: XCTestCase {
    private let launchd = "source: { launchd: 'com.example.a' }"
    private let box = "{ id: 'box', ssh: 'box' }"

    // MARK: - Basics

    func testDefaults() throws {
        let job = try ConfigFixture.job("id: 'a', \(launchd)")

        XCTAssertEqual(job, Job(
            id: "a",
            name: "a",
            hostID: "local",
            source: .launchd(label: "com.example.a"),
            schedule: nil,
            grace: Job.defaultGrace,
            notify: true,
            checks: []
        ))
    }

    func testEverySettingIsRead() throws {
        let job = try ConfigFixture.job(
            "id: 'a', name: 'Job A', host: 'box', \(launchd), schedule: { daily: '02:05' }, grace: '2h', notify: false",
            hosts: box
        )

        XCTAssertEqual(job.name, "Job A")
        XCTAssertEqual(job.hostID, "box")
        XCTAssertEqual(job.schedule, .daily(at: try XCTUnwrap(TimeOfDay(hour: 2, minute: 5))))
        XCTAssertEqual(job.grace, 7200)
        XCTAssertFalse(job.notify)
    }

    func testIDIsRequired() {
        XCTAssertEqual(issues(launchd), ["jobs[0].id: is required"])
    }

    func testIDsMustBeUnique() {
        let config = "{ version: 1, jobs: [ { id: 'local', \(launchd) }, { id: 'local', \(launchd) } ] }"

        XCTAssertEqual(ConfigFixture.issues(config), ["jobs[1] (local).id: is used more than once"])
    }

    func testNameMustBeANonEmptyString() {
        XCTAssertEqual(issues("id: 'a', name: '', \(launchd)"), ["jobs[0] (a).name: must not be empty"])
        XCTAssertEqual(issues("id: 'a', name: 5, \(launchd)"), ["jobs[0] (a).name: must be a string"])
    }

    func testHostMustBeDefined() {
        XCTAssertEqual(
            issues("id: 'a', host: 'nope', \(launchd)"),
            ["jobs[0] (a).host: is \"nope\", which is not defined under hosts"]
        )
    }

    func testGraceMustBeAPositiveDuration() {
        let message = "jobs[0] (a).grace: must be a duration such as \"90s\", \"30m\", \"26h\" or \"2d\""

        for value in ["'0m'", "'1.5h'", "'soon'", "'-5m'", "'5 m'"] {
            XCTAssertEqual(issues("id: 'a', \(launchd), grace: \(value)"), [message], value)
        }
        XCTAssertEqual(issues("id: 'a', \(launchd), grace: 30"), ["jobs[0] (a).grace: must be a string"])
    }

    func testNotifyMustBeABoolean() {
        XCTAssertEqual(issues("id: 'a', \(launchd), notify: 'no'"), ["jobs[0] (a).notify: must be true or false"])
    }

    func testMisspelledSettingIsReported() {
        XCTAssertEqual(
            issues("id: 'a', \(launchd), shedule: { daily: '02:00' }"),
            ["jobs[0] (a).shedule: is not a known setting"]
        )
    }

    // MARK: - Source

    func testSourceKinds() throws {
        XCTAssertEqual(
            try ConfigFixture.job("id: 'a', host: 'box', source: { systemd: 'backup.timer' }", hosts: box).source,
            .systemd(unit: "backup.timer", scope: .system)
        )
        XCTAssertEqual(
            try ConfigFixture.job("id: 'a', host: 'box', source: { systemd: 'backup.service', scope: 'user' }", hosts: box).source,
            .systemd(unit: "backup.service", scope: .user)
        )
        XCTAssertEqual(
            try ConfigFixture.job("id: 'a', source: { cron: 'run backup.sh' }, checks: [ { type: 'file-age', path: '/tmp/x' } ]").source,
            .cron(matching: "run backup.sh")
        )
    }

    func testSourceMustBeAnObjectWithExactlyOneKind() {
        let message = "jobs[0] (a).source: must have exactly one of launchd, systemd, cron"

        XCTAssertEqual(issues("id: 'a', source: 'com.example.a'"), ["jobs[0] (a).source: must be an object"])
        XCTAssertEqual(issues("id: 'a', source: {}"), [message])
        XCTAssertEqual(issues("id: 'a', source: { launchd: 'x', cron: 'y' }"), [message])
    }

    func testLaunchdLabelCannotContainSpacesOrLookLikeAnOption() {
        let message = "jobs[0] (a).source.launchd: must be a launchd label, without spaces and not starting with \"-\""

        XCTAssertEqual(issues("id: 'a', source: { launchd: 'com example' }"), [message])
        XCTAssertEqual(issues("id: 'a', source: { launchd: '-x' }"), [message])
    }

    func testSystemdUnitMustBeATimerOrService() {
        XCTAssertEqual(
            issues("id: 'a', host: 'box', source: { systemd: 'backup' }", hosts: box),
            ["jobs[0] (a).source.systemd: must be a unit name ending in .timer or .service"]
        )
        XCTAssertEqual(
            issues("id: 'a', host: 'box', source: { systemd: '--now.timer' }", hosts: box),
            ["jobs[0] (a).source.systemd: must be a unit name, without spaces and not starting with \"-\""]
        )
    }

    func testSystemdScopeMustBeSystemOrUser() {
        XCTAssertEqual(
            issues("id: 'a', host: 'box', source: { systemd: 'backup.timer', scope: 'root' }", hosts: box),
            ["jobs[0] (a).source.scope: must be \"system\" or \"user\""]
        )
    }

    func testScopeOnlyBelongsToSystemd() {
        XCTAssertEqual(
            issues("id: 'a', source: { launchd: 'com.example.a', scope: 'user' }"),
            ["jobs[0] (a).source.scope: is not a known setting"]
        )
    }

    func testSystemdCannotRunOnThisMac() {
        XCTAssertEqual(
            issues("id: 'a', source: { systemd: 'backup.timer' }"),
            ["jobs[0] (a).source: systemd needs a Linux host, but this job runs on \"local\", which is this Mac"]
        )
    }

    // MARK: - Jobs without a source

    func testJobWithoutSourceNeedsASchedule() {
        XCTAssertEqual(
            issues("id: 'a', checks: [ { type: 'file-age', path: '/tmp/x' } ]"),
            ["jobs[0] (a).schedule: is required for a job without a source, because there is nowhere to read the schedule from"]
        )
    }

    func testJobWithoutSourceNeedsACheck() {
        let message = "jobs[0] (a): needs a source or at least one check; otherwise there is no way to tell whether it ran"

        XCTAssertEqual(issues("id: 'a', schedule: { daily: '02:00' }"), [message])
        XCTAssertEqual(issues("id: 'a', schedule: { daily: '02:00' }, checks: []"), [message])
    }

    // MARK: - Schedule

    func testScheduleKinds() throws {
        let check = "checks: [ { type: 'file-age', path: '/tmp/x' } ]"

        XCTAssertEqual(
            try ConfigFixture.job("id: 'a', schedule: { daily: '23:59' }, \(check)").schedule,
            .daily(at: try XCTUnwrap(TimeOfDay(hour: 23, minute: 59)))
        )
        XCTAssertEqual(
            try ConfigFixture.job("id: 'a', schedule: { weekly: { day: 'sun', at: '00:00' } }, \(check)").schedule,
            .weekly(on: .sun, at: try XCTUnwrap(TimeOfDay(hour: 0, minute: 0)))
        )
        XCTAssertEqual(try ConfigFixture.job("id: 'a', schedule: { every: '15m' }, \(check)").schedule, .every(900))
    }

    func testScheduleMustHaveExactlyOneKind() {
        let message = "jobs[0] (a).schedule: must have exactly one of daily, weekly, every"

        XCTAssertEqual(issues("id: 'a', \(launchd), schedule: {}"), [message])
        XCTAssertEqual(issues("id: 'a', \(launchd), schedule: { daily: '02:00', every: '1h' }"), [message])
    }

    func testDailyMustBeA24HourTime() {
        let message = "jobs[0] (a).schedule.daily: must be a 24-hour time such as \"02:00\""

        for value in ["2:00", "24:00", "02:60", "0200", "02:00:00", "2am"] {
            XCTAssertEqual(issues("id: 'a', \(launchd), schedule: { daily: '\(value)' }"), [message], value)
        }
    }

    func testWeeklyNeedsAKnownDayAndATime() {
        XCTAssertEqual(
            issues("id: 'a', \(launchd), schedule: { weekly: { day: 'monday', at: '02:00' } }"),
            ["jobs[0] (a).schedule.weekly.day: must be one of mon, tue, wed, thu, fri, sat, sun"]
        )
        XCTAssertEqual(
            issues("id: 'a', \(launchd), schedule: { weekly: { day: 'mon' } }"),
            ["jobs[0] (a).schedule.weekly.at: is required"]
        )
        XCTAssertEqual(
            issues("id: 'a', \(launchd), schedule: { weekly: { at: '02:00' } }"),
            ["jobs[0] (a).schedule.weekly.day: is required"]
        )
        XCTAssertEqual(
            issues("id: 'a', \(launchd), schedule: { weekly: 'mon 02:00' }"),
            ["jobs[0] (a).schedule.weekly: must be an object"]
        )
    }

    func testEveryMustBeADurationOfAtLeastOneMinute() {
        XCTAssertEqual(
            issues("id: 'a', \(launchd), schedule: { every: '30s' }"),
            ["jobs[0] (a).schedule.every: must be at least 1m"]
        )
        XCTAssertEqual(
            issues("id: 'a', \(launchd), schedule: { every: 'often' }"),
            ["jobs[0] (a).schedule.every: must be a duration such as \"90s\", \"30m\", \"26h\" or \"2d\""]
        )
        XCTAssertEqual(
            issues("id: 'a', \(launchd), schedule: { every: 15 }"),
            ["jobs[0] (a).schedule.every: must be a string"]
        )
    }

    private func issues(_ job: String, hosts: String = "") -> [String] {
        ConfigFixture.issues(ConfigFixture.config(job: job, hosts: hosts))
    }
}
