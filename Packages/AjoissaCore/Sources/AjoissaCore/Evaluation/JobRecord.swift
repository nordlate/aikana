import Foundation

/// Whether a job is fine.
public enum JobState: String, Sendable, Equatable, Codable, CaseIterable {
    /// The run that was last due happened, and nothing about it failed.
    case ok
    case running
    /// A run is due and still has time, or no run has been due since Ajoissa started watching.
    case waiting
    /// The job ran and went wrong, or it cannot run at all.
    case failed
    /// A run was due and there is no sign of it.
    case missed
    /// The job's state could not be read, and has not been readable for a long time.
    case stale
    /// The job's state could not be read just now. This is not a verdict on the job.
    case unknown
    case hostOffline

    /// Whether the state means something is wrong with the job itself.
    public var isProblem: Bool {
        switch self {
        case .failed, .missed, .stale: true
        case .ok, .running, .waiting, .unknown, .hostOffline: false
        }
    }
}

/// What Ajoissa remembers about one job between evaluations. launchd keeps no history, so this is the record.
public struct JobRecord: Sendable, Equatable, Codable {
    public struct Transition: Sendable, Equatable, Codable {
        public var date: Date
        public var state: JobState
        public var reason: String

        public init(date: Date, state: JobState, reason: String) {
            self.date = date
            self.state = state
            self.reason = reason
        }
    }

    /// Runs that were due before this moment are not judged: nobody was looking, or the timetable was different.
    public var watchingSince: Date
    /// The timetable the job had when it was last evaluated. A change starts the watch over.
    public var timetable: Timetable?
    /// When the scheduler's run count was last read, and what it was.
    public var lastObservedAt: Date?
    public var lastRunCount: Int?
    /// The latest run is known to have happened no earlier than this.
    public var lastRun: Date?
    /// Since when the job's state has been unreadable without a break.
    public var unreadableSince: Date?
    /// Since when the scheduler has not had the job loaded. While that lasts no run can be expected.
    public var unavailableSince: Date?
    public var state: JobState
    public var reason: String
    public var stateSince: Date
    public var lastEvaluatedAt: Date
    /// The most recent verdicts the job settled on, oldest first. `waiting` and `running` are passing moments
    /// between verdicts and are not listed.
    public var transitions: [Transition]

    public init(
        watchingSince: Date,
        timetable: Timetable? = nil,
        lastObservedAt: Date? = nil,
        lastRunCount: Int? = nil,
        lastRun: Date? = nil,
        unreadableSince: Date? = nil,
        unavailableSince: Date? = nil,
        state: JobState = .waiting,
        reason: String = "",
        stateSince: Date? = nil,
        lastEvaluatedAt: Date? = nil,
        transitions: [Transition] = []
    ) {
        self.watchingSince = watchingSince
        self.timetable = timetable
        self.lastObservedAt = lastObservedAt
        self.lastRunCount = lastRunCount
        self.lastRun = lastRun
        self.unreadableSince = unreadableSince
        self.unavailableSince = unavailableSince
        self.state = state
        self.reason = reason
        self.stateSince = stateSince ?? watchingSince
        self.lastEvaluatedAt = lastEvaluatedAt ?? watchingSince
        self.transitions = transitions
    }
}

/// The verdict on a job at one moment.
public struct JobEvaluation: Sendable, Equatable {
    public var state: JobState
    /// Why, in a sentence that completes "The job is <state>: …".
    public var reason: String
    /// The scheduled time the verdict is about, for a job with calendar rules: the oldest one not yet accounted
    /// for, or else the latest one that has passed. Checks that ask "since the last expected run" mean this.
    public var expectedRun: Date?
    public var nextRun: Date?
    /// Whether the state differs from the one in the record that was passed in. True for a job seen for the first time.
    public var changed: Bool
    /// The record to keep for the next evaluation.
    public var record: JobRecord
}
