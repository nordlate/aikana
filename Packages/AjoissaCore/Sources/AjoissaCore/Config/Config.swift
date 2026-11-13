import Foundation

/// What the user expects to run: the machines, and the jobs on them.
///
/// A `Config` only exists in validated form. Build one with ``ConfigLoader``.
public struct Config: Sendable, Equatable {
    /// The only config file format version this engine reads.
    public static let supportedVersion = 1

    /// Every host a job can run on. Always starts with ``Host/local``.
    public let hosts: [Host]
    public let jobs: [Job]

    /// Not public: outside the engine, a config comes from ``ConfigLoader`` and has passed every rule.
    init(hosts: [Host], jobs: [Job]) {
        self.hosts = hosts
        self.jobs = jobs
    }

    public func host(withID id: String) -> Host? {
        hosts.first { $0.id == id }
    }
}

/// A machine that jobs run on.
public struct Host: Sendable, Equatable, Identifiable {
    public enum Connection: Sendable, Equatable {
        /// The Mac that Ajoissa itself runs on.
        case local
        /// Another machine, named by its alias in the user's `~/.ssh/config`.
        case ssh(alias: String)
    }

    /// The id of the host that is always present and cannot be redefined.
    public static let localID = "local"
    public static let local = Self(id: localID, connection: .local, mayBeOffline: false)

    public let id: String
    public let connection: Connection
    /// A machine that is allowed to be switched off or asleep. Being unreachable is then not a problem to report.
    public let mayBeOffline: Bool

    public init(id: String, connection: Connection, mayBeOffline: Bool) {
        self.id = id
        self.connection = connection
        self.mayBeOffline = mayBeOffline
    }
}

/// One thing that is expected to run on a schedule.
public struct Job: Sendable, Equatable, Identifiable {
    /// How long after its scheduled time a job may still run before it counts as missed, unless the config says otherwise.
    public static let defaultGrace: TimeInterval = 30 * 60

    public let id: String
    /// The name shown to the user. The id when the config gives none.
    public let name: String
    public let hostID: String
    /// Where the job is scheduled, if Ajoissa can read that. `nil` for a job that is only known through its checks.
    public let source: JobSource?
    /// When the job is expected to run. `nil` means the schedule is read from the source.
    public let schedule: Schedule?
    public let grace: TimeInterval
    /// Whether a problem with this job sends a notification.
    public let notify: Bool
    public let checks: [Check]

    public init(
        id: String,
        name: String,
        hostID: String,
        source: JobSource?,
        schedule: Schedule?,
        grace: TimeInterval,
        notify: Bool,
        checks: [Check]
    ) {
        self.id = id
        self.name = name
        self.hostID = hostID
        self.source = source
        self.schedule = schedule
        self.grace = grace
        self.notify = notify
        self.checks = checks
    }
}

/// The scheduler that runs a job.
public enum JobSource: Sendable, Equatable {
    public enum SystemdScope: String, Sendable, Equatable, CaseIterable {
        case system
        case user
    }

    /// A launchd agent or daemon, by its label.
    case launchd(label: String)
    /// A systemd timer or the service it starts, by unit name.
    case systemd(unit: String, scope: SystemdScope)
    /// A crontab line, identified by text that appears in exactly one line.
    case cron(matching: String)
}

/// When a job is expected to run. Times are in the time zone of the machine Ajoissa runs on.
public enum Schedule: Sendable, Equatable {
    /// The shortest interval that can be stated for a repeating job.
    public static let minimumInterval: TimeInterval = 60

    case daily(at: TimeOfDay)
    case weekly(on: Weekday, at: TimeOfDay)
    case every(TimeInterval)
}

public struct TimeOfDay: Sendable, Equatable {
    public let hour: Int
    public let minute: Int

    /// - Returns: `nil` unless the hour is 0–23 and the minute 0–59.
    public init?(hour: Int, minute: Int) {
        guard (0...23).contains(hour), (0...59).contains(minute) else { return nil }
        self.hour = hour
        self.minute = minute
    }
}

public enum Weekday: String, Sendable, Equatable, CaseIterable {
    case mon, tue, wed, thu, fri, sat, sun
}

/// What must be true for a run to count as successful, beyond the job's exit code.
///
/// Paths are kept as written. A leading `~/` is the home directory on the job's host, so it is expanded there, not here.
public enum Check: Sendable, Equatable {
    /// How long a `command` check may run when the config gives no timeout.
    public static let defaultCommandTimeout: TimeInterval = 30
    /// The longest timeout a `command` check may ask for.
    public static let maximumCommandTimeout: TimeInterval = 10 * 60

    /// A file matching `path` is newer than `maxAge`, or newer than the job's last expected run when `maxAge` is `nil`.
    case fileAge(path: String, maxAge: TimeInterval?)
    /// The newest file matching `path` is at least `minBytes` large.
    case fileSize(path: String, minBytes: Int64)
    /// The command exits with code 0 within `timeout`. Arguments are passed as given, without a shell.
    case command(arguments: [String], timeout: TimeInterval)
    /// A log file contains, or does not contain, some text since the job's last expected run.
    /// `path` is `nil` when the log path comes from the job's launchd definition.
    case logPattern(path: String?, contains: String?, notContains: String?)
}
