import Foundation

/// One job as it is shown to a person: the verdict, and what it rests on.
public struct JobReport: Sendable, Equatable, Identifiable {
    public struct CheckReport: Sendable, Equatable {
        /// The check in a few words, as it is written in the config.
        public var label: String
        /// The type of check, as it is written in the config: "file-age".
        public var kind: String
        /// What it looks at: a path, a program, or "the job's log".
        public var target: String
        public var outcome: CheckOutcome

        public init(label: String, kind: String = "", target: String = "", outcome: CheckOutcome) {
            self.label = label
            self.kind = kind
            self.target = target
            self.outcome = outcome
        }

        public init(check: Check, outcome: CheckOutcome) {
            self.init(label: check.label, kind: check.kind, target: check.target, outcome: outcome)
        }
    }

    public var job: Job
    public var state: JobState
    /// Why, in a sentence that completes "The job is <state>: …".
    public var reason: String
    /// Whether the job was looked at. A job on a machine or a scheduler that is not read yet is listed and
    /// not judged; nothing is remembered about it.
    public var isJudged: Bool
    /// The scheduler and the job's name in it, such as "launchd com.example.backup". `nil` for a job known
    /// only through its checks.
    public var source: String?
    /// What the scheduler said about the job, in one line.
    public var sourceStatus: String?
    /// The same in parts, each marked when it is a sign of trouble: "loaded, idle", "last exit 1", "41 runs".
    public var sourceStatusParts: [StatusPart] = []
    /// The timetable in plain words, or why there is none to show.
    public var schedule: String
    /// The latest run is known to have happened no earlier than this.
    public var lastRun: Date?
    public var nextRun: Date?
    /// The scheduled time the verdict is about: for a job that is `missed` or `waiting`, the run that is due.
    /// `nil` for a job with no scheduled times.
    public var expectedRun: Date?
    /// How often the job runs, for a job that repeats on an interval and has no scheduled times.
    public var repeatInterval: TimeInterval?
    /// One entry per check that was carried out. Empty when the checks were not run.
    public var checks: [CheckReport]
    /// The verdicts the job settled on, oldest first.
    public var transitions: [JobRecord.Transition]
    /// The files the job writes its output to, and those its checks read.
    public var logPaths: [String]
    /// Whether the state is news since the last look.
    public var changed: Bool
    /// The recent runs, oldest first.
    public var runs: [RunMark] = []
    /// Whether the job's machine is one that is allowed to be switched off or asleep.
    public var hostMayBeOffline = false

    /// Whether the job wants a look without having failed: a run is missing, it has been unreadable for
    /// long, or its machine cannot be reached and is not one that is allowed to be off.
    public var needsAttention: Bool {
        switch state {
        case .missed, .stale: true
        case .hostOffline: !hostMayBeOffline
        case .ok, .running, .waiting, .failed, .unknown: false
        }
    }

    public var id: String { job.id }

    public init(
        job: Job,
        state: JobState,
        reason: String,
        isJudged: Bool = true,
        source: String? = nil,
        sourceStatus: String? = nil,
        schedule: String = "",
        lastRun: Date? = nil,
        nextRun: Date? = nil,
        checks: [CheckReport] = [],
        transitions: [JobRecord.Transition] = [],
        logPaths: [String] = [],
        changed: Bool = false
    ) {
        self.job = job
        self.state = state
        self.reason = reason
        self.isJudged = isJudged
        self.source = source
        self.sourceStatus = sourceStatus
        self.schedule = schedule
        self.lastRun = lastRun
        self.nextRun = nextRun
        self.checks = checks
        self.transitions = transitions
        self.logPaths = logPaths
        self.changed = changed
    }
}

/// A piece of what a scheduler said about a job.
public struct StatusPart: Sendable, Equatable {
    public var text: String
    /// Whether it is a sign of trouble, such as a non-zero exit code.
    public var isProblem: Bool

    public init(_ text: String, isProblem: Bool = false) {
        self.text = text
        self.isProblem = isProblem
    }
}

/// A machine jobs run on, under a name that does not clash with Foundation's `Host` where both are imported.
public typealias WatchedHost = Host

/// All jobs at a glance.
public enum OverallStatus: Sendable, Equatable {
    case allFine
    /// A run is missing, a job has been unreadable for long, or a machine that should be on cannot be reached.
    case needsAttention
    /// A job ran and went wrong, or cannot run.
    case failure

    public init(reports: [JobReport]) {
        if reports.contains(where: { $0.state == .failed }) {
            self = .failure
        } else if reports.contains(where: \.needsAttention) {
            self = .needsAttention
        } else {
            self = .allFine
        }
    }
}

/// The jobs of one machine, in the order they are listed.
public struct HostGroup: Sendable, Equatable, Identifiable {
    public var host: Host
    public var reports: [JobReport]

    public var id: String { host.id }

    /// The jobs grouped by machine, machines in the order of the config. Within a machine the jobs that need
    /// a look come first, then by name. A machine with no jobs is left out.
    public static func groups(of reports: [JobReport], hosts: [Host]) -> [Self] {
        hosts.compactMap { host in
            let own = reports.filter { $0.job.hostID == host.id }.sorted { first, second in
                if first.state.listRank != second.state.listRank {
                    return first.state.listRank < second.state.listRank
                }
                return first.job.name.localizedStandardCompare(second.job.name) == .orderedAscending
            }
            return own.isEmpty ? nil : Self(host: host, reports: own)
        }
    }
}

extension JobState {
    /// Where the state comes in a list: the smaller, the further up.
    var listRank: Int {
        switch self {
        case .failed: 0
        case .missed: 1
        case .stale: 2
        case .hostOffline: 3
        case .unknown: 4
        case .running: 5
        case .waiting: 6
        case .ok: 7
        }
    }
}

extension Schedule {
    /// The schedule in a few words, such as "daily at 02:00", "Mon at 06:30" or "every 15m".
    public var summary: String {
        switch self {
        case let .daily(time): "daily at \(time.text)"
        case let .weekly(day, time): "\(day.rawValue.capitalized) at \(time.text)"
        case let .every(interval): "every \(LaunchdJobDefinition.compact(seconds: Int(interval)))"
        }
    }
}

extension TimeOfDay {
    var text: String {
        String(format: "%02d:%02d", hour, minute)
    }
}
