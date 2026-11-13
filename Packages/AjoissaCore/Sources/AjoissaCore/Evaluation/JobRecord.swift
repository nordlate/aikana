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

    /// Whether the state says nothing about the job itself, only that it could not be looked at.
    public var isUnreadable: Bool {
        switch self {
        case .unknown, .stale, .hostOffline: true
        case .ok, .running, .waiting, .failed, .missed: false
        }
    }

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
    /// The scheduled time that is waited for or missed, and the moment its grace counts from. That moment is
    /// fixed when the scheduled time is first found open, so that a later wake cannot give it more time.
    public var openRun: Date?
    public var openRunGraceFrom: Date?
    /// For a job on an interval: the moment the interval is counted from. It moves on with each run that is
    /// seen, and by the length of each sleep.
    public var intervalFrom: Date?
    /// The state the job was in before its state became unreadable or its host went offline. Coming back to the
    /// same state is not news.
    public var stateBeforeUnreadable: JobState?
    /// When a run was seen that no scheduled time was waiting for, such as one started by hand after the
    /// scheduled run failed. Its output is then what the checks should read.
    public var extraRunSeenAt: Date?
    /// What the job's checks remember. The evaluation carries it along and never reads it.
    public var checkState: CheckState?
    public var state: JobState
    public var reason: String
    public var stateSince: Date
    public var lastEvaluatedAt: Date
    /// The most recent verdicts the job settled on, oldest first. `waiting`, `running` and `unknown` are passing
    /// moments between verdicts and are not listed, and a verdict is not listed twice in a row.
    public var transitions: [Transition]

    public init(
        watchingSince: Date,
        timetable: Timetable? = nil,
        lastObservedAt: Date? = nil,
        lastRunCount: Int? = nil,
        lastRun: Date? = nil,
        unreadableSince: Date? = nil,
        unavailableSince: Date? = nil,
        openRun: Date? = nil,
        openRunGraceFrom: Date? = nil,
        intervalFrom: Date? = nil,
        stateBeforeUnreadable: JobState? = nil,
        extraRunSeenAt: Date? = nil,
        checkState: CheckState? = nil,
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
        self.openRun = openRun
        self.openRunGraceFrom = openRunGraceFrom
        self.intervalFrom = intervalFrom
        self.stateBeforeUnreadable = stateBeforeUnreadable
        self.extraRunSeenAt = extraRunSeenAt
        self.checkState = checkState
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
    /// The moment "since the last expected run" means for this job's checks: the scheduled time in question,
    /// or for a job on an interval the start of the stretch in which a run must have happened. `nil` for a
    /// job with no run to expect.
    public var checksSince: Date?
    /// The moment that tells one run's output from the last one's. It stays the same until there is a new run.
    /// For a job with scheduled times it is the scheduled time in question, or the moment a later run was seen
    /// that no scheduled time was waiting for. For other jobs it is the moment the latest run was seen.
    public var outputSince: Date?
    /// The scheduled time before the one in question. Whatever was noted about a log before then belongs to
    /// an older run still.
    public var runBeforeExpected: Date?
    /// For a job known only through its checks: the moment its run has had its time. A check result from
    /// before then was a look at a job that may still have been working.
    public var checksFreshFrom: Date?
    /// Whether the state is news: it differs from the one in the record that was passed in. True for a job seen
    /// for the first time. A job that comes back from being unreadable or offline to the state it had before
    /// has not changed.
    public var changed: Bool
    /// The record to keep for the next evaluation.
    public var record: JobRecord
}
