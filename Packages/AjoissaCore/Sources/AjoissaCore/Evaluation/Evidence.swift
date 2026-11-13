import Foundation

/// How a job's last finished run ended.
public enum RunExit: Sendable, Equatable {
    /// No run has finished since the scheduler loaded the job.
    case neverExited
    case code(Int)
    /// Ended by a signal, as the scheduler words it: "Terminated: 15".
    case signal(String)

    /// What went wrong, as the end of "its last run …". `nil` for a normal end.
    var problem: String? {
        switch self {
        case .neverExited, .code(0): nil
        case let .code(code): "exited with code \(code)"
        case let .signal(signal): "was ended by signal \(signal)"
        }
    }
}

/// What a job's scheduler said about it at one moment.
public struct SourceEvidence: Sendable, Equatable {
    public enum Availability: Sendable, Equatable {
        /// The scheduler knows the job.
        case available
        /// The job is defined, but the scheduler has not loaded it, so it will not run.
        case notLoaded
        /// The scheduler does not know the job and no definition was found.
        case missing
        /// The scheduler could not be asked. This says nothing about the job.
        case unknown(reason: String)
    }

    public var availability: Availability
    /// When the scheduler will run the job. `nil` when that could not be read; empty when the job has no timetable.
    public var timetable: Timetable?
    public var isRunning: Bool?
    /// How many times the job has started since the scheduler loaded it. It starts over when the job is reloaded.
    public var runCount: Int?
    public var lastExit: RunExit?
    /// When the job's log file was last written.
    public var logModified: Date?
    /// When the last run started, for a scheduler that records it.
    public var lastRunStarted: Date?

    public init(
        availability: Availability,
        timetable: Timetable? = nil,
        isRunning: Bool? = nil,
        runCount: Int? = nil,
        lastExit: RunExit? = nil,
        logModified: Date? = nil,
        lastRunStarted: Date? = nil
    ) {
        self.availability = availability
        self.timetable = timetable
        self.isRunning = isRunning
        self.runCount = runCount
        self.lastExit = lastExit
        self.logModified = logModified
        self.lastRunStarted = lastRunStarted
    }
}

/// The result of one outcome check, as the evaluation needs it.
public struct CheckOutcome: Sendable, Equatable, Codable {
    public enum Result: Sendable, Equatable, Codable {
        case passed
        /// The check ran and what it looked for is not there. The text is written for a person.
        case failed(String)
        /// The check itself could not be carried out.
        case couldNotRun(String)
        /// The check was left for later, and says nothing yet. The text says why.
        case skipped(String)
    }

    public var result: Result
    /// When the job is shown to have run, by a check that passed: the time of the file it found, or of the log
    /// it read. `nil` for a check that shows no run, such as a command that merely succeeds.
    public var provesRunAt: Date?
    /// More to show a person who asks: the file that was found, or what a command printed.
    public var detail: String?

    public init(result: Result, provesRunAt: Date? = nil, detail: String? = nil) {
        self.result = result
        self.provesRunAt = provesRunAt
        self.detail = detail
    }
}

/// Everything known about a job at the moment it is evaluated. Gathering it is someone else's work;
/// the evaluation only reads it.
public struct Evidence: Sendable, Equatable {
    public var hostReachable: Bool
    /// `nil` for a job with no scheduler Ajoissa can read.
    public var source: SourceEvidence?
    /// The machine has been awake without a break since this moment: its last wake, or its start.
    /// A scheduled time that passed while it slept counts from here.
    public var awakeSince: Date?
    /// When the machine last started. The scheduler's run counts start over then.
    public var bootedAt: Date?
    public var checks: [CheckOutcome]

    public init(
        hostReachable: Bool = true,
        source: SourceEvidence? = nil,
        awakeSince: Date? = nil,
        bootedAt: Date? = nil,
        checks: [CheckOutcome] = []
    ) {
        self.hostReachable = hostReachable
        self.source = source
        self.awakeSince = awakeSince
        self.bootedAt = bootedAt
        self.checks = checks
    }
}
