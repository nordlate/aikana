import Foundation

/// One job as it is shown to a person: the verdict, and what it rests on.
public struct JobReport: Sendable, Equatable, Identifiable {
    public struct CheckReport: Sendable, Equatable {
        /// The check in a few words, as it is written in the config.
        public var label: String
        public var outcome: CheckOutcome

        public init(label: String, outcome: CheckOutcome) {
            self.label = label
            self.outcome = outcome
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
    /// The timetable in plain words, or why there is none to show.
    public var schedule: String
    /// The latest run is known to have happened no earlier than this.
    public var lastRun: Date?
    public var nextRun: Date?
    /// One entry per check that was carried out. Empty when the checks were not run.
    public var checks: [CheckReport]
    /// The verdicts the job settled on, oldest first.
    public var transitions: [JobRecord.Transition]
    /// The files the job writes its output to, and those its checks read.
    public var logPaths: [String]
    /// Whether the state is news since the last look.
    public var changed: Bool

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

/// All jobs at a glance.
public enum OverallStatus: Sendable, Equatable {
    case allFine
    /// A run is missing, a job has been unreadable for long, or a machine cannot be reached.
    case needsAttention
    /// A job ran and went wrong, or cannot run.
    case failure

    public init(reports: [JobReport]) {
        let states = Set(reports.map(\.state))
        if states.contains(.failed) {
            self = .failure
        } else if !states.isDisjoint(with: [.missed, .stale, .hostOffline]) {
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
