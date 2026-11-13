import Foundation

/// What the checks remember between evaluations.
///
/// A log file only grows, and nothing in it says which part belongs to which run. To look only at what a run
/// wrote, Ajoissa remembers where each log ended when it last looked, and from that where the log stood just
/// before the run in question.
public struct CheckState: Sendable, Equatable, Codable {
    /// A place in a log: how long the log was, and enough about it to notice later that it is no longer the
    /// same text.
    public struct LogPosition: Sendable, Equatable, Codable {
        public var offset: Int64
        /// The file's identity then. A different one now means the log was replaced by a new file.
        public var identity: UInt64?
        /// The last few bytes before `offset`. If they are no longer there, the log was rewritten in place.
        public var tail: Data

        public init(offset: Int64, identity: UInt64? = nil, tail: Data = Data()) {
            self.offset = offset
            self.identity = identity
            self.tail = tail
        }
    }

    /// Where a log ended at a look.
    public struct LogMark: Sendable, Equatable, Codable {
        public var position: LogPosition
        public var date: Date

        public init(position: LogPosition, date: Date) {
            self.position = position
            self.date = date
        }
    }

    /// Where a log stood just before a run: everything after `position` was written by that run or later.
    public struct LogBaseline: Sendable, Equatable, Codable {
        /// The moment that identifies the run; see ``JobEvaluation/outputSince``.
        public var since: Date
        public var position: LogPosition

        public init(since: Date, position: LogPosition) {
            self.since = since
            self.position = position
        }
    }

    /// What a `command` check found, kept so that the command is not run again at every look.
    public struct CommandResult: Sendable, Equatable, Codable {
        /// The run the command was judging; `nil` for a job with no run to tell apart.
        public var since: Date?
        public var checkedAt: Date
        public var outcome: CheckOutcome

        public init(since: Date?, checkedAt: Date, outcome: CheckOutcome) {
            self.since = since
            self.checkedAt = checkedAt
            self.outcome = outcome
        }
    }

    /// By log path: where it ended at the last look.
    public var logMarks: [String: LogMark]
    /// By log path: where it stood before the run that is being judged.
    public var logBaselines: [String: LogBaseline]
    /// By command check: its last result.
    public var commands: [String: CommandResult]

    public init(
        logMarks: [String: LogMark] = [:],
        logBaselines: [String: LogBaseline] = [:],
        commands: [String: CommandResult] = [:]
    ) {
        self.logMarks = logMarks
        self.logBaselines = logBaselines
        self.commands = commands
    }
}
